import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lyrics/lyrics_providers.dart';

const _ttmlDoc = '<tt xmlns="http://www.w3.org/ns/ttml"><body><div>'
    '<p begin="00:00.10" end="00:02.00">'
    '<span begin="00:00.10" end="00:00.50">Hello</span>'
    '<span begin="00:00.50" end="00:01.00">world</span></p>'
    '</div></body></tt>';

const _karaokeDoc = '[1000,2000](1000,200)Hello (1500,300)world\n'
    '[3000,1500](3000,400)Second (3600,300)line\n';

void main() {
  test('TTML document yields word-synced lines', () {
    final lines = parseBetterDocument(_ttmlDoc);
    expect(lines, isNotNull);
    expect(lines!.first.hasSyllables, isTrue);
    expect(lines.first.text, 'Hello world');
    expect(lines.first.syllables.first.timeMs, 100);
  });

  test('karaoke doc yields syllable lines', () {
    final lines = parseBetterDocument(_karaokeDoc);
    expect(lines, isNotNull);
    expect(lines!.length, 2);
    expect(lines.first.text, 'Hello world');
    expect(lines.first.syllables.length, 2);
    expect(lines.first.syllables[0].timeMs, 1000);
    expect(lines.first.syllables[1].text.trim(), 'world');
    expect(lines[1].text, 'Second line');
  });

  test('JSON envelope with ttml unwraps', () {
    final lines = parseBetterDocument('{"ttml":"$_ttmlDoc"}');
    expect(lines, isNotNull);
    expect(lines!.first.hasSyllables, isTrue);
  });

  test('error envelope yields null', () {
    expect(parseBetterDocument('{"isError":true}'), isNull);
    expect(parseBetterDocument('{"ok":false}'), isNull);
    expect(parseBetterDocument(''), isNull);
    expect(parseBetterDocument('not lyrics at all {{{'), isNull);
  });

  test('enhanced LRC falls through the chain', () {
    const enhanced =
        '[00:01.00]Hel<00:01.20>lo\n[00:05.00]Wor<00:05.30>ld\n';
    final lines = parseBetterDocument(enhanced);
    expect(lines, isNotNull);
    expect(lines!.first.hasSyllables, isTrue);
  });
}
