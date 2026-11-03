import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/lastfm/auth_repository.dart';
import '../../features/lastfm/home_repository.dart';
import '../../features/search/search_repository.dart';
import '../../features/search/shared_providers.dart' show databaseProvider;
import '../components/artwork.dart';
import '../components/buttons.dart';
import '../components/states.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Friends you added yourself. Last.fm has no public "add friend" call, so
/// these are kept on this device (kv_store) and shown next to the friends
/// Last.fm already lists for you.
class LocalFriends extends StateNotifier<List<String>> {
  final void Function(String json) _save;
  LocalFriends(String? stored, this._save) : super(_decode(stored));

  static const storageKey = 'friends_local_v1';

  static List<String> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List).map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  bool has(String name) =>
      state.any((n) => n.toLowerCase() == name.toLowerCase());

  void add(String name) {
    final n = name.trim();
    if (n.isEmpty || has(n)) return;
    state = [...state, n];
    _save(jsonEncode(state));
  }

  void remove(String name) {
    state = [
      for (final n in state)
        if (n.toLowerCase() != name.toLowerCase()) n,
    ];
    _save(jsonEncode(state));
  }
}

final localFriendsProvider =
    StateNotifierProvider<LocalFriends, List<String>>((ref) {
  final db = ref.watch(databaseProvider);
  String? raw;
  try {
    raw = db.kvGet(LocalFriends.storageKey);
  } catch (_) {}
  return LocalFriends(raw, (json) {
    try {
      db.kvSet(LocalFriends.storageKey, json);
    } catch (_) {}
  });
});

final _lastFmFriendsProvider = FutureProvider<List<FriendEntry>>((ref) {
  // Always your own friends: it must not follow viewingProfileProvider.
  return ref.watch(homeRepositoryProvider).fetchFriends();
});

/// Avatar for a friend added here (stored by name only, so it has none).
/// Not autoDispose: looked up once per session and kept, so the Friends
/// tab shows the same pictures instantly on every return.
final _friendAvatarProvider =
    FutureProvider.family<String, String>((ref, name) async {
  final user =
      await ref.watch(searchRepositoryProvider).lookupUser(name);
  return user?.artworkUrl ?? '';
});

final _friendSearchProvider = FutureProvider.autoDispose
    .family<List<SearchResultItem>, String>((ref, q) {
  if (q.trim().length < 2) return const [];
  return ref.watch(searchRepositoryProvider).search(SearchTab.users, q);
});

void _openProfile(BuildContext context, WidgetRef ref, String name) {
  ref.read(viewingProfileProvider.notifier).view(name);
  context.go('/profile');
}

class WaveFriendsPage extends ConsumerStatefulWidget {
  const WaveFriendsPage({super.key});

  @override
  ConsumerState<WaveFriendsPage> createState() => _WaveFriendsPageState();
}

