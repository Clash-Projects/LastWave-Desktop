import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_info.dart';
import '../../core/diagnostics/diagnostics_log.dart';
import '../../core/network/dio_factory.dart';
import '../../core/storage/prefs.dart';

/// One listen to send: what played and when it started (UTC seconds).
@immutable
class Listen {
  final String artist;
  final String track;
  final String album;
  final int startedAtSec;
  const Listen({
    required this.artist,
    required this.track,
    this.album = '',
    this.startedAtSec = 0,
  });
}

/// Scrobble services besides Last.fm. Each is independent: its own
/// connection, its own offline queue, and a failure in one never holds up
/// another (or Last.fm).
abstract class ExtraScrobbler {
  /// Shown in Settings and Stats.
  String get name;
  bool get connected;
  String get username;
  Future<bool> nowPlaying(Listen l);
  Future<bool> submit(Listen l);

  /// Lifetime listens on the service, or null when unavailable.
  Future<int?> listenCount();

  /// The user's profile page.
  Uri get profileUrl;
}

// -- ListenBrainz -------------------------------------------------------------

/// ListenBrainz (or any server speaking its API: Maloja, Koito, …).
/// Auth is the user token from listenbrainz.org/settings.
class ListenBrainzScrobbler implements ExtraScrobbler {
  ListenBrainzScrobbler(this._prefs, this._dio);
  final Prefs _prefs;
  final Dio _dio;

  static const defaultServer = 'https://api.listenbrainz.org';

  @override
  String get name => 'ListenBrainz';
  @override
  bool get connected => _prefs.listenBrainzToken.isNotEmpty;
  @override
  String get username => _prefs.listenBrainzUser;

  String get _base => normalizeServer(_prefs.listenBrainzServer, defaultServer);

  static String cleanToken(String token) {
    var t = token.trim();
    if (t.toLowerCase().startsWith('token ')) {
      t = t.substring(6).trim();
    } else if (t.toLowerCase().startsWith('bearer ')) {
      t = t.substring(7).trim();
    }
    return t.replaceAll('"', '').replaceAll("'", '').trim();
  }

  Options _auth(String token) => Options(
        headers: {
          'Authorization': 'Token ${cleanToken(token)}',
          'Content-Type': 'application/json',
        },
        responseType: ResponseType.json,
        validateStatus: (_) => true,
      );

  /// Checks [token] against [server] and stores it with the user name.
  /// Returns null on success, else the reason.
  Future<String?> connect(String token, {String server = ''}) async {
    final t = cleanToken(token);
    if (t.isEmpty) return 'Paste your user token.';
    final base = normalizeServer(server, defaultServer);
    try {
      final res = await _dio.get<dynamic>('$base/1/validate-token',
          options: _auth(t));
      var body = res.data;
      if (body is String) {
        try {
          body = jsonDecode(body);
        } catch (_) {}
      }
      final valid = body is Map && body['valid'] == true;
      if (!valid) {
        return (res.statusCode ?? 0) == 0
            ? 'Could not reach $base.'
            : (body is Map && body['message'] != null
                ? body['message'].toString()
                : 'The token was not accepted.');
      }
      await _prefs.setListenBrainz(
        token: t,
        user: body['user_name']?.toString() ?? '',
        server: server.trim(),
      );
      return null;
    } catch (_) {
      return 'Could not reach $base.';
    }
  }

  Future<void> disconnect() =>
      _prefs.setListenBrainz(token: '', user: '', server: '');

  Map<String, Object?> _metadata(Listen l) => {
        'artist_name': l.artist,
        'track_name': l.track,
        if (l.album.isNotEmpty) 'release_name': l.album,
        'additional_info': {
          'media_player': 'LastWave',
          'submission_client': 'LastWave Desktop',
          'submission_client_version': appVersion,
        },
      };

