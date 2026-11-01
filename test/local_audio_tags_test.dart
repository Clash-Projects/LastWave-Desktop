import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/library/local_audio_tags.dart';

Uint8List _u32(int v) =>
    Uint8List.fromList([v >> 24 & 255, v >> 16 & 255, v >> 8 & 255, v & 255]);

Uint8List _synchsafe(int v) =>
    Uint8List.fromList([v >> 21 & 127, v >> 14 & 127, v >> 7 & 127, v & 127]);

Uint8List _cat(List<List<int>> parts) =>
    Uint8List.fromList([for (final p in parts) ...p]);

Uint8List _id3Frame(String id, String text) {
  final body = _cat([
    [3],
    utf8.encode(text),
  ]);
  return _cat([ascii.encode(id), _synchsafe(body.length), [0, 0], body]);
}

Uint8List _id3(List<Uint8List> frames) {
  final body = _cat(frames);
  return _cat([
    ascii.encode('ID3'),
    [4, 0, 0],
    _synchsafe(body.length),
    body,
  ]);
}

Uint8List _box(List<int> type, List<int> payload) =>
    _cat([_u32(8 + payload.length), type, payload]);

Uint8List _mp4Text(List<int> type, String text) => _box(type, [
      ..._box(ascii.encode('data'), [0, 0, 0, 1, 0, 0, 0, 0, ...utf8.encode(text)]),
    ]);

void main() {
  test('reads title, artist, album, and year from ID3v2.4', () {
    final tags = LocalAudioTags.fromHead(_id3([
      _id3Frame('TIT2', 'Song'),
      _id3Frame('TPE1', 'Singer'),
      _id3Frame('TALB', 'Album'),
      _id3Frame('TDRC', '2019-05-03'),
    ]));
    expect(tags.title, 'Song');
    expect(tags.artist, 'Singer');
    expect(tags.album, 'Album');
    expect(tags.year, '2019');
  });

  test('reads MP4 text as UTF-8, not Latin-1', () {
    final ilst = _box(ascii.encode('ilst'), [
      ..._mp4Text([0xA9, 0x6E, 0x61, 0x6D], 'नज़र से'),
      ..._mp4Text([0xA9, 0x61, 0x6C, 0x62], 'Album'),
      ..._mp4Text([0xA9, 0x64, 0x61, 0x79], '2011-07-01'),
    ]);
    final meta = _box(ascii.encode('meta'), [0, 0, 0, 0, ...ilst]);
    final moov = _box(
      ascii.encode('moov'),
      _box(ascii.encode('udta'), meta),
    );
    final tags = LocalAudioTags.fromHead(moov);
    expect(tags.title, 'नज़र से');
    expect(tags.album, 'Album');
    expect(tags.year, '2011');
  });

  test('yearIn finds a four-digit year and ignores other numbers', () {
    expect(LocalAudioTags.yearIn('Released 1998 (remaster)'), '1998');
    expect(LocalAudioTags.yearIn('Track 12'), '');
  });
}
