import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';
import 'package:lastwave_desktop/features/innertube/yt_library_providers.dart';
import 'package:lastwave_desktop/features/lastfm/auth_repository.dart';
import 'package:lastwave_desktop/features/lastfm/home_repository.dart';
import 'package:lastwave_desktop/features/lastfm/profile_providers.dart';
import 'package:lastwave_desktop/ui/components/artwork.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('userAvatarUrlProvider', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('returns empty when signed out', () {
      final container = ProviderContainer(
        overrides: [
          authRepositoryProvider.overrideWith((ref) => _MockAuth(const AuthState())),
        ],
      );
      addTearDown(container.dispose);

      final avatar = container.read(userAvatarUrlProvider);
      expect(avatar, isEmpty);
    });

    test('returns Last.fm avatar when signed in and available', () async {
      final container = ProviderContainer(
        overrides: [
          authRepositoryProvider.overrideWith(
            (ref) => _MockAuth(const AuthState(
              status: AuthStatus.signedIn,
              username: 'test_user',
            )),
          ),
          userProfileStatsProvider.overrideWith(
            (ref, viewing) => Future.value(const HomeStats(
              avatarUrl: 'https://example.com/lastfm_avatar.png',
            )),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(userProfileStatsProvider(null).future);
      final avatar = container.read(userAvatarUrlProvider);
      expect(avatar, equals('https://example.com/lastfm_avatar.png'));
    });

    test('falls back to YouTube photoUrl when Last.fm avatar is empty', () async {
      final container = ProviderContainer(
        overrides: [
          authRepositoryProvider.overrideWith(
            (ref) => _MockAuth(const AuthState(
              status: AuthStatus.signedIn,
              username: 'test_user',
            )),
          ),
          userProfileStatsProvider.overrideWith(
            (ref, viewing) => Future.value(const HomeStats(avatarUrl: '')),
          ),
          ytAccountProvider.overrideWith(
            (ref) => Future.value(const YtAccount(
              photoUrl: 'https://example.com/youtube_avatar.png',
            )),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(userProfileStatsProvider(null).future);
      await container.read(ytAccountProvider.future);
      final avatar = container.read(userAvatarUrlProvider);
      expect(avatar, equals('https://example.com/youtube_avatar.png'));
    });

    test('retries userProfileStatsProvider on invalidate after transient failure', () async {
      int attempts = 0;
      final container = ProviderContainer(
        overrides: [
          authRepositoryProvider.overrideWith(
            (ref) => _MockAuth(const AuthState(
              status: AuthStatus.signedIn,
              username: 'test_user',
            )),
          ),
          userProfileStatsProvider.overrideWith((ref, viewing) {
            attempts++;
            if (attempts == 1) {
              return Future.error(Exception('Network error'));
            }
            return Future.value(const HomeStats(avatarUrl: 'https://example.com/retry.png'));
          }),
        ],
      );
      addTearDown(container.dispose);

      // First attempt fails
      try {
        await container.read(userProfileStatsProvider(null).future);
        fail('Expected error');
      } catch (e) {
        expect(e, isA<Exception>());
      }

      // Invalidate to retry (as triggered on /profile visit or tap)
      container.invalidate(userProfileStatsProvider(null));

      final stats = await container.read(userProfileStatsProvider(null).future);
      expect(stats.avatarUrl, equals('https://example.com/retry.png'));
      expect(attempts, equals(2));
    });
  });

  group('Avatar rendering in UI', () {
    testWidgets('renders letter initial when avatar URL is empty', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authRepositoryProvider.overrideWith(
              (ref) => _MockAuth(const AuthState(
                status: AuthStatus.signedIn,
                username: 'NONDEADER',
              )),
            ),
            userAvatarUrlProvider.overrideWithValue(''),
          ],
          child: const FluentApp(
            home: ScaffoldPage(
              content: _AvatarProbe(),
            ),
          ),
        ),
      );

      expect(find.text('N'), findsOneWidget);
      expect(find.byType(WaveArtwork), findsNothing);
    });

    testWidgets('renders WaveArtwork.circle when avatar URL is present', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authRepositoryProvider.overrideWith(
              (ref) => _MockAuth(const AuthState(
                status: AuthStatus.signedIn,
                username: 'NONDEADER',
              )),
            ),
            userAvatarUrlProvider.overrideWithValue('https://example.com/pfp.jpg'),
          ],
          child: const FluentApp(
            home: ScaffoldPage(
              content: _AvatarProbe(),
            ),
          ),
        ),
      );

      expect(find.byType(WaveArtwork), findsOneWidget);
    });
  });
}

class _AvatarProbe extends ConsumerWidget {
  const _AvatarProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authRepositoryProvider);
    final avatarUrl = ref.watch(userAvatarUrlProvider);
    final username = auth.username;

    if (avatarUrl.isNotEmpty) {
      return WaveArtwork.circle(
        url: avatarUrl,
        size: 26,
        label: username,
        upgrade: false,
      );
    }
    return Text(username.isNotEmpty ? username[0].toUpperCase() : '?');
  }
}

class _MockAuth extends StateNotifier<AuthState> implements AuthRepository {
  _MockAuth(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
