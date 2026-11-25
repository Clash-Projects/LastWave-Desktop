import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synchronized/synchronized.dart';
import 'package:xml/xml.dart';

import '../../core/app_info.dart';
import '../../core/diagnostics/diagnostics_log.dart';
import '../../core/network/dio_factory.dart';
import '../../core/storage/prefs.dart';
import '../lastfm/home_models.dart';

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

  (String, String, int) get _key => (
    artist.trim().toLowerCase(),
    track.trim().toLowerCase(),
    startedAtSec,
  );
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

  /// False keeps this listen queued; true also consumes permanent rejections.
  Future<bool> submit(Listen l);

  /// Lifetime listens on the service, or null when unavailable.
  Future<int?> listenCount();

  /// The user's profile page.
  Uri get profileUrl;
}

/// Extended read + love capabilities for scrobbler backends that support
/// fetching history, user stats, top charts, and track feedback.
abstract interface class ScrobblerReadBackend {
  Future<bool> loveTrack(String artist, String track, bool loved);

  Future<List<HomeTrack>> fetchRecentTracks({
    String? viewingAs,
    int limit = 30,
    int page = 1,
  });

  Future<HomeStats> fetchStats({String? viewingAs});

  Future<int> fetchPeriodPlayCount({
    String? viewingAs,
    required int fromMillis,
    required int toMillis,
  });

  Future<List<HomeTrack>> fetchTopTracks({
    String? viewingAs,
    String period = '7day',
    int limit = 20,
  });

  Future<List<({String name, int playCount, String artworkUrl})>> fetchTopArtists({
    String? viewingAs,
    String period = '7day',
    int limit = 20,
  });

  Future<List<({String name, String artist, int playCount, String artworkUrl})>>
      fetchTopAlbums({
    String? viewingAs,
    String period = '7day',
    int limit = 20,
  });
}

// -- ListenBrainz -------------------------------------------------------------

/// ListenBrainz (or any server speaking its API: Maloja, Koito, …).
/// Auth is the user token from listenbrainz.org/settings.
class ListenBrainzScrobbler implements ExtraScrobbler, ScrobblerReadBackend {
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
      final res = await _dio.get<dynamic>(
        '$base/1/validate-token',
        options: _auth(t),
      );
      var body = res.data;
      if (body is String) {
        try {
          body = jsonDecode(body);
        } catch (_) {}
      }
      final valid =
          (res.statusCode ?? 0) ~/ 100 == 2 &&
          body is Map &&
          body['valid'] == true;
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
      if (!ok) {
        DiagnosticsLog.info('listenbrainz $type http=${res.statusCode}');
      }
      // A rejected payload cannot become valid by retrying and would block later listens.
      return ok || (type == 'single' && res.statusCode == 400);
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
      if ((res.statusCode ?? 0) ~/ 100 != 2) return null;
      final data = res.data;
      final payload = data is Map ? data['payload'] : null;
      final count = payload is Map ? payload['count'] : null;
      return count is num ? count.toInt() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Uri get profileUrl => profileUrlFor(username);

  /// Public profile page for any ListenBrainz user.
  Uri profileUrlFor(String user) {
    final base = _base;
    // The public site for the default API host; self-hosted servers serve
    // both from one origin.
    final site = base == defaultServer ? 'https://listenbrainz.org' : base;
    return Uri.parse('$site/user/${Uri.encodeComponent(user)}/');
  }

  static String _lbRange(String period) => switch (period) {
        '7day' => 'week',
        '1month' => 'month',
        '3month' || '6month' || '12month' => 'year',
        _ => 'all_time',
      };

  static String _caaThumb(Map<dynamic, dynamic> map) {
    final rel = map['caa_release_mbid']?.toString() ?? '';
    if (rel.isEmpty) return '';
    final caaId = map['caa_id']?.toString() ?? '';
    if (caaId.isNotEmpty) {
      return 'https://coverartarchive.org/release/$rel/$caaId-250.jpg';
    }
    return 'https://coverartarchive.org/release/$rel/front-250';
  }

