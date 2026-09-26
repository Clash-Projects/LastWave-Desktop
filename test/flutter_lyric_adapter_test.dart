import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lyrics/flutter_lyric_adapter.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_models.dart' as lm;

void main() {
  group('flutter_lyric_adapter', () {
    test(
      'convertToFlutterLyricModel accurately converts word-synced lyrics',
      () {
        const result = lm.LyricsResult(
          lines: [
            lm.LyricLine(
              timeMs: 12000,
              durationMs: 3500,
              text: 'I said, ooh, I\'m blinded by the lights',
              transliteration: 'Romaji or translation',
              syllables: [
                lm.LyricSyllable(timeMs: 12000, durationMs: 400, text: 'I '),
                lm.LyricSyllable(
                  timeMs: 12400,
                  durationMs: 500,
                  text: 'said, ',
                ),
                lm.LyricSyllable(timeMs: 12900, durationMs: 400, text: 'ooh, '),
                lm.LyricSyllable(timeMs: 13300, durationMs: 400, text: 'I\'m '),
                lm.LyricSyllable(
                  timeMs: 13700,
                  durationMs: 600,
                  text: 'blinded ',
                ),
                lm.LyricSyllable(timeMs: 14300, durationMs: 300, text: 'by '),
                lm.LyricSyllable(timeMs: 14600, durationMs: 300, text: 'the '),
                lm.LyricSyllable(
                  timeMs: 14900,
                  durationMs: 600,
                  text: 'lights',
                ),
              ],
            ),
          ],
          isSynced: true,
          isWordSynced: true,
          source: 'Apple Music',
        );

        final model = convertToFlutterLyricModel(
          result,
          showTransliteration: true,
        );
        expect(model.lines.length, equals(2));
        expect(model.lines[0].text, equals('•  •  •'));

        final line = model.lines[1];
        expect(line.start, equals(const Duration(milliseconds: 12000)));
        expect(line.end, equals(const Duration(milliseconds: 15500)));
        expect(line.text, equals('I said, ooh, I\'m blinded by the lights'));
        expect(line.translation, equals('Romaji or translation'));
        expect(line.words, isNotNull);
        expect(line.words!.length, equals(8));

        expect(line.words![0].text, equals('I '));
        expect(
          line.words![0].start,
          equals(const Duration(milliseconds: 12000)),
        );
        expect(line.words![0].end, equals(const Duration(milliseconds: 12400)));

        expect(line.words![7].text, equals('lights'));
        expect(
          line.words![7].start,
          equals(const Duration(milliseconds: 14900)),
        );
        expect(line.words![7].end, equals(const Duration(milliseconds: 15500)));
      },
    );

    test(
      'convertToFlutterLyricModel omits word timings for Apple line lyrics',
      () {
        const result = lm.LyricsResult(
          lines: [
            lm.LyricLine(
              timeMs: 1000,
              durationMs: 2000,
              text: 'Due',
              syllables: [
                lm.LyricSyllable(timeMs: 1000, durationMs: 400, text: 'Due'),
              ],
            ),
          ],
          isSynced: true,
          isWordSynced: true,
        );

        final model = convertToFlutterLyricModel(result, wordByWord: false);
        expect(model.lines.last.text, equals('Due'));
        expect(model.lines.last.words, isNull);
      },
    );

    test('convertToFlutterLyricModel respects showTransliteration toggle', () {
      const result = lm.LyricsResult(
        lines: [
          lm.LyricLine(
            timeMs: 1000,
            text: 'Hello',
            transliteration: 'Konnichiwa',
          ),
        ],
      );

      final withTrans = convertToFlutterLyricModel(
        result,
        showTransliteration: true,
      );
      expect(withTrans.lines.first.translation, equals('Konnichiwa'));

      final withoutTrans = convertToFlutterLyricModel(
        result,
        showTransliteration: false,
      );
      expect(withoutTrans.lines.first.translation, isNull);
    });

    test('convertToFlutterLyricModel inserts standalone 3-dot instrumental lines for intro and inter-line gaps', () {
      const result = lm.LyricsResult(
        lines: [
          lm.LyricLine(
            timeMs: 10000, // 10s intro gap
            durationMs: 3000,
            text: 'First vocal line',
          ),
          lm.LyricLine(
            timeMs: 25000, // 12s gap between line 1 (ends at 13s) and line 2 (starts at 25s)
            durationMs: 3000,
            text: 'Second vocal line',
          ),
        ],
        isSynced: true,
      );

      final model = convertToFlutterLyricModel(result);
      // Expect 4 lines: [Intro 3-dots, Line 1, Interlude 3-dots, Line 2]
      expect(model.lines.length, equals(4));

      // Line 0: Intro gap
      final introGap = model.lines[0];
      expect(introGap.text, equals('•  •  •'));
      expect(introGap.start, equals(Duration.zero));
      expect(introGap.end, equals(const Duration(milliseconds: 10000)));
      expect(introGap.words, isNotNull);
      expect(introGap.words!.length, equals(3));
      expect(introGap.words![0].text, equals('•  '));
      expect(introGap.words![1].text, equals('•  '));
      expect(introGap.words![2].text, equals('•'));

      // Line 1: First vocal line
      expect(model.lines[1].text, equals('First vocal line'));

      // Line 2: Interlude gap
      final interludeGap = model.lines[2];
      expect(interludeGap.text, equals('•  •  •'));
      expect(interludeGap.start, equals(const Duration(milliseconds: 13000)));
      expect(interludeGap.end, equals(const Duration(milliseconds: 25000)));
      expect(interludeGap.words, isNotNull);
      expect(interludeGap.words!.length, equals(3));

      // Line 3: Second vocal line
      expect(model.lines[3].text, equals('Second vocal line'));
    });

    testWidgets(
      'buildAppleMusicLyricStyle constructs valid Apple Music style',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                final style = buildAppleMusicLyricStyle(
                  context,
                  compact: false,
                  isDark: true,
                  isRtl: false,
                );

                // Validate Apple Music style properties
                expect(style.activeAnchorPosition, equals(0.34));
                // Equal to activeAnchor so flutter_lyric does not clamp
                // short tracks to the bottom of the panel.
                expect(style.selectionAnchorPosition, equals(0.34));
                expect(style.lineGap, equals(36.0));
                expect(style.fadeRange, isNotNull);
                expect(style.fadeRange!.top, equals(90.0));
                expect(style.fadeRange!.bottom, equals(180.0));
                expect(style.lineTextAlign, equals(TextAlign.left));
                expect(
                  style.contentAlignment,
                  equals(CrossAxisAlignment.start),
                );
                expect(
                  style.selectionAutoResumeDuration <
                      style.activeAutoResumeDuration,
                  isTrue,
                );

                final rtlStyle = buildAppleMusicLyricStyle(
                  context,
                  compact: true,
                  isDark: false,
                  isRtl: true,
                );
                expect(rtlStyle.lineTextAlign, equals(TextAlign.right));
                expect(
                  rtlStyle.contentAlignment,
                  equals(CrossAxisAlignment.end),
                );

                return const SizedBox();
              },
            ),
          ),
        );
      },
    );
  });
}
