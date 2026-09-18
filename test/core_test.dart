import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/network/lastfm_crypto.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';
import 'package:lastwave_desktop/features/innertube/signature_decipher.dart';
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

    test('normalization collapses apostrophes and explicit tags', () {
      expect(
          LosslessMusicApi.normalizeTitle("I Can't Save You"),
          equals(LosslessMusicApi.normalizeTitle('I Cant Save You')));
      expect(
          LosslessMusicApi.normalizeTitle('The Hills (Explicit)'),
          equals('the hills'));
    });

    test('titlesMatch accepts YouTube vs Qobuz wording', () {
      expect(
          LosslessMusicApi.titlesMatch(
              "I Can't Save You (Interlude)",
              'I Cant Save You (Interlude)'),
          isTrue);
      expect(
          LosslessMusicApi.titlesMatch('Hello', 'Goodbye'),
          isFalse);
    });

    test('titlesMatch allows a one-letter catalog typo', () {
      expect(
          LosslessMusicApi.titlesMatch('Nube Ras', 'Numbe Ras'),
          isTrue);
    });
  });

  group('InnerTube matching (Android parity)', () {
    test('similarity is 100 for identical strings', () {
      expect(
          InnerTubeMusicApi.similarity('hello', 'hello'),
          100);
    });

    test('noise words do not hurt similarity', () {
      // official/video are MATCH_NOISE_WORDS: token sets equal.
      expect(
          InnerTubeMusicApi.similarity(
              'hello', 'hello (official video)'),
          100);
    });

    test('unrelated strings score 0', () {
      expect(
          InnerTubeMusicApi.similarity('hello', 'goodbye'),
          0);
    });

    test('substring with enough overlap scores >= 85', () {
      expect(
          InnerTubeMusicApi.similarity(
              'midnight memories', 'midnight memories deluxe'),
          greaterThanOrEqualTo(85));
    });

    test('short title inside a longer unrelated title does not match', () {
      expect(
          InnerTubeMusicApi.similarity('Cider', 'Cinderella'),
          lessThan(85));
      expect(
          InnerTubeMusicApi.similarity(
              'Piranha', 'Wisakda Me (Piranha, Pt. 2)'),
          lessThan(85));
    });

    test('normalize strips diacritics and punctuation', () {
      expect(InnerTubeMusicApi.normalize('Beyoncé!  Hello'),
          'beyonce hello');
    });

    test('baseTitle strips featuring clauses', () {
      expect(
          InnerTubeMusicApi.baseTitle('Song (feat. Someone)')
              .trim(),
          'Song');
    });

    test('highResolutionArtwork upgrades google hosts', () {
      expect(
          InnerTubeMusicApi.highResolutionArtwork(
              'https://lh3.googleusercontent.com/a=w60-h60-l90-rj'),
          'https://lh3.googleusercontent.com/a=w512-h512-l90-rj');
      expect(
          InnerTubeMusicApi.highResolutionArtwork(
              'https://i.ytimg.com/vi/x/hqdefault.jpg'),
          'https://i.ytimg.com/vi/x/hqdefault.jpg');
    });

    test('parseDuration matches Android fold', () {
      expect(InnerTubeMusicApi.parseDuration('3:45'), 225);
      expect(InnerTubeMusicApi.parseDuration('1:02:03'), 3723);
      expect(InnerTubeMusicApi.parseDuration('views'), isNull);
      expect(InnerTubeMusicApi.parseDuration('3'), isNull);
    });
  });

  group('Signature decipher (offline, synthetic player)', () {
    // Synthetic base.js exercising reverse + splice + swap ops.
    const js = 'var Q={r:function(a){a.reverse()},'
        's:function(a,b){a.splice(0,b)},'
        'w:function(a,b){var c=a[0];a[0]=a[b%a.length];a[b]=c}};'
        'QZ=function(a){a=a.split("");Q.r(a);Q.s(a,2);Q.w(a,3);'
        'return a.join("")}';

    test('parses ops and deciphers signature', () {
      final decipher = SignatureDecipher(Dio());
      final script =
          decipher.parseForTest('https://x/base.js', js);
      expect(script, isNotNull);
      expect(script!.sigOps.length, 3);
      // reverse(abcdef)=fedcba, splice(0,2)->dcba, swap(3): d<->a => acbd
      final url = decipher.decipherUrl(
          'url=${Uri.encodeComponent('https://ex.com/v')}&s=abcdef&sp=sig',
          script);
      expect(url, 'https://ex.com/v?sig=acbd');
    });

    test('passes through plain urls without s param', () {
      final decipher = SignatureDecipher(Dio());
      final script =
          decipher.parseForTest('https://x/base.js', js);
      final url = decipher.decipherUrl(
          'url=${Uri.encodeComponent('https://ex.com/v')}', script!);
      expect(url, 'https://ex.com/v');
    });

    test('returns null when undecipherable', () {
      final decipher = SignatureDecipher(Dio());
      expect(
          decipher.parseForTest(
              'https://x/base.js', 'var x = 1;'),
          isNull);
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

  group('Apple word-by-word parsing (paxsenix)', () {
    test('parses word timings and joins part words', () {
      final result = LyricsRepository.parseAppleWordByWord({
        'type': 'Syllable',
        'plain': 'a conversation\n',
        'content': [
          {
            'timestamp': 1000,
            'endtime': 3000,
            'duration': 2000,
            'background': false,
            'text': [
              {'text': 'a', 'timestamp': 1000, 'duration': 100, 'part': false},
              {'text': 'conver', 'timestamp': 1100, 'duration': 300, 'part': true},
              {'text': 'sation', 'timestamp': 1400, 'duration': 600, 'part': false},
            ],
          },
        ],
      });
      expect(result, isNotNull);
      expect(result!.isWordSynced, isTrue);
      expect(result.source, 'Apple Music');
      expect(result.plainLyrics, 'a conversation\n');
      expect(result.lines.length, 1);
      final line = result.lines.first;
      expect(line.text, 'a conversation');
      expect(line.timeMs, 1000);
      expect(line.durationMs, 2000);
      expect(line.syllables.length, 3);
      expect(line.syllables[1].text, 'conver');
      expect(line.syllables[1].timeMs, 1100);
    });

    test('marks background vocal lines', () {
      final result = LyricsRepository.parseAppleWordByWord({
        'type': 'Syllable',
        'content': [
          {
            'timestamp': 500,
            'endtime': 900,
            'duration': 400,
            'background': true,
            'text': [
              {'text': 'ooh', 'timestamp': 500, 'duration': 400, 'part': false},
            ],
          },
        ],
      });
      expect(result, isNotNull);
      expect(result!.lines.first.syllables.first.isBackground, isTrue);
    });

    test('line-synced payloads stay syllable-free for interpolated karaoke',
        () {
      final result = LyricsRepository.parseAppleWordByWord({
        'type': 'Line',
        'content': [
          {
            'timestamp': 1409,
            'endtime': 3060,
            'duration': 1651,
            'background': false,
            'text': [
              {
                'text': "I'm tweakin', I'm geekin'",
                'timestamp': 1409,
                'duration': 1651,
                'part': false,
              },
            ],
          },
        ],
      });
      expect(result, isNotNull);
      expect(result!.isSynced, isTrue);
      expect(result.isWordSynced, isFalse);
      expect(result.lines.first.text, "I'm tweakin', I'm geekin'");
      expect(result.lines.first.timeMs, 1409);
      expect(result.lines.first.durationMs, 1651);
      // No whole-line pseudo syllable — the adapter interpolates per-word
      // timing so the karaoke wipe still animates.
      expect(result.lines.first.hasSyllables, isFalse);
    });

    test('error payload yields null', () {
      expect(
        LyricsRepository.parseAppleWordByWord(
          const {'message': 'No lyrics for this track', 'error': true},
        ),
        isNull,
      );
    });

    test('empty content yields null', () {
      expect(
        LyricsRepository.parseAppleWordByWord(const {'content': []}),
        isNull,
      );
    });
  });

  group('RTL detection', () {
    test('detects Arabic text', () {
      expect(isRtlText('مرحبا بالعالم'), isTrue);
      expect(isRtlText('Hello world'), isFalse);
    });
  });
}
