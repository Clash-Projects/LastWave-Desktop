import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lastwave_desktop/features/scrobblers/extra_scrobblers.dart';
import 'package:lastwave_desktop/ui/settings/settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Prefs prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await Prefs.load();
  });

  test('settings rail contains Accounts entry', () {
    final accounts = waveSettingsSections.firstWhere((s) => s.$1 == 'accounts');
    expect(accounts.$2, 'Accounts');
  });

  test('normalizeServer adds https and strips trailing slash', () {
    expect(normalizeServer('libre.fm', 'fallback'), 'https://libre.fm');
    expect(normalizeServer('https://libre.fm/', 'fallback'), 'https://libre.fm');
    expect(normalizeServer('http://my-gnufm.local:8080///', 'fallback'),
        'http://my-gnufm.local:8080');
    expect(normalizeServer('', 'https://libre.fm'), 'https://libre.fm');
  });

  test('LibreFmScrobbler sign hashes parameters in alphabetical order', () {
    final sig = LibreFmScrobbler.sign({
      'username': 'testuser',
      'method': 'auth.getMobileSession',
      'api_key': '12345678901234567890123456789012',
    }, 'mysecret');
    expect(sig.length, 32);
    // Same params always give exact same signature
    expect(
      sig,
      LibreFmScrobbler.sign({
        'api_key': '12345678901234567890123456789012',
        'method': 'auth.getMobileSession',
        'username': 'testuser',
      }, 'mysecret'),
    );
  });

  test('LibreFmScrobbler parseXml handles key, user, error and status', () {
    final successXml = '''
      <lfm status="ok">
        <session>
          <name>testuser</name>
          <key>sessionkey12345</key>
        </session>
      </lfm>
    ''';
    final parsedSuccess = LibreFmScrobbler.parseXml(successXml);
    expect(parsedSuccess['session']['key'], 'sessionkey12345');
    expect(parsedSuccess['session']['name'], 'testuser');
    expect(parsedSuccess['status'], 'ok');

    final errorXml = '''
      <lfm status="failed">
        <error code="4">Invalid authentication token supplied</error>
      </lfm>
    ''';
    final parsedError = LibreFmScrobbler.parseXml(errorXml);
    expect(parsedError['error'], 'Invalid authentication token supplied');
    expect(parsedError['message'], 'Invalid authentication token supplied');

    final infoXml = '''
      <lfm status="ok">
        <user>
          <playcount>425</playcount>
        </user>
      </lfm>
    ''';
    final parsedInfo = LibreFmScrobbler.parseXml(infoXml);
    expect(parsedInfo['user']['playcount'], '425');
  });

  test('ListenBrainz cleanToken strips prefixes and quotes', () {
    expect(ListenBrainzScrobbler.cleanToken('  my-token-123  '), 'my-token-123');
    expect(ListenBrainzScrobbler.cleanToken('Token my-token-123'), 'my-token-123');
    expect(ListenBrainzScrobbler.cleanToken('token my-token-123'), 'my-token-123');
    expect(ListenBrainzScrobbler.cleanToken('Bearer my-token-123'), 'my-token-123');
    expect(ListenBrainzScrobbler.cleanToken('"my-token-123"'), 'my-token-123');
    expect(ListenBrainzScrobbler.cleanToken("'my-token-123'"), 'my-token-123');
  });

  group('independent provider queues', () {
    const first = Listen(artist: 'Artist', track: 'First', startedAtSec: 100);
    const second = Listen(artist: 'Artist', track: 'Second', startedAtSec: 200);

    test('concurrent submits serialize one provider and remove only its head', () async {
      final release = Completer<bool>();
      final service = _FakeScrobbler('one', (listen, attempt) {
        return attempt == 1 ? release.future : Future.value(true);
      });
      final scrobblers = ExtraScrobblers([service]);
      scrobblers.submit(first);
      await pumpEventQueue();
      scrobblers.submit(second);
      await pumpEventQueue();

      try {
        expect(service.submitted, [first]);
        expect(service.maximumActive, 1);
      } finally {
        release.complete(true);
        await pumpEventQueue();
      }

      expect(service.submitted, [first, second]);
      expect(service.maximumActive, 1);
    });

    test('retrying the same listen only retries the failed provider', () async {
      final healthy = _FakeScrobbler('healthy', (_, __) async => true);
      final failing = _FakeScrobbler('failing', (_, attempt) async => attempt > 1);
      final scrobblers = ExtraScrobblers([healthy, failing]);

      scrobblers.submit(first);
      await pumpEventQueue();
      scrobblers.submit(first);
      await pumpEventQueue();

      expect(healthy.submitted, [first]);
      expect(failing.submitted, [first, first]);
    });

    test('dedup normalizes metadata but allows a distinct playback timestamp', () async {
      const duplicate = Listen(
        artist: ' artist ',
        track: ' FIRST ',
        album: 'Different edition',
        startedAtSec: 100,
      );
      const replay = Listen(artist: 'Artist', track: 'First', startedAtSec: 101);
      final service = _FakeScrobbler('one', (_, __) async => true);
      final scrobblers = ExtraScrobblers([service]);

      scrobblers.submit(first);
      await pumpEventQueue();
      scrobblers.submit(duplicate);
      await pumpEventQueue();
      scrobblers.submit(replay);
      await pumpEventQueue();

      expect(service.submitted, [first, replay]);
    });

    test('a stalled provider does not hold up another provider', () async {
      final release = Completer<bool>();
      final slow = _FakeScrobbler('slow', (_, attempt) {
        return attempt == 1 ? release.future : Future.value(true);
      });
      final fast = _FakeScrobbler('fast', (_, __) async => true);
      final scrobblers = ExtraScrobblers([slow, fast]);

      try {
        scrobblers.submit(first);
        await pumpEventQueue();
        expect(fast.submitted, [first]);
        expect(fast.active, 0);
        expect(slow.active, 1);

        scrobblers.submit(second);
        await pumpEventQueue();
        expect(fast.submitted, [first, second]);
        expect(fast.active, 0);
      } finally {
        release.complete(true);
        await pumpEventQueue();
      }
    });
  });

  group('ListenBrainz HTTP outcomes', () {
    const rejected = Listen(artist: 'Artist', track: 'Rejected', startedAtSec: 100);
    const following = Listen(artist: 'Artist', track: 'Following', startedAtSec: 200);

    test('HTTP 400 discards one invalid listen without blocking the next', () async {
      await prefs.setListenBrainz(token: 'token', user: 'user', server: '');
      final adapter = _ResponseAdapter((request, attempt) {
        return _response(attempt == 1 ? 400 : 200, attempt == 1
            ? '{"error":"Invalid metadata"}' : '{"status":"ok"}');
      });
      final client = ListenBrainzScrobbler(prefs, Dio()..httpClientAdapter = adapter);
      final scrobblers = ExtraScrobblers([client]);

      scrobblers.submit(rejected);
      await pumpEventQueue();
      scrobblers.submit(following);
      await pumpEventQueue();

      expect(adapter.listenTracks, ['Rejected', 'Following']);
    });

    for (final status in [401, 429, 503]) {
      test('HTTP $status retains a listen for retry before the following listen', () async {
        await prefs.setListenBrainz(token: 'token', user: 'user', server: '');
        final adapter = _ResponseAdapter((request, attempt) {
          return _response(attempt == 1 ? status : 200, attempt == 1
              ? '{"error":"Try later"}' : '{"status":"ok"}');
        });
        final client = ListenBrainzScrobbler(prefs, Dio()..httpClientAdapter = adapter);
        final scrobblers = ExtraScrobblers([client]);

        scrobblers.submit(rejected);
        await pumpEventQueue();
        scrobblers.submit(following);
        await pumpEventQueue();

        expect(adapter.listenTracks, ['Rejected', 'Rejected', 'Following']);
      });
    }

    test('a success-shaped token response on HTTP 503 does not save credentials', () async {
      final adapter = _ResponseAdapter((_, __) => _response(
          503, '{"valid":true,"user_name":"user"}'));
      final client = ListenBrainzScrobbler(prefs, Dio()..httpClientAdapter = adapter);

      expect(await client.connect('token'), isNotNull);
      expect(prefs.listenBrainzToken, isEmpty);
      expect(prefs.listenBrainzUser, isEmpty);
    });
  });

  group('Libre.fm response validation', () {
    const listen = Listen(artist: 'Artist', track: 'Track', startedAtSec: 100);
    const jsonSession = '{"session":{"name":"user","key":"session-key"}}';
    const xmlSession = '<lfm status="ok"><session><name>user</name><key>session-key</key></session></lfm>';
    const jsonScrobble = '{"scrobbles":{"@attr":{"accepted":"1","ignored":"0"}}}';
    const xmlScrobble = '<lfm status="ok"><scrobbles accepted="1" ignored="0"/></lfm>';

    for (final format in ['JSON', 'XML']) {
      for (final status in [401, 429, 503]) {
        test('$format session on HTTP $status does not sign in or save credentials', () async {
          final adapter = _ResponseAdapter((_, __) => _response(
              status, format == 'JSON' ? jsonSession : xmlSession));
          final client = LibreFmScrobbler(prefs, Dio()..httpClientAdapter = adapter);

          expect(await client.connect('user', 'password'), isNotNull);
          expect(prefs.libreFmSession, isEmpty);
          expect(prefs.libreFmUser, isEmpty);
          expect(prefs.libreFmServer, isEmpty);
        });

        test('$format scrobble response on HTTP $status is not successful', () async {
          await prefs.setLibreFm(session: 'session', user: 'user', server: '');
          final adapter = _ResponseAdapter((_, __) => _response(
              status, format == 'JSON' ? jsonScrobble : xmlScrobble));
          final client = LibreFmScrobbler(prefs, Dio()..httpClientAdapter = adapter);

          expect(await client.submit(listen), isFalse);
        });
      }

      test('HTTP 200 with a valid $format scrobble acknowledgement succeeds', () async {
        await prefs.setLibreFm(session: 'session', user: 'user', server: '');
        final adapter = _ResponseAdapter((_, __) => _response(
            200, format == 'JSON' ? jsonScrobble : xmlScrobble));
        final client = LibreFmScrobbler(prefs, Dio()..httpClientAdapter = adapter);

        expect(await client.submit(listen), isTrue);
      });
    }

    for (final code in [91, 99]) {
      test('XML ignored code $code is ${code == 91 ? 'consumed as a duplicate' : 'retained for retry'}', () async {
        await prefs.setLibreFm(session: 'session', user: 'user', server: '');
        final body = '<lfm status="ok"><scrobbles accepted="0" ignored="1">'
            '<scrobble><ignoredMessage code="$code">Ignored</ignoredMessage>'
            '</scrobble></scrobbles></lfm>';
        final adapter = _ResponseAdapter((_, __) => _response(200, body));
        final client = LibreFmScrobbler(prefs, Dio()..httpClientAdapter = adapter);

        expect(await client.submit(listen), code == 91);
      });
    }

    for (final body in [
      '{}',
      '<html><body>Welcome</body></html>',
      '<lfm status="ok"/>',
      '{"scrobbles":{"@attr":{"accepted":"0","ignored":"0"}}}',
    ]) {
      test('HTTP 200 without a scrobble acknowledgement is not successful: $body', () async {
        await prefs.setLibreFm(session: 'session', user: 'user', server: '');
        final adapter = _ResponseAdapter((_, __) => _response(200, body));
        final client = LibreFmScrobbler(prefs, Dio()..httpClientAdapter = adapter);

        expect(await client.submit(listen), isFalse);
      });
    }
  });

}

