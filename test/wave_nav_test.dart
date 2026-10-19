import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lastwave_desktop/ui/app_shell/branch_switcher.dart';
import 'package:lastwave_desktop/ui/navigation/route_origin.dart';
import 'package:lastwave_desktop/ui/navigation/wave_nav.dart';
import 'package:lastwave_desktop/ui/theme/tokens.dart';

/// Why [waveOpen] exists.
///
/// These tests replicate the app's navigation shape — a `StatefulShellRoute`
/// whose branch container is the real [WaveBranchSwitcher], the shell's single
/// pointer listener feeding [WaveRouteOrigin], and page builders shaped like
/// `lib/app/router.dart`'s. The app's detail routes are *siblings* of their
/// lists (`/albums` and `/album/:id`), so `context.go` hands go_router a
/// rewritten page list: the destination is mounted as a fresh page with
/// nothing underneath, which means no transition at all and no source left to
/// close back over. `waveOpen` pushes instead, which is what makes the anchored
/// entrance play — and the last test pins that difference down.
Page<void> _plain(Widget child) => CustomTransitionPage(
      child: child,
      transitionsBuilder: (context, animation, secondary, child) =>
          FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: WaveMotion.standard,
        ),
        child: child,
      ),
      transitionDuration: WaveMotion.fast,
    );

/// Shape of `lib/app/router.dart`'s `_anchoredPage`.
Page<void> _anchored(Widget child) {
  final origin = WaveRouteOrigin.consume();
  if (origin == null) return _plain(child);
  return CustomTransitionPage(
    child: child,
    transitionsBuilder: (context, animation, secondary, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: WaveMotion.standard,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
          alignment: origin.alignmentIn(MediaQuery.sizeOf(context)),
          child: child,
        ),
      );
    },
    transitionDuration: WaveMotion.normal,
  );
}

const _detailKey = ValueKey('detail');

class _ListPage extends StatelessWidget {
  const _ListPage(
    this.title, {
    this.pushLinks = const [],
    this.goLinks = const [],
  });

  final String title;

  /// Opened with [waveOpen] — stacked, so the entrance can play.
  final List<(String, String)> pushLinks;

  /// Opened with `context.go` — the branch's page list is rewritten.
  final List<(String, String)> goLinks;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title),
          for (final (label, path) in pushLinks)
            GestureDetector(
              onTap: () => waveOpen(context, path),
              child: Text(label),
            ),
          for (final (label, path) in goLinks)
            GestureDetector(
              onTap: () => context.go(path),
              child: Text(label),
            ),
        ],
      );
}

Widget _detail() => const Center(child: Text('the detail', key: _detailKey));

/// The shell chrome: one pointer listener (as in `WaveShell`) plus a back
/// affordance wired exactly like `WaveShell._goBack`.
Widget _chrome(Widget shell) => Column(
      children: [
        Builder(
          builder: (context) => GestureDetector(
            onTap: () {
              if (context.canPop()) context.pop();
            },
            child: const Text('chrome back'),
          ),
        ),
        Expanded(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerUp: (event) => WaveRouteOrigin.record(event.position),
            child: shell,
          ),
        ),
      ],
    );

GoRouter _router() => GoRouter(
      initialLocation: '/home',
      routes: [
        StatefulShellRoute(
          navigatorContainerBuilder: (context, shell, children) =>
              WaveBranchSwitcher(
            currentIndex: shell.currentIndex,
            children: children,
          ),
          builder: (context, state, shell) => _chrome(shell),
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/home',
                  pageBuilder: (c, s) => _plain(
                    const _ListPage(
                      'home list',
                      pushLinks: [('open album', '/album/1')],
                      goLinks: [
                        ('jump to album', '/album/9'),
                        ('go to albums', '/albums'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/albums',
                  pageBuilder: (c, s) => _plain(
                    const _ListPage(
                      'albums list',
                      pushLinks: [('open album', '/album/2')],
                      goLinks: [('open nested', '/albums/7')],
                    ),
                  ),
                  routes: [
                    GoRoute(
                      path: ':id',
                      pageBuilder: (c, s) => _anchored(_detail()),
                    ),
                  ],
                ),
                GoRoute(
                  path: '/album/:id',
                  pageBuilder: (c, s) => _anchored(_detail()),
                ),
              ],
            ),
          ],
        ),
      ],
    );

