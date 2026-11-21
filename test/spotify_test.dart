import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/spotify/spotify_api.dart';
import 'package:lastwave_desktop/features/spotify/spotify_auth.dart';
import 'package:lastwave_desktop/features/spotify/spotify_web_login.dart';
import 'package:lastwave_desktop/features/spotify/spotify_web_player.dart';
import 'package:lastwave_desktop/ui/canvas/canvas_geometry.dart';

void main() {
  group('one-time password', () {
    // RFC 6238 appendix B, SHA-1 secret "12345678901234567890":
    // T=59 -> 94287082, so the 6-digit code is 287082.
    test('matches the RFC 6238 vector', () {
      final key = ascii.encode('12345678901234567890');
      expect(SpotifyAuth.generateOtp(key, 59), '287082');
      expect(SpotifyAuth.generateOtp(key, 1111111109), '081804');
      expect(SpotifyAuth.generateOtp(key, 1234567890), '005924');
    });
  });

  group('home', () {
    test('reads titled rows of playlists, albums and artists', () {
      final sections = SpotifyApi.parseHome({
        'data': {
          'home': {
            'sectionContainer': {
              'sections': {
                'items': [
                  {
                    'data': {
                      'title': {'transformedLabel': 'Made For You'},
                    },
                    'sectionItems': {
                      'items': [
                        {
                          'content': {
                            'data': {
                              'uri': 'spotify:playlist:p1',
                              'name': 'Daily Mix 1',
                              'images': {
                                'items': [
                                  {
                                    'sources': [
                                      {'url': 'https://i/p1.jpg'},
                                    ],
                                  },
                                ],
                              },
                            },
                          },
                        },
                        {
                          'content': {
                            'data': {
                              'uri': 'spotify:artist:a1',
                              'profile': {'name': 'Raftaar'},
                            },
                          },
                        },
                        {
                          'content': {
                            'data': {
                              'uri': 'spotify:episode:e1',
                              'name': 'A podcast',
                            },
                          },
                        },
                      ],
                    },
                  },
                  {
                    'data': {'title': {'text': 'Empty row'}},
                    'sectionItems': {'items': []},
                  },
                ],
              },
            },
          },
        },
      });
      expect(sections, hasLength(1));
      expect(sections.single.title, 'Made For You');
      expect(sections.single.items.map((i) => i.kind), ['playlist', 'artist']);
      expect(sections.single.items.first.artworkUrl, 'https://i/p1.jpg');
      expect(SpotifyApi.parseHome(null), isEmpty);
    });

    test('groups multiple micro-sections with matching titles and dedupes cards', () {
      final sections = SpotifyApi.parseHome({
        'data': {
          'home': {
            'sectionContainer': {
              'sections': {
                'items': [
                  {
                    'data': {'title': {'transformedLabel': 'Made for you'}},
                    'sectionItems': {
                      'items': [
                        {
                          'content': {
                            'data': {
                              'uri': 'spotify:playlist:p1',
                              'name': '2000s Mix',
                            },
                          },
                        },
                      ],
                    },
                  },
                  {
                    'data': {'title': {'transformedLabel': 'Made for you'}},
                    'sectionItems': {
                      'items': [
                        {
                          'content': {
                            'data': {
                              'uri': 'spotify:playlist:p2',
                              'name': 'Happy Mix',
                            },
                          },
                        },
                      ],
                    },
                  },
                  {
                    'data': {'title': {'text': 'More like Shayan Sensei'}},
                    'sectionItems': {
                      'items': [
                        {
                          'content': {
                            'data': {
                              'uri': 'spotify:playlist:p3',
                              'name': 'Anime Now',
                            },
                          },
                        },
                      ],
                    },
                  },
                  {
                    'data': {'title': {'transformedLabel': 'Made For You'}},
                    'sectionItems': {
                      'items': [
                        {
                          'content': {
                            'data': {
                              'uri': 'spotify:playlist:p1', // Duplicate
                              'name': '2000s Mix',
                            },
                          },
                        },
                        {
                          'content': {
                            'data': {
                              'uri': 'spotify:playlist:p4',
                              'name': 'Sad Mix',
                            },
                          },
                        },
                      ],
                    },
                  },
                ],
              },
            },
          },
        },
      });

      expect(sections, hasLength(2));
      expect(sections[0].title, 'Made for you');
      // p1 was duplicated; should only be included once, giving p1, p2, p4
      expect(sections[0].items.map((i) => i.id), ['p1', 'p2', 'p4']);
      expect(sections[1].title, 'More like Shayan Sensei');
      expect(sections[1].items.map((i) => i.id), ['p3']);
    });
  });

  group('song radio', () {
    test('reads the radio playlist from a seed_to_playlist answer', () {
      expect(
        SpotifyApi.songRadioPlaylistId(
            '{"mediaItems":[{"uri":"spotify:playlist:37i9dQZF1E4abc"}]}'),
        '37i9dQZF1E4abc',
      );
      expect(SpotifyApi.songRadioPlaylistId('{"mediaItems":[]}'), isNull);
      expect(SpotifyApi.songRadioPlaylistId('oops'), isNull);
    });
  });

  group('sp_dc cleaning', () {
    test('accepts the bare value, a pair, or a whole Cookie header', () {
      expect(SpotifyAuth.cleanSpDc('AQabc123'), 'AQabc123');
      expect(SpotifyAuth.cleanSpDc('sp_dc=AQabc123'), 'AQabc123');
      expect(
        SpotifyAuth.cleanSpDc('sp_t=zzz; sp_dc=AQabc123; sp_key=k'),
        'AQabc123',
      );
      expect(SpotifyAuth.cleanSpDc('  "AQabc123"  '), 'AQabc123');
    });

    test('accepts a row copied from the browser cookie table', () {
      expect(
        SpotifyAuth.cleanSpDc(
            'sp_dc\tAQabc123\t.spotify.com\t/\t2027-01-01T00:00:00.000Z'),
        'AQabc123',
      );
      expect(SpotifyAuth.cleanSpDc('AQabc​123﻿'), 'AQabc123');
      expect(SpotifyAuth.cleanSpDc('sp_dc = AQabc123'), 'AQabc123');
    });
  });

  group('otp secret sources', () {
    test('the published dictionary is read newest version first', () {
      final secrets =
          SpotifyAuth.parseSecretDict('{"12":[97,98],"14":[120],"x":[1]}');
      expect(secrets.map((s) => s.version), [14, 12]);
      expect(secrets.first.value, 'x');
      expect(SpotifyAuth.parseSecretDict('not json'), isEmpty);
    });

    test('the remembered secret round-trips', () {
      final s = SpotifyAuth.decodeStoredSecret('{"v":61,"c":[65,66]}');
      expect(s?.version, 61);
      expect(s?.value, 'AB');
      expect(SpotifyAuth.decodeStoredSecret(''), isNull);
      expect(SpotifyAuth.decodeStoredSecret('{"v":1}'), isNull);
    });
  });

  group('web player scraping', () {
    test('reads operation hashes and the newest secret', () {
      final hash = 'a' * 64;
      final script = '''
        foo("canvas","query","$hash");
        bar("other","query","${'b' * 64}");
        [{secret:'abc\\\\def',version:12},{secret:"xyz",version:13}]
      ''';
      expect(SpotifyWebPlayer.queryHash(script, 'canvas'), hash);
      expect(SpotifyWebPlayer.queryHash(script, 'missing'), isNull);
      final secrets = SpotifyWebPlayer.secrets(script);
      expect(secrets.first.version, 13);
      expect(secrets.first.value, 'xyz');
      expect(secrets.last.value, r'abc\def');
    });

    test('finds the bundles linked from the page', () {
      const page = '<script src="https://open.spotifycdn.com/cdn/build/'
          'web-player/web-player.abc123.js"></script>';
      expect(SpotifyWebPlayer.scripts(page), hasLength(1));
    });
  });

  group('sign-in landing page', () {
    test('only post-auth pages count', () {
      expect(
        SpotifyWebLogin.isPostAuth('https://accounts.spotify.com/en/status'),
        isTrue,
      );
      expect(
        SpotifyWebLogin.isPostAuth(
            'https://accounts.spotify.com/en/status?flow_ctx=1'),
        isTrue,
      );
      expect(
        SpotifyWebLogin.isPostAuth('https://accounts.spotify.com/en/login'),
        isFalse,
      );
      expect(
        SpotifyWebLogin.isPostAuth(
            'https://accounts.spotify.com/en/login?continue=x'),
        isFalse,
      );
      expect(SpotifyWebLogin.isPostAuth(null), isFalse);
    });
  });

  group('canvas panel geometry', () {
    test('is exactly 9:16 of the content height when there is room', () {
      expect(
        canvasPanelWidth(height: 800, available: 2000),
        closeTo(450, 0.001),
      );
    });

    test('never takes the whole page', () {
      final w = canvasPanelWidth(height: 1600, available: 900);
      expect(w, lessThanOrEqualTo(900 - 520));
    });
  });
}