class _WaveFriendsPageState extends ConsumerState<WaveFriendsPage> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _query = v.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final lastFm = ref.watch(_lastFmFriendsProvider);
    final local = ref.watch(localFriendsProvider);
    final me = ref.watch(authRepositoryProvider).username.toLowerCase();

    // Last.fm friends + the ones added here, one list.
    final friends = <FriendEntry>[
      ...(lastFm.valueOrNull ?? const <FriendEntry>[]),
    ];
    final seen = friends.map((f) => f.name.toLowerCase()).toSet();
    for (final n in local) {
      if (seen.add(n.toLowerCase())) friends.add(FriendEntry(name: n));
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: WaveDensity.contentMax),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SOCIAL',
                style: WaveType.overline.copyWith(color: waveAccent(context)),
              ),
              const Text('Friends', style: WaveType.pageTitle),
              const SizedBox(height: 14),
              TextBox(
                controller: _controller,
                placeholder: 'Search users to add',
                prefix: const Padding(
                  padding: EdgeInsets.only(left: 10),
                  child: Icon(WaveIcons.search, size: 14),
                ),
                suffix: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(FluentIcons.clear, size: 12),
                        onPressed: () {
                          _controller.clear();
                          _debounce?.cancel();
                          setState(() => _query = '');
                        },
                      ),
                onChanged: _onChanged,
              ),
              const SizedBox(height: 14),
              if (_query.length >= 2) _results(context, me) else ...[
                if (lastFm.isLoading && friends.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(child: ProgressRing()),
                  )
                else if (friends.isEmpty)
                  const WaveEmpty(
                    icon: WaveIcons.friends,
                    title: 'No friends yet',
                    subtitle:
                        'Search for a user above and add them to see them here.',
                  )
                else ...[
                  Text(
                    'YOUR FRIENDS · ${friends.length}',
                    style: WaveType.overline
                        .copyWith(color: waveTextTertiary(context)),
                  ),
                  const SizedBox(height: 6),
                  for (final f in friends)
                    _PersonRow(
                      name: f.name,
                      subtitle: f.realName,
                      avatarUrl: f.avatarUrl.isNotEmpty
                          ? f.avatarUrl
                          : ref
                                  .watch(_friendAvatarProvider(
                                      f.name.toLowerCase()))
                                  .valueOrNull ??
                              '',
                      added: true,
                      // Only friends added here can be removed; Last.fm's own
                      // list is managed on Last.fm.
                      canRemove: ref.read(localFriendsProvider.notifier).has(
                            f.name,
                          ) &&
                          !(lastFm.valueOrNull ?? const <FriendEntry>[]).any(
                            (l) => l.name.toLowerCase() == f.name.toLowerCase(),
                          ),
                      onView: () => _openProfile(context, ref, f.name),
                      onToggle: () =>
                          ref.read(localFriendsProvider.notifier).remove(f.name),
                    ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _results(BuildContext context, String me) {
    final async = ref.watch(_friendSearchProvider(_query));
    final local = ref.watch(localFriendsProvider);
    final lastFmNames = {
      for (final f in ref.watch(_lastFmFriendsProvider).valueOrNull ??
          const <FriendEntry>[])
        f.name.toLowerCase(),
    };
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: ProgressRing()),
      ),
      error: (e, _) => WaveError(
        title: 'Search failed',
        message: '$e',
        onRetry: () => ref.invalidate(_friendSearchProvider(_query)),
      ),
      data: (users) {
        if (users.isEmpty) {
          return const WaveEmpty(
            icon: WaveIcons.search,
            title: 'No users found',
            subtitle: 'Try the exact Last.fm username.',
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'USERS · ${users.length}',
              style: WaveType.overline
                  .copyWith(color: waveTextTertiary(context)),
            ),
            const SizedBox(height: 6),
            for (final u in users)
              _PersonRow(
                name: u.name,
                subtitle: u.subtitle,
                avatarUrl: u.artworkUrl,
                isYou: u.name.toLowerCase() == me,
                added: lastFmNames.contains(u.name.toLowerCase()) ||
                    local.any((n) => n.toLowerCase() == u.name.toLowerCase()),
                canRemove: !lastFmNames.contains(u.name.toLowerCase()),
                onView: () => _openProfile(context, ref, u.name),
                onToggle: () {
                  final n = ref.read(localFriendsProvider.notifier);
                  n.has(u.name) ? n.remove(u.name) : n.add(u.name);
                },
              ),
          ],
        );
      },
    );
  }
}

class _PersonRow extends StatelessWidget {
  final String name;
  final String subtitle;
  final String avatarUrl;
  final bool added;
  final bool canRemove;
  final bool isYou;
  final VoidCallback onView;
  final VoidCallback onToggle;

  const _PersonRow({
    required this.name,
    required this.subtitle,
    required this.avatarUrl,
    required this.added,
    required this.onView,
    required this.onToggle,
    this.canRemove = true,
    this.isYou = false,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onView,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              WaveArtwork.circle(
                url: avatarUrl,
                size: 44,
                label: name,
                title: name,
                artist: name,
                upgrade: false,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isYou ? '$name (you)' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.trackTitle,
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.meta
                            .copyWith(color: waveTextSecondary(context)),
                      ),
                  ],
                ),
              ),
              WaveButton(onPressed: onView, child: const Text('Profile')),
              if (!isYou) ...[
                const SizedBox(width: 8),
                if (!added)
                  WavePrimaryButton(
                    label: 'Add',
                    icon: FluentIcons.add,
                    onPressed: onToggle,
                  )
                else if (canRemove)
                  WaveGhostButton(label: 'Remove', onPressed: onToggle)
                else
                  Text(
                    'Friends',
                    style: WaveType.meta
                        .copyWith(color: waveTextTertiary(context)),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
