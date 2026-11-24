import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/features/lastfm/auth_repository.dart';
import 'package:lastwave_desktop/features/search/shared_providers.dart';
import 'package:lastwave_desktop/ui/app_shell/title_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockAuth extends StateNotifier<AuthState> implements AuthRepository {
  _MockAuth(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Prefs prefs;
  late AppDatabase db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = Prefs(await SharedPreferences.getInstance());
    db = AppDatabase.inMemory();
  });

  tearDown(() {
    db.close();
  });

  Widget createSubject({
    String username = 'Ayush',
    Key? key,
  }) {
    return ProviderScope(
      key: key ?? UniqueKey(),
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        authRepositoryProvider.overrideWith(
          (ref) => _MockAuth(AuthState(
            status: AuthStatus.signedIn,
            username: username,
          )),
        ),
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
    );
  }

  testWidgets('WaveTitleBar renders profile initial and window elements', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(createSubject(username: 'Ayush'));
    await tester.pumpAndSettle();

    // Verify Profile avatar initial
    expect(find.text('A'), findsOneWidget);
  });

  testWidgets('WaveTitleBar adapts layout to searchBarPosition preference', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    // 1. Default ('left')
    await tester.pumpWidget(createSubject());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('drag_left')), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);

    // 2. Center placement
    await prefs.setSearchBarPosition('center');
    await tester.pumpWidget(createSubject());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('drag_center')), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.byTooltip('Commands (Ctrl+K)'), findsOneWidget);

    // 3. Right placement
    await prefs.setSearchBarPosition('right');
    await tester.pumpWidget(createSubject());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('drag_right')), findsOneWidget);

    // 4. Icon only mode (collapsed initially)
    await prefs.setSearchBarPosition('icon');
    await tester.pumpWidget(createSubject());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('drag_icon')), findsOneWidget);
    // In collapsed icon mode, search input box is not showing its placeholder text
    expect(find.text('Search'), findsNothing);

    // Tapping the search icon expands the search box
    final searchIconBtn = find.byTooltip('Search (Ctrl+F)');
    expect(searchIconBtn, findsOneWidget);
    await tester.tap(searchIconBtn);
    await tester.pumpAndSettle();
    expect(find.text('Search'), findsOneWidget);
  });
}
