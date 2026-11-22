import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../features/lastfm/auth_repository.dart';
import '../../core/storage/prefs.dart';
import '../../features/home/home_snapshot.dart';
import '../../features/lastfm/home_repository.dart';
import '../../features/lastfm/lastfm_snapshot.dart';
import '../../features/scrobblers/extra_scrobblers.dart';
import '../../features/search/search_repository.dart';
import '../../features/search/shared_providers.dart' show databaseProvider;
import '../components/artwork.dart';
import '../components/buttons.dart';
import '../components/states.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Where a friend comes from. The Friends tab combines every connected
/// scrobbler: Last.fm friends, the ListenBrainz users you follow, and
/// Libre.fm users you added here.
enum FriendSource {
  lastfm('Last.fm'),
  listenbrainz('ListenBrainz'),
  librefm('Libre.fm');

  final String label;
  const FriendSource(this.label);
}

/// Friends added on this device, by name. Last.fm and Libre.fm have no
/// public "add friend" call, so these live in kv_store next to the
/// friends each service lists for you.
class LocalFriends extends StateNotifier<List<String>> {
  final void Function(String json) _save;
  LocalFriends(String? stored, this._save) : super(_decode(stored));

  static const storageKey = 'friends_local_v1';
  static const libreStorageKey = 'friends_librefm_v1';

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

LocalFriends _localFriends(Ref ref, String key) {
  final db = ref.watch(databaseProvider);
  String? raw;
  try {
    raw = db.kvGet(key);
  } catch (_) {}
  return LocalFriends(raw, (json) {
    try {
      db.kvSet(key, json);
    } catch (_) {}
  });
}

/// Last.fm names added here.
final localFriendsProvider =
    StateNotifierProvider<LocalFriends, List<String>>(
        (ref) => _localFriends(ref, LocalFriends.storageKey));

/// Libre.fm names added here.
final localLibreFriendsProvider =
    StateNotifierProvider<LocalFriends, List<String>>(
        (ref) => _localFriends(ref, LocalFriends.libreStorageKey));

/// Which scrobblers are connected (Last.fm: a signed-in session).
final _connectedProvider =
    Provider<({bool lastfm, bool listenbrainz, bool librefm})>((ref) {
  ref.watch(extraScrobblersRevisionProvider);
  final auth = ref.watch(authRepositoryProvider);
  return (
    lastfm: auth.status == AuthStatus.signedIn && auth.username.isNotEmpty,
    listenbrainz: ref.watch(listenBrainzProvider).connected,
    librefm: ref.watch(libreFmProvider).connected,
  );
});

final _lastFmFriendsProvider = FutureProvider<List<FriendEntry>>((ref) async {
  if (!ref.watch(_connectedProvider).lastfm) return const [];
  // Always your own friends: it must not follow viewingProfileProvider.
  final home = ref.watch(homeRepositoryProvider);
  return swrLoad<List<FriendEntry>>(
    ref,
    key: lastFmCacheKey('friends', ref.read(prefsProvider).username),
    codec: friendEntriesSnapshotCodec,
    group: cacheGroupLastFm,
    maxAge: lastFmCacheMaxAge,
    fetch: home.fetchFriends,
  );
});

/// The ListenBrainz users you follow (its real follow list).
final _lbFollowingProvider = FutureProvider<List<String>>((ref) async {
  if (!ref.watch(_connectedProvider).listenbrainz) return const [];
  return await ref.watch(listenBrainzProvider).following() ?? const [];
});

/// Avatar for a Last.fm name added here (stored by name only). Not
/// autoDispose: looked up once per session, instant on every return.
final _friendAvatarProvider =
    FutureProvider.family<String, String>((ref, name) async {
  final user = await ref.watch(searchRepositoryProvider).lookupUser(name);
  return user?.artworkUrl ?? '';
});

/// Avatar for a Libre.fm name added here. Kept for the session: Libre.fm
/// rate-limits quickly, so each name is looked up once.
final _libreAvatarProvider =
    FutureProvider.family<String, String>((ref, name) async {
  return (await ref.watch(libreFmProvider).userCard(name))?.avatar ?? '';
});

/// Search across every connected service.
final _friendSearchProvider = FutureProvider.autoDispose
    .family<List<_Person>, String>((ref, q) async {
  if (q.trim().length < 2) return const [];
  final on = ref.watch(_connectedProvider);
  final results = await Future.wait([
    if (on.lastfm)
      ref
          .watch(searchRepositoryProvider)
          .search(SearchTab.users, q)
          .then((users) => [
                for (final u in users)
                  _Person(u.name, FriendSource.lastfm,
                      subtitle: u.subtitle, avatar: u.artworkUrl),
              ])
          .catchError((_) => <_Person>[]),
    if (on.listenbrainz)
      ref.watch(listenBrainzProvider).searchUsers(q).then((names) => [
            for (final n in names) _Person(n, FriendSource.listenbrainz),
          ]),
    // Libre.fm has no user search: an exact name is looked up.
    if (on.librefm)
      ref.watch(libreFmProvider).userCard(q).then((card) => [
            if (card != null)
              _Person(card.name, FriendSource.librefm, avatar: card.avatar),
          ]),
  ]);
  return [for (final r in results) ...r];
});

class _Person {
  final String name;
  final FriendSource source;
  final String subtitle;
  final String avatar;
  const _Person(this.name, this.source,
      {this.subtitle = '', this.avatar = ''});
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