/// Scale of the transition wrapping the detail page, null when the route
/// carries none at all.
double? _detailScale(WidgetTester tester) {
  final scales = tester.widgetList<ScaleTransition>(find.ancestor(
    of: find.byKey(_detailKey),
    matching: find.byType(ScaleTransition),
  ));
  return scales.isEmpty ? null : scales.first.scale.value;
}

void main() {
  testWidgets('waveOpen stacks the page so its entrance can play',
      (tester) async {
    await tester.pumpWidget(FluentApp.router(routerConfig: _router()));
    await tester.pumpAndSettle();

    // An album opened from Home, i.e. across branches.
    await tester.tap(find.text('open album'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    final growing = _detailScale(tester);
    expect(growing, isNotNull,
        reason: 'no anchored entrance was applied to the destination');
    expect(growing, lessThan(1.0),
        reason: 'the destination mounted complete instead of growing in');

    await tester.pumpAndSettle();
    expect(find.byKey(_detailKey), findsOneWidget);
    expect(find.text('home list', skipOffstage: false), findsOneWidget,
        reason: 'the page it was opened from should still be underneath');
  });

  testWidgets('back closes it back over the surface it grew out of',
      (tester) async {
    await tester.pumpWidget(FluentApp.router(routerConfig: _router()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open album'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('chrome back'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    final shrinking = _detailScale(tester);
    expect(shrinking, isNotNull,
        reason: 'the pushed page left without reversing its entrance');
    expect(shrinking, lessThan(1.0));

    await tester.pumpAndSettle();
    expect(find.byKey(_detailKey), findsNothing);
    expect(find.text('home list'), findsOneWidget);
  });

  testWidgets('go still mounts a sibling route complete, with nothing '
      'to shrink back over — the case waveOpen avoids', (tester) async {
    await tester.pumpWidget(FluentApp.router(routerConfig: _router()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('jump to album'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    expect(_detailScale(tester), 1.0,
        reason: 'a rewritten page list mounts its destination complete');
    await tester.pumpAndSettle();

    await tester.tap(find.text('chrome back'));
    await tester.pumpAndSettle();
    expect(find.byKey(_detailKey), findsOneWidget,
        reason: 'go left nothing on the stack to close back over');
  });

  testWidgets('back also closes a declarative nested stack', (tester) async {
    await tester.pumpWidget(FluentApp.router(routerConfig: _router()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('go to albums'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open nested'));
    await tester.pumpAndSettle();
    expect(find.byKey(_detailKey), findsOneWidget);

    await tester.tap(find.text('chrome back'));
    await tester.pumpAndSettle();

    expect(find.byKey(_detailKey), findsNothing,
        reason: 'the nested page should come back off the stack');
    expect(find.text('albums list'), findsOneWidget);
  });

  group('waveAlbumLocation', () {
    test('carries the pressed card\'s metadata to the album page', () {
      final location = waveAlbumLocation(
        browseId: 'MPREb_p1',
        title: 'Rumours',
        artist: 'Fleetwood Mac',
        artworkUrl: 'https://lh3.googleusercontent.com/x=w544',
      );
      expect(location, startsWith('/album/MPREb_p1?'));
      final uri = Uri.parse(location);
      expect(uri.path, '/album/MPREb_p1');
      expect(uri.queryParameters['title'], 'Rumours');
      expect(uri.queryParameters['artist'], 'Fleetwood Mac');
      expect(
        uri.queryParameters['art'],
        'https://lh3.googleusercontent.com/x=w544',
        reason: 'the album page reads it back as ?art',
      );
    });

    test('escapes ids and titles that would break the path', () {
      final uri = Uri.parse(waveAlbumLocation(
        browseId: 'MPREb/a b',
        title: 'Live & Loud #2',
      ));
      expect(uri.path, '/album/MPREb%2Fa%20b');
      expect(uri.queryParameters['title'], 'Live & Loud #2');
      expect(uri.queryParameters.containsKey('artist'), isFalse);
      expect(uri.queryParameters.containsKey('art'), isFalse);
    });

    test('is a plain path when nothing is known', () {
      expect(waveAlbumLocation(browseId: 'MPREb_p1'), '/album/MPREb_p1');
    });
  });
}
