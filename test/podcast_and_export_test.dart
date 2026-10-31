import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/library/playlist_file.dart';
import 'package:lastwave_desktop/features/podcasts/podcast_parser.dart';

void main() {
  test('parseHome reads a podcast carousel and parseShowCard', () {
    final home = {
      'contents': {
        'musicCarouselShelfRenderer': {
          'header': {
            'musicCarouselShelfBasicHeaderRenderer': {
              'title': {
                'runs': [
                  {'text': 'New episodes'},
                ],
              },
            },
          },
          'contents': [
            {
              'musicTwoRowItemRenderer': {
                'title': {
                  'runs': [
                    {'text': 'Wave Weekly'},
                  ],
                },
                'subtitle': {
                  'runs': [
                    {'text': 'LastWave'},
                  ],
                },
                'navigationEndpoint': {
                  'browseEndpoint': {'browseId': 'MPSPPLexample'},
                },
                'thumbnail': {
                  'thumbnails': [
                    {'url': 'https://example.com/art.jpg'},
                  ],
                },
              },
            },
          ],
        },
      },
    };

    final shelves = PodcastParser.parseHome(home);
    expect(shelves, hasLength(1));
    expect(shelves.single.title, 'New episodes');
    expect(shelves.single.shows.single.showId, 'MPSPPLexample');
    expect(shelves.single.shows.single.title, 'Wave Weekly');
    expect(shelves.single.shows.single.publisher, 'LastWave');

    final card = PodcastParser.parseShowCard({
      'title': {
        'runs': [
          {'text': 'Not a show'},
        ],
      },
      'navigationEndpoint': {
        'browseEndpoint': {'browseId': 'MPREb_album'},
      },
    });
    expect(card, isNull);
  });

  test('exportPlaylistCsv quotes commas and keeps the header', () {
    final csv = exportPlaylistCsv(const [
      PlaylistFileRow(
        title: 'Hello, World',
        artist: 'Adele',
        album: '25',
        videoId: 'dQw4w9WgxcQ',
      ),
    ]);
    expect(csv.split('\n').first, 'Title,Artist,Album,YouTube');
    expect(csv, contains('"Hello, World",Adele,25,dQw4w9WgxcQ'));
  });
}