  /// Last ListenBrainz follow/unfollow failure, shown under the search.
  String? _lbError;

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

  String _me(FriendSource s) => switch (s) {
        FriendSource.lastfm => ref.read(authRepositoryProvider).username,
        FriendSource.listenbrainz => ref.read(listenBrainzProvider).username,
        FriendSource.librefm => ref.read(libreFmProvider).username,
      }
          .toLowerCase();

  void _openProfile(_Person p) {
    switch (p.source) {
      case FriendSource.lastfm:
        ref.read(viewingProfileProvider.notifier).view(p.name);
        context.go('/profile');
      case FriendSource.listenbrainz:
        unawaited(launchUrl(
            ref.read(listenBrainzProvider).profileUrlFor(p.name),
            mode: LaunchMode.externalApplication));
      case FriendSource.librefm:
        unawaited(launchUrl(ref.read(libreFmProvider).profileUrlFor(p.name),
            mode: LaunchMode.externalApplication));
    }
  }

  Future<void> _setListenBrainzFollow(String name, bool follow) async {
    final err = await ref
        .read(listenBrainzProvider)
        .setFollowing(name, follow: follow);
    if (!mounted) return;
    setState(() => _lbError = err == null
        ? null
        : 'ListenBrainz: couldn\'t ${follow ? 'follow' : 'unfollow'} $name ($err)');
    ref.invalidate(_lbFollowingProvider);
  }

  /// Everyone you follow, across the connected services.
  List<_Person> _friends() {
    final out = <_Person>[];
    final lastFm = ref.watch(_lastFmFriendsProvider).valueOrNull ?? const [];
    final seenLastFm = <String>{};
    for (final f in lastFm) {
      seenLastFm.add(f.name.toLowerCase());
      out.add(_Person(f.name, FriendSource.lastfm,
          subtitle: f.realName, avatar: f.avatarUrl));
    }
    if (ref.watch(_connectedProvider).lastfm) {
      for (final n in ref.watch(localFriendsProvider)) {
        if (seenLastFm.add(n.toLowerCase())) {
          out.add(_Person(n, FriendSource.lastfm,
              avatar: ref
                      .watch(_friendAvatarProvider(n.toLowerCase()))
                      .valueOrNull ??
                  ''));
        }
      }
    }
    for (final n in ref.watch(_lbFollowingProvider).valueOrNull ?? const []) {
      out.add(_Person(n, FriendSource.listenbrainz));
    }
    if (ref.watch(_connectedProvider).librefm) {
      for (final n in ref.watch(localLibreFriendsProvider)) {
        out.add(_Person(n, FriendSource.librefm,
            avatar: ref.watch(_libreAvatarProvider(n.toLowerCase())).valueOrNull ??
                ''));
      }
    }
    return out;
  }

  /// Whether [p] is already a friend, and whether it can be removed here
  /// (Last.fm's own list is managed on Last.fm).
  ({bool added, bool canRemove}) _state(_Person p) {
    final n = p.name.toLowerCase();
    switch (p.source) {
      case FriendSource.lastfm:
        final official = (ref.watch(_lastFmFriendsProvider).valueOrNull ??
                const [])
            .any((f) => f.name.toLowerCase() == n);
        final local = ref.watch(localFriendsProvider.notifier).has(p.name);
        return (added: official || local, canRemove: !official);
      case FriendSource.listenbrainz:
        final following =
            (ref.watch(_lbFollowingProvider).valueOrNull ?? const [])
                .any((f) => f.toLowerCase() == n);
        return (added: following, canRemove: true);
      case FriendSource.librefm:
        return (
          added: ref.watch(localLibreFriendsProvider.notifier).has(p.name),
          canRemove: true,
        );
    }
  }

