import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/app_info.dart';
import 'package:lastwave_desktop/features/about/contributors_provider.dart';
import 'package:lastwave_desktop/ui/settings/about_components.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('contributorsProvider', () {
    test('returns bundled contributors with founder & maintainers', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final list = container.read(contributorsProvider).valueOrNull ?? bundledContributors;
      expect(list.isNotEmpty, isTrue);

      final founder = list.firstWhere((c) => c.login == 'NONDEADER');
      expect(founder.name, equals('Ayush Yadav'));
      expect(founder.role, contains('Founder'));

      final maintainer = list.firstWhere((c) => c.login == 'ajisth69');
      expect(maintainer.name, equals('Ajisth Singh'));
      expect(maintainer.role, contains('Maintainer'));
    });
  });

  group('AboutHeroCard', () {
    testWidgets('renders LastWave title, version, India flag and download button', (tester) async {
      var downloaded = false;
      await tester.pumpWidget(
        FluentApp(
          home: ScaffoldPage(
            content: AboutHeroCard(
              appVersion: appVersion,
              onDownloadMobile: () => downloaded = true,
            ),
          ),
        ),
      );

      expect(find.text('LastWave'), findsOneWidget);
      expect(find.text('Version $appVersion'), findsOneWidget);
      expect(find.text('Made by LastWave Team'), findsOneWidget);
      expect(find.text('🇮🇳'), findsOneWidget);
      expect(find.text('Download Mobile App'), findsOneWidget);

      await tester.tap(find.text('Download Mobile App'));
      await tester.pumpAndSettle();
      expect(downloaded, isTrue);
    });
  });

  group('AboutActionTile', () {
    testWidgets('renders icon, title, subtitle and responds to taps', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        FluentApp(
          home: ScaffoldPage(
            content: AboutActionTile(
              icon: const Icon(FluentIcons.code),
              title: 'Source Code',
              subtitle: 'github.com/Clash-Projects/LastWave-Desktop',
              onTap: () => tapped = true,
            ),
          ),
        ),
      );

      expect(find.text('Source Code'), findsOneWidget);
      expect(find.text('github.com/Clash-Projects/LastWave-Desktop'), findsOneWidget);

      await tester.tap(find.text('Source Code'));
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
    });
  });

  group('ContributorsExpander', () {
    testWidgets('renders collapsed initially and expands on tap to display chips', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        const ProviderScope(
          child: FluentApp(
            home: ScaffoldPage(
              content: SingleChildScrollView(
                child: ContributorsExpander(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify header is visible
      expect(find.text('Contributors & Developers'), findsOneWidget);
      expect(find.textContaining('Made with ❤️ by Clash-Projects contributors'), findsOneWidget);

      // Initially collapsed: tap the header to expand
      await tester.tap(find.text('Contributors & Developers'));
      await tester.pumpAndSettle();

      // Once expanded, verify contributor cards are shown
      expect(find.text('Ayush Yadav'), findsOneWidget);
      expect(find.text('Founder & Maintainer'), findsOneWidget);
      expect(find.text('Ajisth Singh'), findsOneWidget);
      expect(find.text('Core Maintainer'), findsOneWidget);
    });
  });
}
