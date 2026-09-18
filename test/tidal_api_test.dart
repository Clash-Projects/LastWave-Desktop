import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/lossless/lossless_api.dart';
import 'package:lastwave_desktop/features/lossless/tidal_api.dart';

void main() {
  group('TidalPlayback', () {
    test('unwraps search hits from data.items', () {
      final items = TidalPlayback.searchItems({
        'version': '2.0',
        'data': {
          'items': [
            {
              'id': 111,
              'title': 'Numbe Ras',
              'duration': 174,
              'artist': {'name': 'Zany Inzane'},
            },
            {
              'id': 222,
              'title': 'Other',
              'duration': 200,
              'artists': [
                {'name': 'Someone'},
              ],
            },
          ],
        },
      });
      expect(items.length, 2);
      expect(items.first['title'], 'Numbe Ras');
    });

    test('uses the track id not the nested album or artist id', () {
      final items = TidalPlayback.searchItems({
        'data': {
          'items': [
            {
              'album': {'id': 409528225, 'title': 'Numbe Ras'},
              'artist': {'id': 17647243, 'name': 'zany Inzane'},
              'audioQuality': 'LOSSLESS',
              'duration': 175,
              'id': 409528227,
              'title': 'Numbe Ras',
            },
          ],
        },
      });
      expect(items, hasLength(1));
      expect(items.single['id'], 409528227);
    });

    test('parses OriginalTrackUrl from a list wrapper', () {
      final parsed = TidalPlayback.parse([
        {'id': 1, 'title': 'Song'},
        {
          'manifestMimeType': 'application/dash+xml',
          'manifest':
              'PE1QRD48Q29udGVudFByb3RlY3Rpb24gc2NoZW1lSWRVcmk9InVybjp1dWlkOmVkZWY4YmE5LTc5ZDYtNGFjZS1hM2M4LTI3ZGNkNTFkMjFlZCIvPjwvTVBEPg==',
        },
        {'OriginalTrackUrl': 'https://cdn.example/decrypted.flac'},
      ]);
      expect(parsed, isNotNull);
      expect(parsed!.playableUrl, 'https://cdn.example/decrypted.flac');
      expect(parsed.encrypted, isFalse);
    });

    test('decodes unencrypted BTS JSON into a FLAC URL', () {
      final bts = base64.encode(utf8.encode(jsonEncode({
        'mimeType': 'audio/flac',
        'codecs': 'flac',
        'encryptionType': 'NONE',
        'urls': ['https://cdn.example/track.flac'],
      })));
      final parsed = TidalPlayback.parse({
        'data': {
          'audioQuality': 'LOSSLESS',
          'manifestMimeType': 'application/vnd.tidal.bts',
          'manifest': bts,
          'bitDepth': 16,
          'sampleRate': 44100,
        },
      });
      expect(parsed?.playableUrl, 'https://cdn.example/track.flac');
      expect(parsed?.bitDepth, 16);
    });

    test('rejects encrypted MPD and raw .mpd URLs', () {
      const xml =
          '<MPD><ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/></MPD>';
      final parsed = TidalPlayback.parse({
        'manifestMimeType': 'application/dash+xml',
        'manifest': base64.encode(utf8.encode(xml)),
        'url': 'https://cdn.example/track.mpd?token=1',
      });
      expect(parsed?.playableUrl, isNull);
    });

    test('ignores tidal.com catalog pages and uses the BTS FLAC URL', () {
      final bts = base64.encode(utf8.encode(jsonEncode({
        'mimeType': 'audio/flac',
        'codecs': 'flac',
        'encryptionType': 'NONE',
        'urls': ['https://lgf.audio.tidal.com/mediatracks/abc/0.flac'],
      })));
      final parsed = TidalPlayback.parse([
        {
          'title': 'Numbe Ras',
          'url': 'http://www.tidal.com/track/409528227',
        },
        {
          'manifestMimeType': 'application/vnd.tidal.bts',
          'manifest': bts,
          'bitDepth': 16,
          'sampleRate': 44100,
        },
      ]);
      expect(
        parsed?.playableUrl,
        'https://lgf.audio.tidal.com/mediatracks/abc/0.flac',
      );
    });

    test('quality order prefers CD FLAC before hi-res DASH', () {
      expect(TidalApi.qualitiesFor(27), ['LOSSLESS', 'HI_RES_LOSSLESS']);
      expect(TidalApi.qualitiesFor(6), ['LOSSLESS', 'HI_RES_LOSSLESS']);
      expect(TidalApi.qualitiesFor(5), ['LOSSLESS']);
    });

    test('counts DASH SegmentTimeline repeats', () {
      const xml = '''
<MPD><SegmentTemplate startNumber="1" initialization="https://cdn.example/0.mp4" media="https://cdn.example/\$Number\$.mp4">
<SegmentTimeline><S d="176128" r="39"/><S d="137860"/></SegmentTimeline>
</SegmentTemplate></MPD>
''';
      expect(TidalMpd.segmentCount(xml), 41);
      expect(TidalMpd.unescapeXml('a&amp;b=1'), 'a&b=1');
    });
  });

  group('Tidal candidate mapping', () {
    test('maps artist list and cover UUID', () {
      final json = tidalHitToCandidateJson({
        'id': 99,
        'title': 'Numbe Ras',
        'duration': 174,
        'artist': {'name': 'Zany Inzane'},
        'artists': [
          {'name': 'Zany Inzane'},
          {'name': 'Guest'},
        ],
        'album': {
          'title': 'Single',
          'cover': '3f49a481-68e5-46e4-a57a-5da8a75aa106',
        },
      });
      final candidate = LosslessCandidate.fromJson(json);
      expect(candidate.id, '99');
      expect(candidate.performer, 'Zany Inzane');
      expect(candidate.performersText.contains('Guest'), isTrue);
      expect(candidate.albumArtUrl, contains('resources.tidal.com/images/'));
      expect(candidate.albumArtUrl, contains('1280x1280.jpg'));
    });
  });
}
