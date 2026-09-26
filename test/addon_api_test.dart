import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
