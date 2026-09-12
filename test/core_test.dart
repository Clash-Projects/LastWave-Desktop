import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/network/lastfm_crypto.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';
import 'package:lastwave_desktop/features/lossless/lossless_api.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_models.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_repository.dart';

void main() {
  group('LastFmSigner', () {
    test('sign is deterministic and order-independent', () {
      final a = LastFmSigner.sign(
          {'b': '2', 'a': '1'}, 'secret');
      final b = LastFmSigner.sign(
          {'a': '1', 'b': '2'}, 'secret');
      expect(a, equals(b));
      expect(a.length, 32);
    });

    test('sign skips format/callback/api_sig', () {
      final a = LastFmSigner.sign({'a': '1'}, 's');
      final b = LastFmSigner.sign(
          {'a': '1', 'format': 'json', 'api_sig': 'x'},
          's');
      expect(a, equals(b));
    });

    test('sapisidHash format', () {
      final h = LastFmSigner.sapisidHash(
          'abc123', 'https://music.youtube.com');
      expect(h.startsWith('SAPISIDHASH '), isTrue);
      expect(h.split('_').length, 2);
    });
  });

  group('Lossless quality order', () {
    test('preferred first, higher tiers next', () {
      expect(
          LosslessMusicApi.getQualityAttemptOrder(6),
          equals([6, 7, 27, 5]));
      expect(
          LosslessMusicApi.getQualityAttemptOrder(27),
          equals([27, 7, 6, 5]));
      expect(
          LosslessMusicApi.getQualityAttemptOrder(5),
          equals([5, 6, 7, 27]));
      expect(
          LosslessMusicApi.getQualityAttemptOrder(-1),
          isEmpty);
    });

    test('normalization strips artist prefix', () {
      expect(
          LosslessMusicApi.normalizeTitle('Adele - Hello'),
          equals('hello'));
    });
  });

  group('InnerTube matching', () {
    test('similarity is 100 for identical strings', () {
      expect(
          InnerTubeMusicApi.similarity('hello', 'hello'),
          100);
    });

    test('similarity tolerates small differences', () {
      expect(
          InnerTubeMusicApi.similarity(
              'hello', 'hello (official video)'),
          lessThan(100));
      expect(
          InnerTubeMusicApi.similarity('hello', 'hello'),
          greaterThan(70));
    });

    test('normalize strips punctuation', () {
      expect(InnerTubeMusicApi.normalize('Hello! (Official)'),
          'hello official');
    });
  });

  group('LRC parsing', () {
    test('parses timestamps and offset', () {
      const lrc =
          '[offset:+500]\n[00:01.00]first\n[00:02.50][00:05.00]second\n';
      final lines = parseLrc(lrc);
      expect(lines.length, 3);
      expect(lines[0].timeMs, 1500);
      expect(lines[0].text, 'first');
      expect(lines[1].timeMs, 3000);
      expect(lines[2].timeMs, 5500);
    });

    test('empty input yields no lines', () {
      expect(parseLrc(''), isEmpty);
    });
  });

  group('TTML parsing', () {
    test('parses words into syllables', () {
      const ttml = '<p begin="1.0" end="3.0">'
          '<span begin="1.0" end="2.0">Hello</span>'
          '<span begin="2.0" end="3.0">world</span></p>';
      final lines =
          LyricsRepository.parseTtml(ttml);
      expect(lines.length, 1);
      expect(lines.first.text, 'Hello world');
      expect(lines.first.syllables.length, 2);
      expect(lines.first.timeMs, 1000);
    });
  });

  group('RTL detection', () {
    test('detects Arabic text', () {
      expect(isRtlText('مرحبا بالعالم'), isTrue);
      expect(isRtlText('Hello world'), isFalse);
    });
  });
}
