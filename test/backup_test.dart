import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/features/backup/backup_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Prefs prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'lw_sessionkey': 'SESSION',
      'lw_lastfm_api_secret': 'SECRET',
      'lw_addon_urls': 'https://example.invalid/addon',
      'ytm_cookies': 'COOKIE',
      'spotify_sp_dc': 'SPDC',
      'lw_download_dir': r'C:\Music',
      'lw_audio_device_id': 'device-1',
      'lw_username': 'someone',
      'lw_theme_mode': 'midnight',
      'lw_lyrics_text_scale': 1.2,
      'lw_amoled': true,
    });
    prefs = Prefs(await SharedPreferences.getInstance());
  });

  test('export keeps secrets and device-bound settings out of the file', () {
    final json = BackupRepository().build(
      prefs: prefs,
      db: AppDatabase.inMemory(),
      playlists: const [],
    );
    for (final leaked in [
      'SESSION',
      'SECRET',
      'example.invalid',
      'COOKIE',
      'SPDC',
      r'C:\\Music',
      'device-1',
      'someone',
    ]) {
      expect(json.contains(leaked), isFalse, reason: leaked);
    }
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    expect(decoded['type'], backupType);
    final saved = decoded['prefs'] as Map<String, dynamic>;
    expect((saved['strings'] as Map)['lw_theme_mode'], 'midnight');
    expect((saved['doubles'] as Map)['lw_lyrics_text_scale'], 1.2);
    expect((saved['booleans'] as Map)['lw_amoled'], true);
  });

  test('import cannot write a secret or device-bound setting', () async {
    await prefs.setPortablePref('lw_sessionkey', 'ATTACKER');
    await prefs.setPortablePref('lw_download_dir', r'D:\elsewhere');
    await prefs.setPortablePref('lw_theme_mode', 'pearl');
    expect(prefs.sessionKey, 'SESSION');
    expect(prefs.downloadDir, r'C:\Music');
    expect(prefs.themeMode, 'pearl');
  });

  test('read rejects other files and newer schemas', () {
    final repo = BackupRepository();
    expect(repo.read('not json', const []), isA<BackupReadInvalid>());
    expect(repo.read('{"type":"other"}', const []), isA<BackupReadInvalid>());
    expect(
      repo.read(
        jsonEncode({'type': backupType, 'schemaVersion': backupSchema + 1}),
        const [],
      ),
      isA<BackupReadUnsupported>(),
    );
  });

  test('a backup reads back as a preview', () {
    final repo = BackupRepository();
    final json = repo.build(
      prefs: prefs,
      db: AppDatabase.inMemory(),
      playlists: const [],
    );
    final parsed = repo.read(json, const []);
    expect(parsed, isA<BackupReadOk>());
    expect((parsed as BackupReadOk).preview.playlists, isEmpty);
  });
}
