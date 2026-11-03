import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
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
