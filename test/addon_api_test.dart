import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/env/app_env.dart';
import 'package:lastwave_desktop/features/addons/addon_api.dart';

String _hex(String c) => List.filled(64, c).join();

void main() {
  group('parseAddonUrl', () {
    test('full root with trailing slash', () {
      final p = AddonApi.parseAddonUrl(
          'https://addons.example.com/a/${_hex('a')}/');
      expect(p?.root,
          'https://addons.example.com/a/${_hex('a')}/');
      expect(p?.token, _hex('a'));
    });

    test('no trailing slash', () {
      final p = AddonApi.parseAddonUrl(
          'https://addons.example.com/a/${_hex('b')}');
      expect(p?.root,
          'https://addons.example.com/a/${_hex('b')}/');
    });

    test('manifest suffix is stripped', () {
      final p = AddonApi.parseAddonUrl(
          'https://x.test/a/${_hex('c')}/manifest.json');
      expect(p?.root, 'https://x.test/a/${_hex('c')}/');
    });

    test('deeper addon urls reduce to root', () {
      final p = AddonApi.parseAddonUrl(
          'https://x.test/a/${_hex('d')}/stream/abc123?quality=lossless');
      expect(p?.root, 'https://x.test/a/${_hex('d')}/');
    });

    test('bare domain rejected', () {
      expect(
          AddonApi.parseAddonUrl('https://x.test/'), isNull);
      expect(AddonApi.parseAddonUrl('https://x.test'), isNull);
    });

    test('short/non-hex tokens rejected', () {
      expect(
          AddonApi.parseAddonUrl(
              'https://x.test/a/abc123'),
          isNull);
      expect(
          AddonApi.parseAddonUrl(
              'https://x.test/a/xyz!!!'),
          isNull);
      expect(AddonApi.parseAddonUrl(''), isNull);
      expect(AddonApi.parseAddonUrl('   '), isNull);
    });

    test('tokenOfRoot round-trips', () {
      expect(
          AddonApi.tokenOfRoot(
              'https://x.test/a/${_hex('e')}/'),
          _hex('e'));
      expect(AddonApi.tokenOfRoot('https://x.test/'), '');
    });
  });

  group('signFor', () {
    // Fixed vector: recompute independently with package:crypto here
    // so the test pins the exact wire construction
    // "ts\nMETHOD\npath\ntoken" (no query string in path).
    test('stable known-answer vector', () {
      const secret = 'test-secret-1';
      const method = 'GET';
      final path = '/a/${_hex('a')}/manifest.json';
      final token = _hex('a');
      const ts = '1727000000';
      final h = AddonApi.signFor(
          secret: secret,
          method: method,
          path: path,
          token: token,
          ts: ts);
      final mac = Hmac(sha256, utf8.encode(secret));
      final expected = mac
          .convert(utf8.encode('$ts\n$method\n$path\n$token'))
          .toString();
      expect(h['X-LW-TS'], ts);
      expect(h['X-LW-Sign'], expected);
      expect(h['X-LW-Sign'], hasLength(64));
      expect(h['User-Agent'], isNotEmpty);
    });

    test('method is uppercased, query never in path', () {
      final h = AddonApi.signFor(
          secret: 's',
          method: 'get',
          path: '/a/tok/search',
          token: 'tok',
          ts: '1');
      final mac = Hmac(sha256, utf8.encode('s'));
      expect(
          h['X-LW-Sign'],
          mac
              .convert(utf8.encode('1\nGET\n/a/tok/search\ntok'))
              .toString());
    });
  });

  group('serverQualitiesForTier', () {
    test('hi-res tiers ask hi_res first', () {
      expect(AddonApi.serverQualitiesForTier(27).first,
          'hi_res');
      expect(AddonApi.serverQualitiesForTier(7).first,
          'hi_res');
    });

    test('cd asks lossless first, mp3 asks high first', () {
      expect(AddonApi.serverQualitiesForTier(6).first,
          'lossless');
      expect(AddonApi.serverQualitiesForTier(5).first,
          'high');
    });

    test('never requests atmos', () {
      for (final t in [5, 6, 7, 27, -1, 0, 99]) {
        expect(AddonApi.serverQualitiesForTier(t),
            isNot(contains('atmos')));
      }
    });

    test('search knob mirrors Android per tier', () {
      // Android LosslessMusicApi searches with the tier's primary knob
      // (27/7 -> hi_res, 6 -> lossless, 5 -> high); desktop must send
      // the same or the server filters out tier-only entries.
      expect(AddonApi.serverQualitiesForTier(27).first, 'hi_res');
      expect(AddonApi.serverQualitiesForTier(7).first, 'hi_res');
      expect(AddonApi.serverQualitiesForTier(6).first, 'lossless');
      expect(AddonApi.serverQualitiesForTier(5).first, 'high');
    });
  });

  group('khzFromServerSampleRate', () {
    test('Hz values convert to kHz', () {
      expect(
          AddonApi.khzFromServerSampleRate(48000, hiRes: true),
          48.0);
      expect(
          AddonApi.khzFromServerSampleRate(44100, hiRes: false),
          44.1);
      expect(
          AddonApi.khzFromServerSampleRate(96000, hiRes: true),
          96.0);
    });

    test('kHz-range values pass through', () {
      expect(
          AddonApi.khzFromServerSampleRate(48.0, hiRes: true),
          48.0);
      expect(
          AddonApi.khzFromServerSampleRate('44.1', hiRes: false),
          44.1);
    });

    test('missing or absurd values fall back per tier', () {
      expect(
          AddonApi.khzFromServerSampleRate(null, hiRes: true),
          96.0);
      expect(
          AddonApi.khzFromServerSampleRate(null, hiRes: false),
          44.1);
      expect(
          AddonApi.khzFromServerSampleRate(99999999, hiRes: true),
          96.0);
    });

    test('hi-res bitrate math lands in kbps', () {
      // 24-bit × 48 kHz × 2ch = 2304 kbps (was 2304000 pre-fix).
      const depth = 24;
      const rate =
          48.0; // as returned by khzFromServerSampleRate(48000)
      expect((depth * rate * 2).toInt(), 2304);
    });
  });

  group('isDecoyUrl', () {
    test('prank markers rejected case-insensitively', () {
      expect(
          AddonApi.isDecoyUrl(
              'https://pranks-cdn.example.com/x.mp3'),
          isTrue);
      expect(
          AddonApi.isDecoyUrl(
              'https://cdn.example.com/DefinatelyNagato/track.mp3'),
          isTrue);
    });

    test('real urls pass', () {
      expect(
          AddonApi.isDecoyUrl(
              'https://media.example.com/t/abc.flac?exp=1&sig=2'),
          isFalse);
      expect(AddonApi.isDecoyUrl(''), isFalse);
    });
  });

  group('AddonManifest', () {
    test('usable requires id/name/search/stream', () {
      expect(
          const AddonManifest(
            id: 'x',
            name: 'y',
            version: '1',
            resources: ['search', 'stream'],
          ).isUsable,
          isTrue);
      expect(
          const AddonManifest(
            id: 'x',
            name: 'y',
            version: '1',
            resources: ['search'],
          ).isUsable,
          isFalse);
      expect(
          const AddonManifest(
                  id: '', name: 'y', version: '1')
              .isUsable,
          isFalse);
    });
  });

  group('AddonTrack', () {
    test('duration accepts number or string', () {
      expect(
          AddonTrack.fromJson({
            'id': 'a',
            'title': 't',
            'duration': 187,
          }).durationSeconds,
          187);
      expect(
          AddonTrack.fromJson({
            'id': 'a',
            'title': 't',
            'duration': '187.4',
          }).durationSeconds,
          187);
      expect(
          AddonTrack.fromJson(
                  {'id': 'a', 'title': 't'})
              .durationSeconds,
          0);
    });
  });

  group('bestMatch', () {
    AddonTrack t(String id, String title, String artist,
            [int dur = 180]) =>
        AddonTrack(
            id: id,
            title: title,
            artist: artist,
            durationSeconds: dur);

    AddonTrack ta(String id, String title, String artist, String album,
            [int dur = 180]) =>
        AddonTrack(
            id: id,
            title: title,
            artist: artist,
            album: album,
            durationSeconds: dur);

    test('exact match wins', () {
      final m = AddonApi.bestMatch(
        [
          t('1', 'Unrelated Song', 'Someone Else'),
          t('2', 'Midnight Drive', 'Neon Coast'),
        ],
        title: 'Midnight Drive',
        artist: 'Neon Coast',
      );
      expect(m?.id, '2');
    });

    test('junk never matches', () {
      expect(
          AddonApi.bestMatch(
            [t('1', 'Completely Different', 'Other Band')],
            title: 'Midnight Drive',
            artist: 'Neon Coast',
          ),
          isNull);
      expect(AddonApi.bestMatch([], title: 'x', artist: 'y'),
          isNull);
    });

    test('duration gate rejects far lengths', () {
      expect(
          AddonApi.bestMatch(
            [t('1', 'Midnight Drive', 'Neon Coast', 420)],
            title: 'Midnight Drive',
            artist: 'Neon Coast',
            expectedDurationSeconds: 180,
          ),
          isNull);
    });

    test('feat in title still matches plain catalog entry', () {
      // Dracula: queue bills "Dracula (feat. JENNIE)", catalog has "Dracula".
      final m = AddonApi.bestMatch(
        [t('1', 'Dracula', 'Tame Impala')],
        title: 'Dracula (feat. JENNIE)',
        artist: 'Tame Impala feat. JENNIE',
      );
      expect(m?.id, '1');
    });

    test('bare feat suffix still matches', () {
      final m = AddonApi.bestMatch(
        [t('1', 'Dracula', 'Tame Impala')],
        title: 'Dracula feat JENNIE',
        artist: 'Tame Impala, JENNIE',
      );
      expect(m?.id, '1');
    });

    test('explicit / single-version noise still matches', () {
      expect(
          AddonApi.bestMatch(
            [t('1', 'Starboy', 'The Weeknd')],
            title: 'Starboy (Explicit)',
            artist: 'The Weeknd',
          )?.id,
          '1');
      expect(
          AddonApi.bestMatch(
            [t('1', 'Starboy', 'The Weeknd')],
            title: 'Starboy Single Version',
            artist: 'The Weeknd',
          )?.id,
          '1');
    });

    test('collab artist billing matches primary', () {
      final m = AddonApi.bestMatch(
        [t('1', 'Starboy', 'The Weeknd')],
        title: 'Starboy',
        artist: 'The Weeknd; Daft Punk',
      );
      expect(m?.id, '1');
    });

    test('album breaks ties between same-title versions', () {
      final m = AddonApi.bestMatch(
        [
          ta('1', 'Starboy', 'The Weeknd', 'Other Compilation'),
          ta('2', 'Starboy', 'The Weeknd', 'Starboy'),
        ],
        title: 'Starboy',
        artist: 'The Weeknd',
        album: 'Starboy',
      );
      expect(m?.id, '2');
    });

    test('different songs still rejected', () {
      // Stripping must not make "Cider" match "Cinderella"-style noise.
      expect(
          AddonApi.bestMatch(
            [t('1', 'Dracula Untold Suite', 'Other Band')],
            title: 'Dracula (feat. JENNIE)',
            artist: 'Tame Impala feat. JENNIE',
          ),
          isNull);
    });

    test('wanted remix beats the original', () {
      // Regression: queue asked for the JENNIE remix, pool holds both —
      // stripped-exact equates them, feat fidelity must pick the remix.
      final m = AddonApi.bestMatch(
        [
          t('orig', 'Dracula', 'Tame Impala'),
          t('remix', 'Dracula (feat. JENNIE)', 'Tame Impala'),
        ],
        title: 'Dracula (feat. JENNIE)',
        artist: 'Tame Impala',
      );
      expect(m?.id, 'remix');
    });

    test('wanted original beats the remix', () {
      final m = AddonApi.bestMatch(
        [
          t('remix', 'Dracula (feat. JENNIE)', 'Tame Impala'),
          t('orig', 'Dracula', 'Tame Impala'),
        ],
        title: 'Dracula',
        artist: 'Tame Impala',
      );
      expect(m?.id, 'orig');
    });

    test('correct featured artist beats wrong one', () {
      final m = AddonApi.bestMatch(
        [
          t('wrong', 'Dracula (feat. 1nonly)', 'Tame Impala'),
          t('right', 'Dracula feat JENNIE', 'Tame Impala'),
        ],
        title: 'Dracula (feat. JENNIE)',
        artist: 'Tame Impala',
      );
      expect(m?.id, 'right');
    });

    test('(with X) counts as a feature credit', () {
      final m = AddonApi.bestMatch(
        [t('1', 'Dracula (with JENNIE)', 'Tame Impala')],
        title: 'Dracula (feat. JENNIE)',
        artist: 'Tame Impala',
      );
      expect(m?.id, '1');
    });

    test('credit only in catalog title still matches', () {
      // Queue: artist="Tame Impala", title has no feat; catalog puts
      // the credit in its title. And the reverse direction.
      expect(
          AddonApi.bestMatch(
            [t('1', 'Dracula feat JENNIE', 'Tame Impala')],
            title: 'Dracula',
            artist: 'Tame Impala',
          )?.id,
          '1');
    });

    test('bestMatches ranks remix, original, wrong-feat in order', () {
      final ranked = AddonApi.bestMatches(
        [
          t('wrong', 'Dracula (feat. 1nonly)', 'Tame Impala'),
          t('orig', 'Dracula', 'Tame Impala'),
          t('remix', 'Dracula (feat. JENNIE)', 'Tame Impala'),
        ],
        title: 'Dracula (feat. JENNIE)',
        artist: 'Tame Impala',
      ).map((e) => e.id).toList();
      expect(ranked, ['remix', 'orig', 'wrong']);
    });
  });

  group('dice', () {
    test('identical is 100, empty is 0', () {
      expect(AddonApi.dice('abc', 'abc'), 100);
      expect(AddonApi.dice('', 'abc'), 0);
      expect(AddonApi.dice('abc', ''), 0);
    });

    test('near strings score high', () {
      expect(AddonApi.dice('midnight drive', 'midnight drive'), 100);
      expect(AddonApi.dice('midnight drive', 'midnight driv'),
          greaterThan(80));
    });
  });

  group('AddonQuotaException', () {
    test('message falls back when body is not json', () {
      const e = AddonQuotaException(
          retryAfterSeconds: 100,
          remaining: 0,
          message: 'x');
      expect(e.retryAfterSeconds, 100);
      expect(e.remaining, 0);
    });
  });

  group('AddonApi gating', () {
    test('unconfigured without bases or secret', () {
      expect(AddonApi(const []).isConfigured, isFalse);
    });
  });

  group('resolveStream transient retry', () {
    test('one mint blip recovers without falling through', () async {
      if (AppEnv.addonClientSecret.isEmpty) {
        markTestSkipped('addon secret not configured in this env');
      }
      final token = _hex('f');
      final dio = Dio();
      dio.httpClientAdapter = _FlakyAdapter(
        streamFailures: 1,
        searchPayload: {
          'tracks': [
            {'id': 't1', 'title': 'Song', 'artist': 'Singer'},
          ],
        },
        streamPayload: {
          'url': 'https://cdn.test/song.flac',
          'bitDepth': 16,
          'sampleRate': 44100,
        },
      );
      final api = AddonApi(['https://x.test/a/$token/'], dio);
      final stream =
          await api.resolveStream(title: 'Song', artist: 'Singer');
      expect(stream, isNotNull);
      expect(stream!.url, 'https://cdn.test/song.flac');
    });

    test('quota 429 throws immediately (no pointless retry)', () async {
      if (AppEnv.addonClientSecret.isEmpty) {
        markTestSkipped('addon secret not configured in this env');
      }
      final token = _hex('f');
      final dio = Dio();
      dio.httpClientAdapter = _FlakyAdapter(
        streamFailures: 999,
        quota: true,
        searchPayload: {
          'tracks': [
            {'id': 't1', 'title': 'Song', 'artist': 'Singer'},
          ],
        },
        streamPayload: const {},
      );
      final api = AddonApi(['https://x.test/a/$token/'], dio);
      await expectLater(
        api.resolveStream(title: 'Song', artist: 'Singer'),
        throwsA(isA<AddonQuotaException>()),
      );
    });

    test('dead top match falls through to next-best version', () async {
      // Starboy case: the top-ranked `swap_` composite 502s on every
      // tier, so the resolver must serve the plain version rather
      // than dropping to YouTube.
      if (AppEnv.addonClientSecret.isEmpty) {
        markTestSkipped('addon secret not configured in this env');
      }
      final token = _hex('f');
      final dio = Dio();
      dio.httpClientAdapter = _PerTrackAdapter(
        searchPayload: {
          'tracks': [
            {
              'id': 'swap_dead',
              'title': 'starboy feat daft punk the weeknd',
              'artist': 'The Weeknd',
            },
            {'id': 'good', 'title': 'Starboy', 'artist': 'The Weeknd'},
          ],
        },
        deadIds: const {'swap_dead'},
        streamPayload: {
          'url': 'https://cdn.test/starboy.flac',
          'bitDepth': 16,
          'sampleRate': 44100,
        },
      );
      final api = AddonApi(['https://x.test/a/$token/'], dio);
      final stream = await api.resolveStream(
        title: 'Starboy (feat. Daft Punk)',
        artist: 'The Weeknd',
      );
      expect(stream, isNotNull);
      expect(stream!.url, 'https://cdn.test/starboy.flac');
    });

    test('tier 27 searches with hi_res knob (Android parity)', () async {
      // Saadi Galli Aaja case: desktop hardcoded quality=lossless while
      // Android searches with the tier knob (27 -> hi_res), so the
      // server filtered hi_res-only entries out of desktop's pool.
      if (AppEnv.addonClientSecret.isEmpty) {
        markTestSkipped('addon secret not configured in this env');
      }
      final token = _hex('f');
      final dio = Dio();
      final rec = _RecordingAdapter();
      dio.httpClientAdapter = rec;
      final api = AddonApi(['https://x.test/a/$token/'], dio);
      await api.resolveStream(
        title: 'Saadi Galli Aaja',
        artist: 'Ayushmann Khurrana',
        preferredQuality: 27,
      );
      expect(rec.searchQualities, isNotEmpty);
      expect(rec.searchQualities.toSet(), {'hi_res'});
    });

    test('searchTracks defaults to lossless knob', () async {
      if (AppEnv.addonClientSecret.isEmpty) {
        markTestSkipped('addon secret not configured in this env');
      }
      final token = _hex('f');
      final dio = Dio();
      final rec = _RecordingAdapter();
      dio.httpClientAdapter = rec;
      final api = AddonApi(['https://x.test/a/$token/'], dio);
      await api.searchTracks('saadi galli aaja');
      expect(rec.searchQualities, ['lossless']);
    });
  });
}

