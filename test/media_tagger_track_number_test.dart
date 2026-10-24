import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/downloads/media_tagger.dart';

/// Smallest valid FLAC: magic + last STREAMINFO block (34 zero bytes).
Uint8List _flac() => Uint8List.fromList([
  ...ascii.encode('fLaC'),
  0x80,
  0,
  0,
  34,
  ...List.filled(34, 0),
  1,
  2,
  3,
]);

void main() {
  test('FLAC gets TRACKNUMBER when set, nothing when 0', () {
    final tagged = latin1.decode(
      MediaTagger.tagFlac(
        _flac(),
        const DownloadTags(title: 'Key', trackNumber: 3),
      ),
    );
    expect(tagged, contains('TRACKNUMBER=3'));
    final untagged = latin1.decode(
      MediaTagger.tagFlac(_flac(), const DownloadTags(title: 'Key')),
    );
    expect(untagged, isNot(contains('TRACKNUMBER')));
  });

  test('MP3 gets a TRCK frame when set', () {
    final mp3 = Uint8List.fromList([
      0xFF,
      0xFB,
      0x90,
      0x00,
      ...List.filled(64, 0),
    ]);
    final tagged = MediaTagger.tagMp3(
      mp3,
      const DownloadTags(title: 'Key', trackNumber: 12),
    );
    expect(latin1.decode(tagged), contains('TRCK'));
    expect(
      latin1.decode(MediaTagger.tagMp3(mp3, const DownloadTags(title: 'Key'))),
      isNot(contains('TRCK')),
    );
  });
}
