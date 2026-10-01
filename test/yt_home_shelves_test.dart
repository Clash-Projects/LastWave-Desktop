import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/network/dio_factory.dart';
import 'package:lastwave_desktop/core/storage/secure_store.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';

/// Home-browse shelf parsing.
///
/// Fixture is a trimmed capture of a real `FEmusic_home` response
/// (anonymous, WEB_REMIX), with the song rows taken from a real
/// `FEmusic_charts` browse because the anonymous home payload only
/// returns carousel and tastebuilder sections. It deliberately contains
/// all three shapes the parser has to triage:
///   - `musicShelfRenderer`         -> song rows
///   - `musicCarouselShelfRenderer` -> two-row cards
///   - `musicTastebuilderShelfRenderer` -> not renderable, must drop
Map<String, dynamic> _fixture() {
  final file = File('test/fixtures/yt_home_shelves.json');
  expect(file.existsSync(), isTrue,
      reason: 'missing fixture: ${file.path}');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  // Constructed without any network call - parseHomeShelves is pure.
  final tube = InnerTubeMusicApi(DioFactory.create(), SecureStore());

  group('kindForBrowseId', () {
    test('artist channels', () {
      expect(InnerTubeMusicApi.kindForBrowseId('UCabc123'),
          YouTubeEntityKind.artist);
    });

    test('albums are MPRE, with or without a VL wrapper', () {
      expect(InnerTubeMusicApi.kindForBrowseId('MPREb_1234'),
          YouTubeEntityKind.album);
      expect(InnerTubeMusicApi.kindForBrowseId('VLAA123'),
          YouTubeEntityKind.album);
    });

    test('playlists are VLPL, not a bare PL match', () {
      expect(InnerTubeMusicApi.kindForBrowseId('VLPLlLI-kEw'),
          YouTubeEntityKind.playlist);
    });

    // Regression from a live capture: the "Easy Evenings" carousel
    // shipped VLRDCLAK ids. Testing the bare 'RD' prefix instead of the
    // VL-wrapped form mislabelled every radio as a playlist.
    test('radios are VL-wrapped RD ids', () {
      expect(InnerTubeMusicApi.kindForBrowseId('VLRDCLAK5uy_'),
          YouTubeEntityKind.mix);
      expect(InnerTubeMusicApi.kindForBrowseId('VLRDAMVMabc'),
          YouTubeEntityKind.mix);
      expect(InnerTubeMusicApi.kindForBrowseId('RDCLAK5uy_'),
          YouTubeEntityKind.mix);
    });

    test('unknown ids fall back to album rather than throwing', () {
      expect(InnerTubeMusicApi.kindForBrowseId('VLLM'),
          YouTubeEntityKind.album);
      expect(InnerTubeMusicApi.kindForBrowseId(''),
          YouTubeEntityKind.album);
    });
  });

  group('parseHomeShelves', () {
    test('reads every renderable section and drops the rest', () {
      final shelves = tube.parseHomeShelves(_fixture());

      // The real anonymous home payload is 2 carousels + 1
      // tastebuilder. The tastebuilder is not a shelf we can render,
      // so exactly the 2 carousels survive.
      expect(shelves.length, 2);
      expect(shelves[0].title, 'Trending community playlists');
      expect(shelves[1].title, 'Easy Evenings');
      for (final shelf in shelves) {
        expect(shelf.isCardShelf, isTrue, reason: shelf.title);
        expect(shelf.isTrackShelf, isFalse);
      }
    });

    test('carousel cards carry artwork, a name and a kind', () {
      final shelves = tube.parseHomeShelves(_fixture());
      final playlistShelf = shelves[0];
      expect(playlistShelf.entities.length, 2);
      for (final e in playlistShelf.entities) {
        expect(e.name, isNotEmpty);
        expect(e.browseId, isNotEmpty);
        expect(e.artworkUrl, isNotEmpty);
        expect(e.subtitle, isNotEmpty);
      }
      expect(playlistShelf.entities.every(
          (e) => e.kind == YouTubeEntityKind.playlist), isTrue);

      // Second carousel is a radio - must not be reported as a playlist.
      expect(shelves[1].entities.every(
          (e) => e.kind == YouTubeEntityKind.mix), isTrue);
    });

    test('honours maxShelves', () {
      expect(
        tube.parseHomeShelves(_fixture(), maxShelves: 1).length, 1);
      expect(tube.parseHomeShelves(_fixture(), maxShelves: 0), isEmpty);
    });

    test('honours maxItemsPerShelf', () {
      final shelves = tube.parseHomeShelves(
        _fixture(),
        maxItemsPerShelf: 1,
      );
      expect(shelves.length, 2);
      expect(shelves[0].entities.length, 1);
    });

    test('non-renderable shelves are dropped, not rendered as headers', () {
      final root = <String, dynamic>{
        'contents': {
          'sectionListRenderer': {
            'contents': [
              {
                'musicTastebuilderShelfRenderer': {
                  'primaryText': {'text': 'Made for you'},
                }
              },
              {
                'musicCarouselShelfRenderer': {
                  'header': {
                    'musicCarouselShelfBasicHeaderRenderer': {
                      'title': {'runs': [{'text': 'Empty'}]},
                    }
                  },
                  'contents': <Object?>[],
                }
              },
              {
                'musicShelfRenderer': {
                  'title': {'runs': [{'text': 'No rows'}]},
                  'contents': <Object?>[],
                }
              },
            ],
          },
        },
      };
      expect(tube.parseHomeShelves(root), isEmpty);
    });

    // The anonymous home browse returns no musicShelfRenderer, so the
    // song-shelf path is covered here with a well-formed row instead.
    test('a song shelf yields playable tracks', () {
      final root = <String, dynamic>{
        'contents': {
          'sectionListRenderer': {
            'contents': [
              {
                'musicShelfRenderer': {
                  'title': {'runs': [{'text': 'Recently played'}]},
                  'contents': [
                    {
                      'musicResponsiveListItemRenderer': {
                        'playlistItemData': {'videoId': 'abc123'},
                        'flexColumns': [
                          {
                            'musicResponsiveListItemFlexColumnRenderer': {
                              'text': {
                                'runs': [
                                  {'text': 'Raga'},
                                ],
                              },
                            },
                          },
                          {
                            'musicResponsiveListItemFlexColumnRenderer': {
                              'text': {
                                'runs': [
                                  {
                                    'text': 'Anirudh',
                                    'navigationEndpoint': {
                                      'browseEndpoint': {
                                        'browseId': 'UCartist123',
                                      },
                                    },
                                  },
                                ],
                              },
                            },
                          },
                        ],
                      },
                    },
                  ],
                },
              },
            ],
          },
        },
      };
      final shelves = tube.parseHomeShelves(root);
      expect(shelves.length, 1);
      final shelf = shelves.single;
      expect(shelf.isTrackShelf, isTrue);
      expect(shelf.isCardShelf, isFalse);
      expect(shelf.title, 'Recently played');
      expect(shelf.tracks.single.videoId, 'abc123');
      expect(shelf.tracks.single.title, 'Raga');
      expect(shelf.tracks.single.artist, 'Anirudh');
    });

    test('a shelf with a bare {text} title is accepted', () {
      final root = <String, dynamic>{
        'contents': {
          'sectionListRenderer': {
            'contents': [
              {
                'musicShelfRenderer': {
                  'title': {'text': 'Recently played'},
                  'contents': [
                    {
                      'musicResponsiveListItemRenderer': {
                        'playlistItemData': {
                          'videoId': 'abc123',
                        },
                        'flexColumns': [
                          {
                            'musicResponsiveListItemFlexColumnRenderer': {
                              'text': {
                                'runs': [
                                  {'text': 'Song'},
                                ],
                              },
                            },
                          },
                        ],
                      },
                    },
                  ],
                },
              },
            ],
          },
        },
      };
      final shelves = tube.parseHomeShelves(root);
      expect(shelves.length, 1);
      expect(shelves.single.title, 'Recently played');
      expect(shelves.single.tracks.single.videoId, 'abc123');
      expect(shelves.single.tracks.single.title, 'Song');
    });

    test('the two-column (tabbed) account shape parses the same', () {
      // Connected home browse wraps sections in tabs, not
      // singleColumnBrowseResultsRenderer - the section list is found by
      // key so both shapes work.
      final fixture = _fixture();
      final tabs = ((fixture['contents']
              as Map)['singleColumnBrowseResultsRenderer']
          as Map)['tabs'] as List;
      final sectionList = ((((tabs[0]
              as Map)['tabRenderer'] as Map)['content'] as Map)
          ['sectionListRenderer'] as Map);
      final root = <String, dynamic>{
        'contents': {
          'twoColumnBrowseResultsRenderer': {
            'tabs': [
              {
                'tabRenderer': {
                  'content': {
                    'sectionListRenderer': sectionList,
                  },
                },
              },
            ],
          },
        },
      };
      expect(tube.parseHomeShelves(root).length, 2);
    });

    test('missing or malformed payloads yield no shelves', () {
      expect(tube.parseHomeShelves(<String, dynamic>{}), isEmpty);
      expect(
        tube.parseHomeShelves(
            <String, dynamic>{'contents': <String, dynamic>{}}),
        isEmpty);
      expect(
        tube.parseHomeShelves({
          'contents': {
            'sectionListRenderer': {'contents': 'not-a-list'},
          },
        }),
        isEmpty);
    });
  });

  group('YtHomeShelf', () {
    test('renderability tracks populated lists', () {
      expect(const YtHomeShelf(title: 'x').isRenderable, isFalse);
      expect(
        YtHomeShelf(
          title: 'x',
          tracks: const [
            YouTubeMusicTrack(videoId: 'a', title: 't', artist: 'r'),
          ],
        ).isRenderable,
        isTrue,
      );
      expect(
        YtHomeShelf(
          title: 'x',
          entities: const [
            YouTubeMusicEntity(
                kind: YouTubeEntityKind.mix, name: 'n'),
          ],
        ).isRenderable,
        isTrue,
      );
    });
  });
}
