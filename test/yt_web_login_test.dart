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
}