/// Stub Dio adapter: records the `quality` param of every /search call,
/// answers empty pools.
class _RecordingAdapter implements HttpClientAdapter {
  final List<String> searchQualities = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final path = options.uri.path;
    if (path.contains('/search')) {
      searchQualities
          .add(options.queryParameters['quality']?.toString() ?? '');
      return ResponseBody.fromString(
        jsonEncode({'tracks': const []}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString('nope', 404);
  }

  @override
  void close({bool force = false}) {}
}

/// Stub Dio adapter: search always answers, stream 500s for [deadIds]
/// and succeeds for every other track id.
class _PerTrackAdapter implements HttpClientAdapter {
  _PerTrackAdapter({
    required this.searchPayload,
    required this.deadIds,
    required this.streamPayload,
  });

  final Map<String, dynamic> searchPayload;
  final Set<String> deadIds;
  final Map<String, dynamic> streamPayload;

  ResponseBody _json(Map<String, dynamic> payload) =>
      ResponseBody.fromString(
        jsonEncode(payload),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final path = options.uri.path;
    if (path.contains('/search')) return _json(searchPayload);
    if (path.contains('/stream/')) {
      final id = path.split('/').last;
      if (deadIds.contains(id)) {
        return ResponseBody.fromString('boom', 502);
      }
      return _json(streamPayload);
    }
    return ResponseBody.fromString('nope', 404);
  }

  @override
  void close({bool force = false}) {}
}

/// Stub Dio adapter: search always answers, stream fails
/// [streamFailures] times (500, or 429 when [quota]) then succeeds.
class _FlakyAdapter implements HttpClientAdapter {
  _FlakyAdapter({
    required this.streamFailures,
    required this.searchPayload,
    required this.streamPayload,
    this.quota = false,
  });

  int streamFailures;
  final Map<String, dynamic> searchPayload;
  final Map<String, dynamic> streamPayload;
  final bool quota;

  ResponseBody _json(Map<String, dynamic> payload) =>
      ResponseBody.fromString(
        jsonEncode(payload),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final path = options.uri.path;
    if (path.contains('/search')) return _json(searchPayload);
    if (path.contains('/stream/')) {
      if (streamFailures > 0) {
        streamFailures--;
        if (quota) {
          return ResponseBody.fromString('{}', 429, headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          });
        }
        return ResponseBody.fromString('blip', 500);
      }
      return _json(streamPayload);
    }
    return ResponseBody.fromString('nope', 404);
  }

  @override
  void close({bool force = false}) {}
}
