import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/platform/renderer_mode.dart';
import 'package:lastwave_desktop/core/platform/windows_memory.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Optimization & Memory Hygiene Tests', () {
    test('AppDatabase in-memory sets expected PRAGMAs and checkpoints cleanly', () {
      final db = AppDatabase.inMemory();
      final cacheSize = db.raw.select('PRAGMA cache_size;').first['cache_size'] as int;
      expect(cacheSize, -2000);

      // Checkpoint method should execute without throwing
      expect(() => db.checkpoint(), returnsNormally);
      db.close();
    });

    test('trimWindowsWorkingSet executes safely without throwing', () {
      expect(() => trimWindowsWorkingSet(), returnsNormally);
    });

    test('RendererMode toggles cleanly', () async {
      await RendererMode.setImpellerEnabled(false);
      final enabled = await RendererMode.isImpellerEnabled();
      expect(enabled, isFalse);

      await RendererMode.setImpellerEnabled(true);
      final enabledAfter = await RendererMode.isImpellerEnabled();
      expect(enabledAfter, isTrue);

      // Clean up back to default (false / Skia)
      await RendererMode.setImpellerEnabled(false);
      expect(await RendererMode.isImpellerEnabled(), isFalse);
    });
  });
}