class _FakeScrobbler implements ExtraScrobbler {
  _FakeScrobbler(this.name, this.onSubmit);

  @override
  final String name;
  final Future<bool> Function(Listen, int) onSubmit;
  final submitted = <Listen>[];
  int active = 0;
  int maximumActive = 0;

  @override
  bool get connected => true;
  @override
  String get username => 'user';
  @override
  Uri get profileUrl => Uri.parse('https://example.com/user');
  @override
  Future<int?> listenCount() async => null;
  @override
  Future<bool> nowPlaying(Listen listen) async => true;

  @override
  Future<bool> submit(Listen listen) async {
    submitted.add(listen);
    active++;
    if (active > maximumActive) maximumActive = active;
    try {
      return await onSubmit(listen, submitted.length);
    } finally {
      active--;
    }
  }
}

class _ResponseAdapter implements HttpClientAdapter {
  _ResponseAdapter(this.respond);
  final FutureOr<ResponseBody> Function(RequestOptions, int) respond;
  final requests = <RequestOptions>[];

  List<String> get listenTracks => requests.map((request) {
    final body = jsonDecode(request.data as String) as Map<String, dynamic>;
    final payload = body['payload'] as List;
    return payload.single['track_metadata']['track_name'] as String;
  }).toList();

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return await respond(options, requests.length);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _response(int status, String body) => ResponseBody.fromString(
    body, status,
    headers: {Headers.contentTypeHeader: [body.startsWith('<') ? 'application/xml' : 'application/json']});
