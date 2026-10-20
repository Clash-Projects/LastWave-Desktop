import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/innertube/yt_web_login.dart';

void main() {
  test('detects the passkey verification stall text', () {
    expect(
      YtWebLogin.isPasskeyVerificationStall(
        "Mrinmoy Haloi\nVerifying that it's you...\n"
        'Complete sign-in using your passkey\nTry another way',
      ),
      isTrue,
    );
  });

  test('ignores ordinary login pages', () {
    expect(YtWebLogin.isPasskeyVerificationStall('Sign in'), isFalse);
    expect(
      YtWebLogin.isPasskeyVerificationStall(
          'Verify it\'s you\nEnter your password'),
      isFalse,
    );
    expect(YtWebLogin.isPasskeyVerificationStall(''), isFalse);
  });

  test('matching is case-insensitive', () {
    expect(
      YtWebLogin.isPasskeyVerificationStall(
          'VERIFYING THAT IT\'S YOU — use passkey'),
      isTrue,
    );
  });

  test('isBlankUrl detects blank and about:blank URLs', () {
    expect(YtWebLogin.isBlankUrl('about:blank'), isTrue);
    expect(YtWebLogin.isBlankUrl('ABOUT:BLANK'), isTrue);
    expect(YtWebLogin.isBlankUrl('data:,'), isTrue);
    expect(YtWebLogin.isBlankUrl(''), isTrue);
    expect(YtWebLogin.isBlankUrl('   '), isTrue);
    expect(YtWebLogin.isBlankUrl('https://music.youtube.com/'), isFalse);
    expect(YtWebLogin.isBlankUrl('https://accounts.google.com/'), isFalse);
  });

  test('detects the embedded-browser rejection page', () {
    // Verbatim shape of Google's macOS block page.
    expect(
      YtWebLogin.isBrowserBlockedPage(
        "Couldn't sign you in\n"
        'This browser or app may not be secure.\n'
        'Try using a different browser.',
      ),
      isTrue,
    );
    expect(
      YtWebLogin.isBrowserBlockedPage('This browser or app may not be secure'),
      isTrue,
    );
    expect(
      YtWebLogin.isBrowserBlockedPage('error: disallowed_useragent'),
      isTrue,
    );
    // Typographic apostrophe variant.
    expect(
      YtWebLogin.isBrowserBlockedPage('Couldn’t sign you in'),
      isTrue,
    );
    // Ordinary pages must not be mistaken for the block.
    expect(
      YtWebLogin.isBrowserBlockedPage('Sign in\nUse your Google Account'),
      isFalse,
    );
    expect(YtWebLogin.isBrowserBlockedPage(''), isFalse);
  });

  test('isErrorUrl detects failed navigations', () {
    expect(YtWebLogin.isErrorUrl('chrome-error://chromewebdata/'), isTrue);
    expect(YtWebLogin.isErrorUrl('edge-error://chromewebdata/'), isTrue);
    expect(YtWebLogin.isErrorUrl('https://music.youtube.com/'), isFalse);
    expect(YtWebLogin.isBlankUrl('chrome-error://chromewebdata/'), isFalse);
  });

  group('buildCookieHeader', () {
    YtJarCookie c(String name, String value, String domain) =>
        YtJarCookie(name: name, value: value, domain: domain);

    test('prefers the YouTube scope over the Google scope', () {
      final header = YtWebLogin.buildCookieHeader([
        c('SAPISID\x00', 'google-scoped', '.google.com'),
        c('SAPISID\x00', 'youtube-scoped', '.youtube.com'),
        c('__Secure-3PAPISID', 'papisid', '.youtube.com'),
        c('__Secure-3PSID', 'psid', '.youtube.com'),
        c('__Secure-1PSIDTS', 'rotation', '.youtube.com'),
      ]);
      expect(header, isNotNull);
      expect(header, contains('SAPISID=youtube-scoped'));
      expect(header, isNot(contains('google-scoped')));
    });

    test('strips trailing NULs but keeps value padding', () {
      final header = YtWebLogin.buildCookieHeader([
        c('SAPISID\x00', 'abc==\x00', '.youtube.com'),
        c('__Secure-3PSID', 'psid', '.youtube.com'),
        c('LOGIN_INFO', 'li', '.youtube.com'),
      ]);
      expect(header, contains('SAPISID=abc=='));
      expect(header, isNot(contains('\x00')));
    });

    test('drops non-Google cookies and irrelevant names', () {
      final header = YtWebLogin.buildCookieHeader([
        c('SAPISID', 's', '.youtube.com'),
        c('__Secure-3PSID', 'p', '.youtube.com'),
        c('LOGIN_INFO', 'l', '.youtube.com'),
        c('tracker', 'x', '.evil.example'),
        c('junk', 'x', '.youtube.com'),
      ]);
      expect(header, isNotNull);
      expect(header, isNot(contains('tracker')));
      expect(header, isNot(contains('junk=')));
    });

    test('rejects a mid-redirect jar that only has Google-scoped cookies',
        () {
      final header = YtWebLogin.buildCookieHeader([
        c('SAPISID', 's', '.google.com'),
        c('SID', 'x', '.google.com'),
        c('LOGIN_INFO', 'l', '.google.com'),
      ]);
      expect(header, isNull);
    });

    test('rejects a jar with no rotation or LOGIN_INFO cookie', () {
      final header = YtWebLogin.buildCookieHeader([
        c('SAPISID', 's', '.youtube.com'),
        c('SID', 'x', '.youtube.com'),
        c('__Secure-3PSID', 'p', '.youtube.com'),
      ]);
      expect(header, isNull);
      expect(
        YtWebLogin.missingMarkerNames(
            ['SAPISID', 'SID', '__Secure-3PSID']),
        ['LOGIN_INFO or __Secure-*PSIDTS'],
      );
    });

    test('marks a complete jar as complete', () {
      expect(
        YtWebLogin.missingMarkerNames([
          '__Secure-3PAPISID',
          '__Secure-3PSID',
          '__Secure-3PSIDTS',
        ]),
        isEmpty,
      );
      expect(
        YtWebLogin.missingMarkerNames(['LOGIN_INFO']),
        ['SAPISID or __Secure-3PAPISID', 'SID or __Secure-3PSID'],
      );
    });

    test('output order is deterministic', () {
      final jar = [
        c('__Secure-3PSID', 'p', '.youtube.com'),
        c('SAPISID', 's', '.youtube.com'),
        c('LOGIN_INFO', 'l', '.youtube.com'),
      ];
      final a = YtWebLogin.buildCookieHeader(jar);
      final b = YtWebLogin.buildCookieHeader(jar.reversed.toList());
      expect(a, b);
    });
  });
}