  Future<bool> _post(String type, Listen l) async {
    if (!connected) return false;
    final timestamp = l.startedAtSec > 0
        ? l.startedAtSec
        : DateTime.now().millisecondsSinceEpoch ~/ 1000;
    try {
      final res = await _dio.post<dynamic>(
        '$_base/1/submit-listens',
        data: jsonEncode({
          'listen_type': type,
          'payload': [
            {
              if (type == 'single') 'listened_at': timestamp,
              'track_metadata': _metadata(l),
            },
          ],
        }),
        options: _auth(_prefs.listenBrainzToken),
      );
      final ok = (res.statusCode ?? 0) ~/ 100 == 2;
      if (!ok) DiagnosticsLog.info('listenbrainz $type http=${res.statusCode}');
      return ok;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> nowPlaying(Listen l) => _post('playing_now', l);
  @override
  Future<bool> submit(Listen l) => _post('single', l);

  @override
  Future<int?> listenCount() async {
    if (!connected || username.isEmpty) return null;
    try {
      final res = await _dio.get<dynamic>(
        '$_base/1/user/${Uri.encodeComponent(username)}/listen-count',
        options: _auth(_prefs.listenBrainzToken),
      );
      final data = res.data;
      final payload = data is Map ? data['payload'] : null;
      final count = payload is Map ? payload['count'] : null;
      return count is num ? count.toInt() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Uri get profileUrl {
    final base = _base;
    // The public site for the default API host; self-hosted servers serve
    // both from one origin.
    final site = base == defaultServer ? 'https://listenbrainz.org' : base;
    return Uri.parse('$site/user/${Uri.encodeComponent(username)}/');
  }
}

// -- Libre.fm -------------------------------------------------------------------

/// Libre.fm (or any GNU FM server): the Last.fm 2.0 protocol at another
/// address, with a mobile session from username + password.
class LibreFmScrobbler implements ExtraScrobbler {
  LibreFmScrobbler(this._prefs, this._dio);
  final Prefs _prefs;
  final Dio _dio;

  static const defaultServer = 'https://libre.fm';

  // GNU FM does not issue API keys: any 32-character key/secret pair is
  // accepted, but requests must still be signed with it.
  static const _apiKey = 'lastwavedesktop00000000000000000';
  static const _apiSecret = 'lastwavedesktopsecret00000000000';

  @override
  String get name => 'Libre.fm';
  @override
  bool get connected => _prefs.libreFmSession.isNotEmpty;
  @override
  String get username => _prefs.libreFmUser;

  String get _endpoint =>
      '${normalizeServer(_prefs.libreFmServer, defaultServer)}/2.0/';

  @visibleForTesting
  static String sign(Map<String, String> params, String secret) {
    final keys = params.keys.where((k) => k != 'format').toList()..sort();
    final buf = StringBuffer();
    for (final k in keys) {
      buf
        ..write(k)
        ..write(params[k]);
    }
    buf.write(secret);
    return md5.convert(utf8.encode(buf.toString())).toString();
  }

  Future<Map<String, dynamic>?> _call(
    String endpoint,
    Map<String, String> params,
  ) async {
    final signed = {
      ...params,
      'api_key': _apiKey,
    };
    signed['api_sig'] = sign(signed, _apiSecret);
    signed['format'] = 'json';
    try {
      final res = await _dio.post<dynamic>(
        endpoint,
        data: signed,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
      final raw = '${res.data ?? ''}'.trim();
      if (raw.isEmpty) return null;
      if (raw.startsWith('{')) {
        final body = jsonDecode(raw);
        return body is Map ? Map<String, dynamic>.from(body) : null;
      }
      if (raw.startsWith('<')) {
        return parseXml(raw);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static Map<String, dynamic> parseXml(String xml) {
    final map = <String, dynamic>{};
    final key = RegExp(r'<key>([^<]+)</key>').firstMatch(xml)?.group(1);
    final name = RegExp(r'<name>([^<]+)</name>').firstMatch(xml)?.group(1);
    final err =
        RegExp(r'<error[^>]*>([^<]+)</error>').firstMatch(xml)?.group(1);
    final playcount =
        RegExp(r'<playcount>([^<]+)</playcount>').firstMatch(xml)?.group(1);

    if (key != null) {
      map['session'] = {
        'key': key,
        if (name != null) 'name': name,
      };
    }
    if (playcount != null) {
      map['user'] = {'playcount': playcount};
    }
    if (err != null) {
      map['error'] = err;
      map['message'] = err;
    }
    if (xml.contains('status="ok"') || xml.contains("status='ok'")) {
      map['status'] = 'ok';
    }
    return map;
  }

  /// Signs in and stores the session. Null on success, else the reason.
  Future<String?> connect(
    String user,
    String password, {
    String server = '',
  }) async {
    final u = user.trim();
    if (u.isEmpty || password.isEmpty) {
      return 'Enter your username and password.';
    }
    final base = normalizeServer(server, defaultServer);

    // 1. Try standard GNU FM token auth with exact username case: md5(u + md5(password))
    final tokenExact = md5
        .convert(utf8.encode(u + md5.convert(utf8.encode(password)).toString()))
        .toString();
    var body = await _call('$base/2.0/', {
      'method': 'auth.getMobileSession',
      'username': u,
      'authToken': tokenExact,
    });

    // 2. If rejected, try lowercased username token (some servers lowercase internally)
    if (body == null || body['session'] == null) {
      final tokenLower = md5
          .convert(utf8.encode(u.toLowerCase() +
              md5.convert(utf8.encode(password)).toString()))
          .toString();
      if (tokenLower != tokenExact) {
        final retry = await _call('$base/2.0/', {
          'method': 'auth.getMobileSession',
          'username': u,
          'authToken': tokenLower,
        });
        if (retry != null && retry['session'] != null) {
          body = retry;
        }
      }
    }

    // 3. Fallback: try plain password (for modern/alternative Last.fm compatible servers)
    if (body == null || body['session'] == null) {
      final retryPlain = await _call('$base/2.0/', {
        'method': 'auth.getMobileSession',
        'username': u,
        'password': password,
      });
      if (retryPlain != null && retryPlain['session'] != null) {
        body = retryPlain;
      }
    }

    if (body == null) return 'Could not reach $base.';
    final key = body['session'] is Map ? body['session']['key'] : null;
    if (key is! String || key.isEmpty) {
      return body['message']?.toString() ??
          body['error']?.toString() ??
          'Sign-in was not accepted.';
    }
    final name =
        body['session'] is Map ? '${body['session']['name'] ?? u}' : u;
    await _prefs.setLibreFm(session: key, user: name, server: server.trim());
    return null;
  }

  Future<void> disconnect() =>
      _prefs.setLibreFm(session: '', user: '', server: '');

  Future<bool> _write(String method, Map<String, String> extra) async {
    if (!connected) return false;
    final body = await _call(_endpoint, {
      'method': method,
      'sk': _prefs.libreFmSession,
      for (final e in extra.entries)
        if (e.value.isNotEmpty) e.key: e.value,
    });
    final ok = body != null && !body.containsKey('error');
    if (!ok) DiagnosticsLog.info('librefm $method ok=false');
    return ok;
  }

  @override
  Future<bool> nowPlaying(Listen l) => _write('track.updateNowPlaying', {
        'artist': l.artist,
        'track': l.track,
        'album': l.album,
      });

  @override
  Future<bool> submit(Listen l) => _write('track.scrobble', {
        'artist[0]': l.artist,
        'track[0]': l.track,
        'album[0]': l.album,
        'timestamp[0]': '${l.startedAtSec}',
      });

  @override
  Future<int?> listenCount() async {
    if (!connected || username.isEmpty) return null;
    final body = await _call(_endpoint, {
      'method': 'user.getInfo',
      'user': username,
    });
    final raw = body?['user'] is Map ? body!['user']['playcount'] : null;
    return raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
  }

  @override
  Uri get profileUrl => Uri.parse(
      '${normalizeServer(_prefs.libreFmServer, defaultServer)}/user/${Uri.encodeComponent(username)}');
}

/// `https://host[:port][/path]` without a trailing slash; [fallback] when
/// blank. A bare host gets https.
String normalizeServer(String raw, String fallback) {
  var s = raw.trim();
  if (s.isEmpty) return fallback;
  if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

// -- fan-out ----------------------------------------------------------------------

/// Sends every listen to each connected service. Failed submits wait in a
/// per-service queue (max 200) and go out before that service's next one.
class ExtraScrobblers {
  ExtraScrobblers(this.services);
  final List<ExtraScrobbler> services;
  final Map<String, List<Listen>> _queues = {};

  void nowPlaying(Listen l) {
    for (final s in services) {
      if (s.connected) unawaited(s.nowPlaying(l));
    }
  }

  void submit(Listen l) {
    for (final s in services) {
      if (s.connected) unawaited(_submit(s, l));
    }
  }

  Future<void> _submit(ExtraScrobbler s, Listen l) async {
    final queue = _queues.putIfAbsent(s.name, () => []);
    queue.add(l);
    while (queue.isNotEmpty) {
      if (!await s.submit(queue.first)) break;
      queue.removeAt(0);
    }
    while (queue.length > 200) {
      queue.removeAt(0);
    }
  }
}

final _scrobblerDioProvider = Provider<Dio>((_) => DioFactory.create());

final listenBrainzProvider = Provider<ListenBrainzScrobbler>((ref) =>
    ListenBrainzScrobbler(ref.watch(prefsProvider), ref.watch(_scrobblerDioProvider)));

final libreFmProvider = Provider<LibreFmScrobbler>((ref) =>
    LibreFmScrobbler(ref.watch(prefsProvider), ref.watch(_scrobblerDioProvider)));

final extraScrobblersProvider = Provider<ExtraScrobblers>((ref) =>
    ExtraScrobblers([ref.watch(listenBrainzProvider), ref.watch(libreFmProvider)]));

/// Bumped after connecting / disconnecting so Settings and Stats refresh.
final extraScrobblersRevisionProvider = StateProvider<int>((_) => 0);

/// Lifetime listen count per connected service, for the Stats strips.
final extraScrobbleCountProvider =
    FutureProvider.autoDispose.family<int?, String>((ref, name) async {
  ref.watch(extraScrobblersRevisionProvider);
  final s = ref
      .watch(extraScrobblersProvider)
      .services
      .firstWhere((s) => s.name == name);
  return s.listenCount();
});