  void _toggle(_Person p) {
    final s = _state(p);
    switch (p.source) {
      case FriendSource.lastfm:
        final n = ref.read(localFriendsProvider.notifier);
        s.added ? n.remove(p.name) : n.add(p.name);
      case FriendSource.listenbrainz:
        unawaited(_setListenBrainzFollow(p.name, !s.added));
      case FriendSource.librefm:
        final n = ref.read(localLibreFriendsProvider.notifier);
        s.added ? n.remove(p.name) : n.add(p.name);
    }
  }

  Widget _row(_Person p) {
    final s = _state(p);
    return _PersonRow(
      name: p.name,
      source: p.source,
      subtitle: p.subtitle,
      avatarUrl: p.avatar,
      isYou: p.name.toLowerCase() == _me(p.source),
      added: s.added,
      canRemove: s.canRemove,
      onView: () => _openProfile(p),
      onToggle: () => _toggle(p),
    );
  }

  @override
  Widget build(BuildContext context) {
    final on = ref.watch(_connectedProvider);
    final anyConnected = on.lastfm || on.listenbrainz || on.librefm;
    final loading = ref.watch(_lastFmFriendsProvider).isLoading ||
        ref.watch(_lbFollowingProvider).isLoading;
    final friends = anyConnected ? _friends() : const <_Person>[];

    return ListView(
      padding:
          waveDockPadding(context, const EdgeInsets.fromLTRB(24, 20, 24, 24)),
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
              if (anyConnected)
                Text(
                  'From ${[
                    if (on.lastfm) 'Last.fm',
                    if (on.listenbrainz) 'ListenBrainz',
                    if (on.librefm) 'Libre.fm',
                  ].join(', ')}',
                  style:
                      WaveType.meta.copyWith(color: waveTextTertiary(context)),
                ),
              const SizedBox(height: 14),
              if (!anyConnected)
                WaveEmpty(
                  icon: WaveIcons.friends,
                  title: 'Connect a scrobbler',
                  subtitle: 'Friends come from Last.fm, ListenBrainz or '
                      'Libre.fm. Connect any of them to see who you follow '
                      'and add people.',
                  actionLabel: 'Open scrobbler settings',
                  onAction: () => context.go('/settings?section=lastfm'),
                )
              else ...[
                TextBox(
                  controller: _controller,
                  placeholder: on.librefm && !on.lastfm && !on.listenbrainz
                      ? 'Exact Libre.fm username to add'
                      : 'Search users to add',
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
                if (_lbError != null) ...[
                  const SizedBox(height: 6),
                  Text(_lbError!,
                      style: WaveType.meta.copyWith(color: Colors.red)),
                ],
                const SizedBox(height: 14),
                if (_query.length >= 2)
                  _results(context)
                else if (loading && friends.isEmpty)
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
                  for (final f in friends) _row(f),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _results(BuildContext context) {
    final async = ref.watch(_friendSearchProvider(_query));
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
            subtitle: 'Try the exact username.',
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'USERS · ${users.length}',
              style:
                  WaveType.overline.copyWith(color: waveTextTertiary(context)),
            ),
            const SizedBox(height: 6),
            for (final u in users) _row(u),
          ],
        );
      },
    );
  }
}

class _PersonRow extends StatelessWidget {
  final String name;
  final FriendSource source;
  final String subtitle;
  final String avatarUrl;
  final bool added;
  final bool canRemove;
  final bool isYou;
  final VoidCallback onView;
  final VoidCallback onToggle;

  const _PersonRow({
    required this.name,
    required this.source,
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
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            isYou ? '$name (you)' : name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.trackTitle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _SourceChip(source),
                      ],
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
                    label: source == FriendSource.listenbrainz
                        ? 'Follow'
                        : 'Add',
                    icon: FluentIcons.add,
                    onPressed: onToggle,
                  )
                else if (canRemove)
                  WaveGhostButton(
                    label: source == FriendSource.listenbrainz
                        ? 'Unfollow'
                        : 'Remove',
                    onPressed: onToggle,
                  )
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

/// Small label naming the service a person is from.
class _SourceChip extends StatelessWidget {
  final FriendSource source;
  const _SourceChip(this.source);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(WaveRadius.tiny),
        border: Border.all(color: waveOutline(context)),
      ),
      child: Text(
        source.label,
        style: WaveType.meta.copyWith(
          fontSize: 10.5,
          color: waveTextTertiary(context),
        ),
      ),
    );
  }
}
