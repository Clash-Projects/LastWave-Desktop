import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/app/window.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/features/search/shared_providers.dart';
import 'package:lastwave_desktop/ui/app_shell/title_bar.dart';
import 'package:lastwave_desktop/ui/settings/settings_search.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Titlebar Style Prefs', () {
    late Prefs prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await Prefs.load();
    });

    test('defaults to custom', () {
      expect(prefs.titlebarStyle, 'custom');
      expect(Prefs.titlebarStyles, containsAll(['custom', 'system']));
      expect(Prefs.titlebarStyles.contains('none'), isFalse);
    });

    test('can set to system decorations', () async {
      await prefs.setTitlebarStyle('system');
      expect(prefs.titlebarStyle, 'system');
    });

    test('falls back to custom on unrecognized value', () async {
      await prefs.setTitlebarStyle('invalid_style');
      expect(prefs.titlebarStyle, 'custom');
    });
  });

  group('Titlebar Search Index', () {
    test('finds Titlebar by keywords', () {
      final queryTitle = [
        for (final hit in filterSettings(settingsSearchEntries, 'titlebar'))
          hit.title,
      ];
      expect(queryTitle, contains('Titlebar'));

      final querySys = [
        for (final hit
            in filterSettings(settingsSearchEntries, 'system decorations'))
          hit.title,
      ];
      expect(querySys, contains('Titlebar'));

      final queryAppDrawn = [
        for (final hit in filterSettings(settingsSearchEntries, 'app-drawn'))
          hit.title,
      ];
      expect(queryAppDrawn, contains('Titlebar'));
    });
  });

  group('Titlebar Window Management', () {
    test('applyTitlebarStyle executes without error', () async {
      await expectLater(applyTitlebarStyle('custom'), completes);
      await expectLater(applyTitlebarStyle('system'), completes);
    });
  });

  group('Titlebar UI Buttons Visibility', () {
    testWidgets('shows custom window buttons when style is custom',
        (tester) async {
      SharedPreferences.setMockInitialValues({'lw_titlebar_style': 'custom'});
      final prefs = await Prefs.load();
      final db = AppDatabase.inMemory();
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(prefs),
            databaseProvider.overrideWithValue(db),
          ],
          child: FluentApp(
            home: ScaffoldPage(
              content: WaveTitleBar(
                searchController: TextEditingController(),
                searchFocus: FocusNode(),
                onSearchSubmit: (_) {},
                onGo: (_) {},
                onPalette: () {},
                onToggleRail: () {},
                canGoBack: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      if (!Platform.isMacOS) {
        expect(find.byTooltip('Minimize'), findsOneWidget);
        expect(find.byTooltip('Close'), findsOneWidget);
      }
    });

    testWidgets('hides custom window buttons when style is system',
        (tester) async {
      SharedPreferences.setMockInitialValues({'lw_titlebar_style': 'system'});
      final prefs = await Prefs.load();
      final db = AppDatabase.inMemory();
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsProvider.overrideWithValue(prefs),
            databaseProvider.overrideWithValue(db),
          ],
          child: FluentApp(
            home: ScaffoldPage(
              content: WaveTitleBar(
                searchController: TextEditingController(),
                searchFocus: FocusNode(),
                onSearchSubmit: (_) {},
                onGo: (_) {},
                onPalette: () {},
                onToggleRail: () {},
                canGoBack: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Minimize'), findsNothing);
      expect(find.byTooltip('Close'), findsNothing);
    });
  });
}
