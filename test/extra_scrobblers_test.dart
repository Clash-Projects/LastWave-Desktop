import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/scrobblers/extra_scrobblers.dart';
import 'package:lastwave_desktop/ui/settings/settings_page.dart';

void main() {
  test('settings rail contains Scrobbler entry', () {
    final scrobbler = waveSettingsSections.firstWhere((s) => s.$1 == 'lastfm');
    expect(scrobbler.$2, 'Scrobbler');
  });

  test('normalizeServer adds https and strips trailing slash', () {
    expect(normalizeServer('libre.fm', 'fallback'), 'https://libre.fm');
    expect(normalizeServer('https://libre.fm/', 'fallback'), 'https://libre.fm');
    expect(normalizeServer('http://my-gnufm.local:8080///', 'fallback'),
        'http://my-gnufm.local:8080');
    expect(normalizeServer('', 'https://libre.fm'), 'https://libre.fm');
  });

  test('LibreFmScrobbler sign hashes parameters in alphabetical order', () {
    final sig = LibreFmScrobbler.sign({
      'username': 'testuser',
      'method': 'auth.getMobileSession',
      'api_key': '12345678901234567890123456789012',
    }, 'mysecret');
    expect(sig.length, 32);
    // Same params always give exact same signature
    expect(
      sig,
      LibreFmScrobbler.sign({
        'api_key': '12345678901234567890123456789012',
        'method': 'auth.getMobileSession',
        'username': 'testuser',
      }, 'mysecret'),
    );
  });

  test('LibreFmScrobbler parseXml handles key, user, error and status', () {
    final successXml = '''
      <lfm status="ok">
        <session>
          <name>testuser</name>
          <key>sessionkey12345</key>
        </session>
      </lfm>
    ''';
    final parsedSuccess = LibreFmScrobbler.parseXml(successXml);
    expect(parsedSuccess['session']['key'], 'sessionkey12345');
    expect(parsedSuccess['session']['name'], 'testuser');
    expect(parsedSuccess['status'], 'ok');

    final errorXml = '''
      <lfm status="failed">
        <error code="4">Invalid authentication token supplied</error>
      </lfm>
    ''';
    final parsedError = LibreFmScrobbler.parseXml(errorXml);
    expect(parsedError['error'], 'Invalid authentication token supplied');
    expect(parsedError['message'], 'Invalid authentication token supplied');

    final infoXml = '''
      <lfm status="ok">
        <user>
          <playcount>425</playcount>
        </user>
      </lfm>
    ''';
    final parsedInfo = LibreFmScrobbler.parseXml(infoXml);
    expect(parsedInfo['user']['playcount'], '425');
  });

  test('ListenBrainz cleanToken strips prefixes and quotes', () {
    expect(ListenBrainzScrobbler.cleanToken('  my-token-123  '), 'my-token-123');
    expect(ListenBrainzScrobbler.cleanToken('Token my-token-123'), 'my-token-123');
    expect(ListenBrainzScrobbler.cleanToken('token my-token-123'), 'my-token-123');
    expect(ListenBrainzScrobbler.cleanToken('Bearer my-token-123'), 'my-token-123');
    expect(ListenBrainzScrobbler.cleanToken('"my-token-123"'), 'my-token-123');
    expect(ListenBrainzScrobbler.cleanToken("'my-token-123'"), 'my-token-123');
  });
}
