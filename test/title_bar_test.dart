import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/core/storage/prefs.dart';
import 'package:lastwave_desktop/features/lastfm/auth_repository.dart';
import 'package:lastwave_desktop/features/lastfm/profile_providers.dart';
import 'package:lastwave_desktop/features/search/shared_providers.dart';
import 'package:lastwave_desktop/ui/app_shell/title_bar.dart';
import 'package:lastwave_desktop/ui/components/buttons.dart';
import 'package:lastwave_desktop/ui/theme/brand_icons.dart';
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
    String avatarUrl = '',
  }) {
    return ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        authRepositoryProvider.overrideWith(
          (ref) => _MockAuth(AuthState(
            status: AuthStatus.signedIn,
            username: username,
          )),
        ),
        userAvatarUrlProvider.overrideWithValue(avatarUrl),
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

  testWidgets('WaveTitleBar renders Community button, Profile initial, and Menu', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(createSubject(username: 'Ayush'));
    await tester.pumpAndSettle();

    // Verify Community button exists
    expect(
      find.byWidgetPredicate((w) => w is WaveA11yButton && w.label == 'Community'),
      findsOneWidget,
    );

    // Verify Profile avatar exists (with initial 'A')
    expect(find.text('A'), findsOneWidget);

    // Verify Menu button exists
    expect(
      find.byWidgetPredicate((w) => w is WaveA11yButton && w.label == 'Menu'),
      findsOneWidget,
    );
  });

  testWidgets('Tapping Community button opens flyout with Telegram and Discord options', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(createSubject());
    await tester.pumpAndSettle();

    // Find Community button and tap it
    final communityBtn = find.byWidgetPredicate(
      (w) => w is WaveA11yButton && w.label == 'Community',
    );
    expect(communityBtn, findsOneWidget);

    await tester.tap(communityBtn);
    await tester.pumpAndSettle();

    // Verify flyout opened with both Telegram Community and Discord Server
    expect(find.text('Telegram Community'), findsOneWidget);
    expect(find.text('Discord Server'), findsOneWidget);
    expect(find.byType(TelegramIcon), findsOneWidget);
    expect(find.byType(DiscordIcon), findsOneWidget);
  });
}