  Future<Map<String, dynamic>?> _getJson(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final res = await _dio.get<dynamic>(
        '$_base$path',
        queryParameters: query,
        options: connected ? _auth(_prefs.listenBrainzToken) : null,
      );
      if ((res.statusCode ?? 0) ~/ 100 != 2 || res.statusCode == 204) {
        return null;
      }
      var data = res.data;
      if (data is String && data.trim().isNotEmpty) {
        data = jsonDecode(data);
      }
      return data is Map ? Map<String, dynamic>.from(data) : null;
    } catch (_) {
      return null;
    }
  }

  String? _effectiveUser(String? viewingAs) {
    final u = (viewingAs ?? username).trim();
    return u.isEmpty ? null : u;
  }

  @override
  Future<bool> loveTrack(String artist, String track, bool loved) async {
    if (!connected || artist.trim().isEmpty || track.trim().isEmpty) {
      return false;
    }
    try {
      final lookup = await _getJson(
        '/1/metadata/lookup/',
        query: {'artist_name': artist, 'recording_name': track},
      );
      final mbid = lookup?['recording_mbid']?.toString() ?? '';
      if (mbid.isEmpty) return false;
      final res = await _dio.post<dynamic>(
        '$_base/1/feedback/recording-feedback',
        data: jsonEncode({'recording_mbid': mbid, 'score': loved ? 1 : 0}),
        options: _auth(_prefs.listenBrainzToken),
      );
      return (res.statusCode ?? 0) ~/ 100 == 2;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<HomeTrack>> fetchRecentTracks({
    String? viewingAs,
    int limit = 30,
    int page = 1,
  }) async {
    final user = _effectiveUser(viewingAs);
    if (user == null) return const [];
    final json = await _getJson(
      '/1/user/${Uri.encodeComponent(user)}/listens',
      query: {'count': '$limit'},
    );
    final payload = json?['payload'];
    final listens = payload is Map ? payload['listens'] : null;
    if (listens is! List) return const [];
    final out = <HomeTrack>[];
    for (final item in listens) {
      if (item is! Map) continue;
      final meta = item['track_metadata'];
      if (meta is! Map) continue;
      final name = meta['track_name']?.toString() ?? '';
      final artist = meta['artist_name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final ts = item['listened_at'];
      final tsSec = ts is num ? ts.toInt() : int.tryParse('${ts ?? ''}');
      final mbidMap = meta['mbid_mapping'];
      final art = mbidMap is Map ? _caaThumb(mbidMap) : '';
      out.add(HomeTrack(
        name: name,
        artist: artist,
        artworkUrl: art,
        timestampMillis: tsSec != null ? tsSec * 1000 : null,
      ));
    }
    return out;
  }

  @override
  Future<HomeStats> fetchStats({String? viewingAs}) async {
    final user = _effectiveUser(viewingAs);
    if (user == null) return const HomeStats();
    final enc = Uri.encodeComponent(user);
    final results = await Future.wait([
      _getJson('/1/user/$enc/listen-count'),
      _getJson('/1/stats/user/$enc/recordings', query: {'range': 'all_time', 'count': '1'}),
      _getJson('/1/stats/user/$enc/artists', query: {'range': 'all_time', 'count': '1'}),
      _getJson('/1/stats/user/$enc/releases', query: {'range': 'all_time', 'count': '1'}),
    ]);
    int? payloadInt(Map<String, dynamic>? root, String key) {
      final p = root?['payload'];
      final v = p is Map ? p[key] : null;
      return v is num ? v.toInt() : int.tryParse('${v ?? ''}');
    }

    return HomeStats(
      scrobbles: payloadInt(results[0], 'count') ?? 0,
      trackCount: payloadInt(results[1], 'total_recording_count') ??
          payloadInt(results[1], 'total_recordings_count') ??
          0,
      artistCount: payloadInt(results[2], 'total_artist_count') ?? 0,
      albumCount: payloadInt(results[3], 'total_release_count') ?? 0,
    );
  }

  @override
  Future<int> fetchPeriodPlayCount({
    String? viewingAs,
    required int fromMillis,
    required int toMillis,
  }) async {
    final user = _effectiveUser(viewingAs);
    if (user == null) return 0;
    final json = await _getJson(
      '/1/user/${Uri.encodeComponent(user)}/listens',
      query: {
        'min_ts': '${fromMillis ~/ 1000}',
        'max_ts': '${toMillis ~/ 1000}',
        'count': '100',
      },
    );
    final payload = json?['payload'];
    if (payload is! Map) return 0;
    final count = payload['count'];
    if (count is num) return count.toInt();
    final listens = payload['listens'];
    return listens is List ? listens.length : 0;
  }

  @override
  Future<List<HomeTrack>> fetchTopTracks({
    String? viewingAs,
    String period = '7day',
    int limit = 20,
  }) async {
    final user = _effectiveUser(viewingAs);
    if (user == null) return const [];
    final json = await _getJson(
      '/1/stats/user/${Uri.encodeComponent(user)}/recordings',
      query: {'range': _lbRange(period), 'count': '$limit'},
    );
    final payload = json?['payload'];
    final recs = payload is Map ? payload['recordings'] : null;
    if (recs is! List) return const [];
    return [
      for (final r in recs)
        if (r is Map && (r['track_name']?.toString() ?? '').isNotEmpty)
          HomeTrack(
            name: r['track_name']?.toString() ?? '',
            artist: r['artist_name']?.toString() ?? '',
            artworkUrl: _caaThumb(r),
            playCount: (r['listen_count'] as num?)?.toInt() ?? 0,
          ),
    ];
  }

  @override
  Future<List<({String name, int playCount, String artworkUrl})>>
      fetchTopArtists({
    String? viewingAs,
    String period = '7day',
    int limit = 20,
  }) async {
    final user = _effectiveUser(viewingAs);
    if (user == null) return const [];
    final json = await _getJson(
      '/1/stats/user/${Uri.encodeComponent(user)}/artists',
      query: {'range': _lbRange(period), 'count': '$limit'},
    );
    final payload = json?['payload'];
    final artists = payload is Map ? payload['artists'] : null;
    if (artists is! List) return const [];
    return [
      for (final a in artists)
        if (a is Map && (a['artist_name']?.toString() ?? '').isNotEmpty)
          (
            name: a['artist_name']?.toString() ?? '',
            playCount: (a['listen_count'] as num?)?.toInt() ?? 0,
            artworkUrl: '',
          ),
    ];
  }

  @override
  Future<List<({String name, String artist, int playCount, String artworkUrl})>>
      fetchTopAlbums({
    String? viewingAs,
    String period = '7day',
    int limit = 20,
  }) async {
    final user = _effectiveUser(viewingAs);
    if (user == null) return const [];
    final json = await _getJson(
      '/1/stats/user/${Uri.encodeComponent(user)}/releases',
      query: {'range': _lbRange(period), 'count': '$limit'},
    );
    final payload = json?['payload'];
    final releases = payload is Map ? payload['releases'] : null;
    if (releases is! List) return const [];
    return [
      for (final r in releases)
        if (r is Map && (r['release_name']?.toString() ?? '').isNotEmpty)
          (
            name: r['release_name']?.toString() ?? '',
            artist: r['artist_name']?.toString() ?? '',
            playCount: (r['listen_count'] as num?)?.toInt() ?? 0,
            artworkUrl: _caaThumb(r),
          ),
    ];
  }
}

// -- Libre.fm -------------------------------------------------------------------

/// Libre.fm (or any GNU FM server): the Last.fm 2.0 protocol at another
/// address, with a mobile session from username + password.
class LibreFmScrobbler implements ExtraScrobbler, ScrobblerReadBackend {
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
    final signed = {...params, 'api_key': _apiKey};
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
      if ((res.statusCode ?? 0) ~/ 100 != 2) {
        DiagnosticsLog.info('librefm ${params['method']} http=${res.statusCode}');
        return null;
      }
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
    final root = XmlDocument.parse(xml).rootElement;
    if (root.name.local != 'lfm') return {};
    final map = <String, dynamic>{'status': root.getAttribute('status')};
    final error = root.getElement('error');
    if (error != null) {
      map['error'] = error.innerText;
      map['message'] = error.innerText;
    }
    if (map['status'] != 'ok') return map;
    final session = root.getElement('session');
    if (session != null) {
      map['session'] = {
        'key': session.getElement('key')?.innerText,
        'name': session.getElement('name')?.innerText,
      };
    }
    final playcount = root.getElement('user')?.getElement('playcount')?.innerText;
    if (playcount != null) {
      map['user'] = {'playcount': playcount};
    }
    final scrobbles = root.getElement('scrobbles');
    if (scrobbles != null) {
      map['scrobbles'] = {
        '@attr': {
          'accepted': scrobbles.getAttribute('accepted'),
          'ignored': scrobbles.getAttribute('ignored'),
        },
        if (scrobbles.getElement('scrobble') != null)
          'scrobble': <String, dynamic>{},
      };
    }
    if (root.getElement('nowplaying') != null) {
      map['nowplaying'] = <String, dynamic>{};
    }
    for (final ignored in root.findAllElements('ignoredMessage')) {
      map['ignoredMessageCode'] = ignored.getAttribute('code');
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
          .convert(
            utf8.encode(
              u.toLowerCase() + md5.convert(utf8.encode(password)).toString(),
            ),
          )
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
    final name = body['session'] is Map ? '${body['session']['name'] ?? u}' : u;
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
    final scrobbles = body?['scrobbles'];
    final attributes = scrobbles is Map ? scrobbles['@attr'] : null;
    final accepted =
        int.tryParse('${attributes is Map ? attributes['accepted'] : null}') ?? 0;
    final result = method == 'track.scrobble'
        ? (scrobbles is Map ? scrobbles['scrobble'] : null)
        : body?['nowplaying'];
    final ignored = result is Map ? result['ignoredMessage'] : null;
    final rawCode =
        body?['ignoredMessageCode'] ?? (ignored is Map ? ignored['code'] : null);
    final code = int.tryParse('$rawCode');
    // Retrying rejected metadata (1–4) or duplicates (91) would block later listens.
    final consumedCode =
        rawCode == null ||
        code != null && (code >= 0 && code <= 4 || code == 91);
    final ok =
        body != null &&
        !body.containsKey('error') &&
        (body['status'] == null || body['status'] == 'ok') &&
        (result is Map || method == 'track.scrobble' && accepted > 0) &&
        consumedCode;
    if (!ok) {
      DiagnosticsLog.info('librefm $method ok=false');
    } else if (code != null && code >= 1 && code <= 4) {
      DiagnosticsLog.info('librefm $method ignored=$code');
    }
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
    '${normalizeServer(_prefs.libreFmServer, defaultServer)}/user/${Uri.encodeComponent(username)}',
  );

  String? _effectiveUser(String? viewingAs) {
    final u = (viewingAs ?? username).trim();
    return u.isEmpty ? null : u;
  }

  Future<Map<String, dynamic>?> _read(Map<String, String> params) async {
    final body = await _call(_endpoint, params);
    if (body == null || body.containsKey('error')) return null;
    return body;
  }

  @override
  Future<bool> loveTrack(String artist, String track, bool loved) => _write(
        loved ? 'track.love' : 'track.unlove',
        {'artist': artist, 'track': track},
      );

  @override
  Future<List<HomeTrack>> fetchRecentTracks({
    String? viewingAs,
    int limit = 30,
    int page = 1,
  }) async {
    final user = _effectiveUser(viewingAs);
    if (user == null) return const [];
    final json = await _read({
      'method': 'user.getrecenttracks',
      'user': user,
      'limit': '$limit',
      'page': '$page',
      'extended': '0',
    });
    return json == null ? const [] : LastFmResponseParser.parseRecentTracks(json);
  }

  @override
  Future<HomeStats> fetchStats({String? viewingAs}) async {
    final user = _effectiveUser(viewingAs);
    if (user == null) return const HomeStats();
    final results = await Future.wait([
      _read({'method': 'user.getinfo', 'user': user}),
      _read({
        'method': 'user.gettoptracks',
        'user': user,
        'limit': '1',
        'period': 'overall',
      }),
      _read({
        'method': 'user.gettopartists',
        'user': user,
        'limit': '1',
        'period': 'overall',
      }),
      _read({
        'method': 'user.gettopalbums',
        'user': user,
        'limit': '1',
        'period': 'overall',
      }),
    ]);
    return LastFmResponseParser.parseStats(
      userInfoJson: results[0] ?? const {},
      topTracksJson: results[1] ?? const {},
      topArtistsJson: results[2] ?? const {},
      topAlbumsJson: results[3] ?? const {},
    );
  }

  @override
  Future<int> fetchPeriodPlayCount({
    String? viewingAs,
    required int fromMillis,
    required int toMillis,
  }) async {
    final user = _effectiveUser(viewingAs);
    if (user == null) return 0;
    final json = await _read({
      'method': 'user.getrecenttracks',
      'user': user,
      'from': '${fromMillis ~/ 1000}',
      'to': '${toMillis ~/ 1000}',
      'limit': '1',
      'page': '1',
    });
    return json == null
        ? 0
        : LastFmResponseParser.parsePeriodPlayCount(json);
  }

  @override
  Future<List<HomeTrack>> fetchTopTracks({
    String? viewingAs,
    String period = '7day',
    int limit = 20,
  }) async {
    final user = _effectiveUser(viewingAs);
    if (user == null) return const [];
    final json = await _read({
      'method': 'user.gettoptracks',
      'user': user,
      'period': period,
      'limit': '$limit',
    });
    return json == null ? const [] : LastFmResponseParser.parseTopTracks(json);
  }

  @override
  Future<List<({String name, int playCount, String artworkUrl})>>
      fetchTopArtists({
    String? viewingAs,
    String period = '7day',
    int limit = 20,
  }) async {
    final user = _effectiveUser(viewingAs);
    if (user == null) return const [];
    final json = await _read({
      'method': 'user.gettopartists',
      'user': user,
      'period': period,
      'limit': '$limit',
    });
    return json == null ? const [] : LastFmResponseParser.parseTopArtists(json);
  }

  @override
  Future<List<({String name, String artist, int playCount, String artworkUrl})>>
      fetchTopAlbums({
    String? viewingAs,
    String period = '7day',
    int limit = 20,
  }) async {
    final user = _effectiveUser(viewingAs);
    if (user == null) return const [];
    final json = await _read({
      'method': 'user.gettopalbums',
      'user': user,
      'period': period,
      'limit': '$limit',
    });
    return json == null ? const [] : LastFmResponseParser.parseTopAlbums(json);
  }
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

class _ScrobbleQueue {
  final lock = Lock();
  final listens = <Listen>[];
  final consumed = LinkedHashSet<(String, String, int)>();
}

/// Sends every listen to each connected service. Failed submits wait in a
/// per-service queue (max 200) and go out before that service's next one.
class ExtraScrobblers {
  ExtraScrobblers(this.services);
  final List<ExtraScrobbler> services;
  final _queues = <ExtraScrobbler, _ScrobbleQueue>{};

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

  void loveTrack(String artist, String track, bool loved) {
    for (final s in services) {
      if (s.connected && s is ScrobblerReadBackend) {
        unawaited((s as ScrobblerReadBackend).loveTrack(artist, track, loved));
      }
    }
  }

  Future<void> _submit(ExtraScrobbler s, Listen l) async {
    final state = _queues.putIfAbsent(s, _ScrobbleQueue.new);
    await state.lock.synchronized(() async {
      final queue = state.listens;
      if (!state.consumed.contains(l._key) &&
          !queue.any((pending) => pending._key == l._key)) {
        queue.add(l);
      }
      while (queue.length > 200) {
        queue.removeAt(0);
      }
      while (s.connected && queue.isNotEmpty) {
        final pending = queue.first;
        try {
          if (!await s.submit(pending)) break;
        } catch (_) {
          DiagnosticsLog.info('${s.name} submission failed');
          break;
        }
        queue.removeAt(0);
        state.consumed.add(pending._key);
        if (state.consumed.length > 200) {
          state.consumed.remove(state.consumed.first);
        }
      }
    });
  }
}

final _scrobblerDioProvider = Provider<Dio>((_) => DioFactory.create());

final listenBrainzProvider = Provider<ListenBrainzScrobbler>(
  (ref) => ListenBrainzScrobbler(
    ref.watch(prefsProvider),
    ref.watch(_scrobblerDioProvider),
  ),
);

final libreFmProvider = Provider<LibreFmScrobbler>(
  (ref) => LibreFmScrobbler(
    ref.watch(prefsProvider),
    ref.watch(_scrobblerDioProvider),
  ),
);

final extraScrobblersProvider = Provider<ExtraScrobblers>(
  (ref) => ExtraScrobblers([
    ref.watch(listenBrainzProvider),
    ref.watch(libreFmProvider),
  ]),
);

/// Bumped after connecting / disconnecting so Settings and Stats refresh.
final extraScrobblersRevisionProvider = StateProvider<int>((_) => 0);

/// Lifetime listen count per connected service, for the Stats strips.
final extraScrobbleCountProvider = FutureProvider.autoDispose
    .family<int?, String>((ref, name) async {
      ref.watch(extraScrobblersRevisionProvider);
      final s = ref
          .watch(extraScrobblersProvider)
          .services
          .firstWhere((s) => s.name == name);
      return s.listenCount();
    });
