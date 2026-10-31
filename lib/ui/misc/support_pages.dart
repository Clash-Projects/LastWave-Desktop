import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart'
    show playGenerated, playableFromGenerated;
import '../../features/feed/feed_repository.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/innertube/yt_library_providers.dart';
import '../../features/lastfm/auth_repository.dart';
import '../../features/lastfm/home_repository.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../components/buttons.dart';
import '../components/states.dart';
import '../components/track_row.dart';
import '../theme/tokens.dart';

final _waveFriendsProvider =
    FutureProvider<List<FriendEntry>>((ref) {
  // The Friends tab always shows your own friends. It must not follow
  // viewingProfileProvider: after viewing a friend's profile, `viewing`
  // stays set, and the tab would otherwise list the friend's friends
  // (including your own name on mutual friendships).
  return ref.watch(homeRepositoryProvider).fetchFriends();
});

/// Secondary pages re-homed in the Fluent system.
///
/// These routes remain functional but are no longer separate visual
/// languages: each uses the same hero + table / card patterns as the
/// primary collections. Logic is reused through existing providers.
/// Top tracks query: friend view (or self) + Last.fm period.
typedef _TopQuery = ({String? viewing, String period});

final _waveTopTracksProvider =
    FutureProvider.family<List<HomeTrack>, _TopQuery>(
        (ref, q) {
  return ref.watch(homeRepositoryProvider).fetchTopTracks(
        viewingAs: q.viewing,
        period: q.period,
        limit: 100,
      );
});

const _topPeriods = ['7day', '1month', '12month', 'overall'];

/// YT thumbnail fallback for chart rows without art: Last.fm top-track
/// payloads carry no images and store catalogs miss obscure tracks, so
/// resolve matches for the art-less rows and seed `hqdefault` as the
/// LAST chain entry via `videoIdOf` (official covers always win).
/// Matches are disk-cached, so repeat views resolve instantly.
/// Bounded parallel (4 at a time), fail-soft per track.
final _waveTopTrackVideoIdsProvider =
    FutureProvider.autoDispose.family<Map<String, String>, _TopQuery>(
        (ref, q) async {
  final tracks = await ref.watch(_waveTopTracksProvider(q).future);
  final need =
      tracks.take(30).where((t) => t.artworkUrl.isEmpty).toList();
  if (need.isEmpty) return const {};
  final tube = ref.watch(innerTubeProvider);
  final out = <String, String>{};
  for (var i = 0; i < need.length; i += 4) {
    final batch =
        need.sublist(i, (i + 4).clamp(0, need.length));
    final hits = await Future.wait(batch.map((t) async {
      try {
        final m = await tube
            .findBestMatchOrNull(t.name, t.artist)
            .timeout(const Duration(seconds: 15));
        final id = m?.videoId ?? '';
        return MapEntry(t.key, id);
      } catch (_) {
        return MapEntry(t.key, '');
      }
    }));
    for (final h in hits) {
      if (h.value.isNotEmpty) out[h.key] = h.value;
    }
  }
  return out;
});

String _topPeriodLabel(String period) => switch (period) {
      '7day' => '7 days',
      '1month' => 'Month',
      '12month' => 'Year',
      _ => 'All time',
    };

class WaveProfilePage extends ConsumerStatefulWidget {
  const WaveProfilePage({super.key});

  @override
  ConsumerState<WaveProfilePage> createState() =>
      _WaveProfilePageState();
}

class _WaveProfilePageState
    extends ConsumerState<WaveProfilePage> {
  String _period = '7day';

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authRepositoryProvider);
    final viewing = ref.watch(viewingProfileProvider);
    final user = viewing ?? auth.username;
    if (user.isEmpty) {
      return WaveEmpty(
        icon: FluentIcons.contact,
        title: 'No profile selected',
        subtitle: 'Connect Last.fm in Settings to see your profile.',
        actionLabel: 'Open Settings',
        onAction: () => context.go('/settings?section=lastfm'),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: WaveDensity.contentMax,
          ),
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                'SOCIAL',
                style: WaveType.overline.copyWith(
                  color: waveAccent(context),
                ),
              ),
              Text(user, style: WaveType.pageTitle),
              const SizedBox(height: 4),
              Text(
                viewing != null
                    ? 'Viewing $viewing'
                    : 'Your Last.fm profile',
                style: WaveType.body.copyWith(
                  color: waveTextSecondary(context),
                ),
              ),
              if (viewing != null) ...[
                const SizedBox(height: 8),
                WaveButton(
                  onPressed: () => ref
                      .read(viewingProfileProvider.notifier)
                      .clear(),
                  child:
                      const Text('Back to my profile'),
                ),
              ],
              const SizedBox(height: 16),
              _TopTracksSection(
                viewing: viewing,
                period: _period,
                onPeriod: (v) =>
                    setState(() => _period = v),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Top tracks with period switcher. Ranks by scrobbles; rows also in
/// your YouTube library carry an "on YouTube" badge (self view only —
/// a friend's YouTube is unknowable). Tracks only on YouTube follow
/// in their own shelf.
class _TopTracksSection extends ConsumerWidget {
  final String? viewing;
  final String period;
  final ValueChanged<String> onPeriod;
  const _TopTracksSection({
    required this.viewing,
    required this.period,
    required this.onPeriod,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final topAsync = ref
        .watch(_waveTopTracksProvider((viewing: viewing, period: period)));
    // YT fallback ids for rows without art (resolves in background,
    // empty until ready — rows show the tonal fallback meanwhile).
    final ytIds = ref
            .watch(_waveTopTrackVideoIdsProvider(
                (viewing: viewing, period: period)))
            .valueOrNull ??
        const <String, String>{};
    // Own YouTube library for overlap badges (self view only).
    final ytKeys = viewing == null
        ? {
            for (final t in ref
                    .watch(ytLikedSongsProvider)
                    .valueOrNull ??
                const [])
              '${t.title.toLowerCase()}|${t.artist.toLowerCase()}',
            for (final t in ref
                    .watch(ytHistoryProvider)
                    .valueOrNull ??
                const [])
              '${t.title.toLowerCase()}|${t.artist.toLowerCase()}',
          }
        : const <String>{};
    final ytByKey = viewing == null
        ? <String, GeneratedTrack>{
            for (final t in ref
                    .watch(ytLikedSongsProvider)
                    .valueOrNull ??
                const [])
              '${t.title.toLowerCase()}|${t.artist.toLowerCase()}':
                  GeneratedTrack(
                name: t.title,
                artist: t.artist,
                artworkUrl: t.artworkUrl,
                videoId: t.videoId,
              ),
            for (final t in ref
                    .watch(ytHistoryProvider)
                    .valueOrNull ??
                const [])
              '${t.title.toLowerCase()}|${t.artist.toLowerCase()}':
                  GeneratedTrack(
                name: t.title,
                artist: t.artist,
                artworkUrl: t.artworkUrl,
                videoId: t.videoId,
              ),
          }
        : const <String, GeneratedTrack>{};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'TOP TRACKS',
          style: WaveType.overline
              .copyWith(color: waveAccent(context)),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final p in _topPeriods)
              ToggleButton(
                checked: period == p,
                onChanged: (_) => onPeriod(p),
                child: Text(_topPeriodLabel(p)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        topAsync.when(
          loading: () => const WaveLoading(
            label: 'Loading top tracks…',
          ),
          error: (e, _) => WaveError(
            title: 'Could not load top tracks',
            message: '$e',
            onRetry: () => ref.invalidate(_waveTopTracksProvider(
                (viewing: viewing, period: period))),
          ),
          data: (all) {
            final tracks = all.take(30).toList();
            if (tracks.isEmpty) {
              return const WaveEmpty(
                icon: FluentIcons.music_note,
                title: 'No top tracks yet',
                subtitle:
                    'Scrobble more to fill this chart.',
              );
            }
            final playingKey = ref.watch(
              playbackServiceProvider.select(
                  (s) => s.current?.queueKey),
            );
            List<GeneratedTrack> asGenerated() => tracks
                .map(
                  (t) => GeneratedTrack(
                    name: t.name,
                    artist: t.artist,
                    artworkUrl: t.artworkUrl,
                  ),
                )
                .toList();
            // YouTube-only: liked/history tracks missing from the
            // Last.fm chart entirely.
            final topKeys = {
              for (final t in tracks)
                '${t.name.toLowerCase()}|${t.artist.toLowerCase()}',
            };
            final ytOnly = [
              for (final e in ytByKey.entries)
                if (!topKeys.contains(e.key)) e.value,
            ];
            return Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                WaveDesktopTable<HomeTrack>(
                  items: tracks,
                  keyOf: (t) =>
                      '${t.name.toLowerCase()}|${t.artist.toLowerCase()}',
                  titleOf: (t) => t.name,
                  subtitleOf: (t) {
                    final plays = t.playCount > 0
                        ? ' · ${t.playCount} plays'
                        : '';
                    final yt = ytKeys.contains(
                            '${t.name.toLowerCase()}|${t.artist.toLowerCase()}')
                        ? ' · on YouTube'
                        : '';
                    return '${t.artist}$plays$yt';
                  },
                  albumOf: (_) => '',
                  artworkOf: (t) => t.artworkUrl,
                  // subtitleOf carries decorations ('· N plays · on
                  // YouTube') that would poison the official-artwork
                  // lookup — pass clean metadata explicitly.
                  artworkTitleOf: (t) => t.name,
                  artworkArtistOf: (t) => t.artist,
                  videoIdOf: (t) => ytIds[t.key] ?? '',
                  playableOf: (t) => playableFromGenerated(
                      GeneratedTrack(
                    name: t.name,
                    artist: t.artist,
                    artworkUrl: t.artworkUrl,
                  )),
                  durationOf: (_) => '',
                  durationSortOf: (_) => 0,
                  titleSortOf: (t) => t.name.toLowerCase(),
                  artistSortOf: (t) =>
                      t.artist.toLowerCase(),
                  isCurrent: (t) =>
                      playingKey ==
                      '${t.name.toLowerCase()}|${t.artist.toLowerCase()}',
                  isPlaying: (t) {
                    final playing = ref.watch(
                      playbackServiceProvider.select(
                          (p) => p.isPlaying),
                    );
                    return playingKey ==
                            '${t.name.toLowerCase()}|${t.artist.toLowerCase()}' &&
                        playing;
                  },
                  showArtistColumn: true,
                  shrinkWrap: true,
                  selectable: true,
                  onPlay: (i) => playGenerated(
                    ref,
                    context,
                    asGenerated()[i],
                    sourceLabel: 'Top tracks',
                    queueAll: asGenerated(),
                    startIndex: i,
                  ),
                ),
                if (ytOnly.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'ONLY ON YOUTUBE',
                    style: WaveType.overline.copyWith(
                        color: waveAccent(context)),
                  ),
                  const SizedBox(height: 8),
                  for (var i = 0;
                      i < ytOnly.length.clamp(0, 10);
                      i++)
                    WaveTrackRow(
                      index: i + 1,
                      title: ytOnly[i].name,
                      artist: ytOnly[i].artist,
                      artworkUrl: ytOnly[i].artworkUrl,
                      videoId: ytOnly[i].videoId,
                      playing: playingKey ==
                          ytOnly[i].key,
                      isCurrent: playingKey ==
                          ytOnly[i].key,
                      onTap: () => playGenerated(
                        ref,
                        context,
                        ytOnly[i],
                        sourceLabel: 'Top tracks',
                      ),
                    ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class WaveFriendsPage extends ConsumerWidget {
  const WaveFriendsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final friends = ref.watch(_waveFriendsProvider);
    return friends.when(
      loading: () => const WaveLoading(
        label: 'Loading friends…',
      ),
      error: (e, _) => WaveError(
        title: 'Could not load friends',
        message: '$e',
        onRetry: () =>
            ref.invalidate(_waveFriendsProvider),
      ),
      data: (list) {
        if (list.isEmpty) {
          return const WaveEmpty(
            icon: FluentIcons.people,
            title: 'No friends yet',
            subtitle:
                'Add friends on Last.fm to see them here.',
          );
        }
        return ListView(
          padding:
              const EdgeInsets.fromLTRB(24, 20, 24, 24),
          children: [
            const Text(
              'Friends',
              style: WaveType.pageTitle,
            ),
            const SizedBox(height: 8),
            for (final f in list)
              ListTile(
                leading: const Icon(
                  FluentIcons.contact,
                  size: 18,
                ),
                title: Text(f.name),
                subtitle: Text(
                  f.realName.isNotEmpty
                      ? f.realName
                      : f.name,
                ),
                trailing: WaveButton(
                  onPressed: () {
                    ref
                        .read(
                          viewingProfileProvider
                              .notifier,
                        )
                        .view(f.name);
                    context.go('/profile');
                  },
                  child: const Text('View'),
                ),
                onPressed: () {
                  ref
                      .read(
                        viewingProfileProvider.notifier,
                      )
                      .view(f.name);
                  context.go('/profile');
                },
              ),
          ],
        );
      },
    );
  }
}

class WaveMixLabPage extends ConsumerStatefulWidget {
  const WaveMixLabPage({super.key});

  @override
  ConsumerState<WaveMixLabPage> createState() =>
      _WaveMixLabPageState();
}

class _WaveMixLabPageState extends ConsumerState<WaveMixLabPage> {
  static const _modes = <(MixMode, String)>[
    (MixMode.top, 'Top tracks'),
    (MixMode.recent, 'Recent'),
    (MixMode.similarTracks, 'Song radio'),
    (MixMode.similarArtists, 'Similar artists'),
    (MixMode.tag, 'Tag'),
    (MixMode.mix, 'Mix'),
    (MixMode.recommendations, 'Recommendations'),
    (MixMode.neverHeard, 'Never heard'),
    (MixMode.library, 'Library'),
  ];
  static const _periods = <(String, String)>[
    ('overall', 'Overall'),
    ('12month', '12 months'),
    ('6month', '6 months'),
    ('3month', '3 months'),
    ('1month', '1 month'),
    ('7day', '7 days'),
  ];

  MixMode _mode = MixMode.mix;
  String _period = 'overall';
  int _length = 25;
  bool _busy = false;
  String? _error;
  List<GeneratedTrack> _tracks = const [];
  final _seedTrack = TextEditingController();
  final _seedArtist = TextEditingController();
  final _tag = TextEditingController();

  bool get _periodMatters => switch (_mode) {
        MixMode.top ||
        MixMode.recent ||
        MixMode.similarArtists ||
        MixMode.neverHeard ||
        MixMode.library =>
          true,
        _ => false,
      };

  bool get _lengthLocked => _mode == MixMode.recommendations;
  int get _count => _lengthLocked ? 35 : _length;

  @override
  void dispose() {
    _seedTrack.dispose();
    _seedArtist.dispose();
    _tag.dispose();
    super.dispose();
  }

  String get _modeLabel =>
      _modes.firstWhere((m) => m.$1 == _mode).$2;

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final tracks = await ref.read(feedRepositoryProvider).generate(
            mode: _mode,
            total: _count,
            period: _period,
            seedTrack: _seedTrack.text,
            seedArtist: _seedArtist.text,
            tag: _tag.text,
          );
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  Future<void> _save() async {
    if (_tracks.isEmpty) return;
    final name = TextEditingController(text: _modeLabel);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Save playlist'),
        content: TextBox(
          controller: name,
          placeholder: 'Playlist name',
        ),
        actions: [
          WaveButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          WaveFilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final title = name.text.trim();
    name.dispose();
    if (ok != true || !mounted) return;
    final saved = await ref.read(playlistRepositoryProvider.notifier).saveGenerated(
          title.isEmpty ? _modeLabel : title,
          [
            for (final t in _tracks)
              StoredTrack(
                name: t.name,
                artist: t.artist,
                album: t.album,
                artworkUrl: t.artworkUrl,
                videoId: t.videoId,
                durationSeconds: t.durationSeconds,
                playbackUrl: t.playbackUrl,
              ),
          ],
        );
    if (mounted) context.go('/playlists/${saved.id}');
  }

  @override
  Widget build(BuildContext context) {
    final playingKey = ref.watch(
      playbackServiceProvider.select((s) => s.current?.queueKey),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: WaveDensity.contentMax,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'LISTEN',
                style: WaveType.overline.copyWith(color: waveAccent(context)),
              ),
              const Text('Mix Lab', style: WaveType.pageTitle),
              const SizedBox(height: 2),
              Text(
                '$_count tracks · $_modeLabel',
                style: WaveType.body.copyWith(color: waveTextSecondary(context)),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final mode in _modes)
                    ToggleButton(
                      checked: _mode == mode.$1,
                      onChanged: (_) => setState(() => _mode = mode.$1),
                      child: Text(mode.$2),
                    ),
                ],
              ),
              if (_periodMatters) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final period in _periods)
                      ToggleButton(
                        checked: _period == period.$1,
                        onChanged: (_) => setState(() => _period = period.$1),
                        child: Text(period.$2),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  SizedBox(
                    width: 92,
                    child: Text('$_count tracks', style: WaveType.meta),
                  ),
                  Expanded(
                    child: Slider(
                      value: _count.toDouble(),
                      min: 5,
                      max: 35,
                      divisions: 30,
                      onChanged: _lengthLocked
                          ? null
                          : (v) => setState(() => _length = v.round()),
                    ),
                  ),
                ],
              ),
              if (_mode == MixMode.similarTracks) ...[
                const SizedBox(height: 8),
                TextBox(controller: _seedTrack, placeholder: 'Song'),
                const SizedBox(height: 8),
                TextBox(controller: _seedArtist, placeholder: 'Artist'),
              ],
              if (_mode == MixMode.similarArtists) ...[
                const SizedBox(height: 8),
                TextBox(controller: _seedArtist, placeholder: 'Artist'),
              ],
              if (_mode == MixMode.tag) ...[
                const SizedBox(height: 8),
                TextBox(controller: _tag, placeholder: 'Tag'),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  WavePrimaryButton(
                    label: _busy ? 'Generating…' : 'Generate',
                    icon: FluentIcons.refresh,
                    onPressed: _busy ? null : _generate,
                  ),
                  if (_tracks.isNotEmpty) ...[
                    WaveGhostButton(
                      label: 'Play',
                      icon: FluentIcons.play,
                      onPressed: () => playGenerated(
                        ref,
                        context,
                        _tracks.first,
                        sourceLabel: 'Mix Lab',
                        queueAll: _tracks,
                      ),
                    ),
                    WaveGhostButton(
                      label: 'Save playlist',
                      icon: FluentIcons.save,
                      onPressed: _save,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              if (_busy)
                const WaveLoading(label: 'Generating mix…')
              else if (_error != null)
                WaveError(
                  title: 'Mix failed',
                  message: _error!,
                  onRetry: _generate,
                )
              else if (_tracks.isEmpty)
                const WaveEmpty(
                  icon: FluentIcons.lightbulb,
                  title: 'No mix yet',
                  subtitle:
                      'Pick a mode and generate a playlist from your taste.',
                )
              else
                Column(
                  children: [
                    const WaveTrackTableHeader(showAlbum: false),
                    for (var i = 0; i < _tracks.length; i++)
                      WaveTrackRow(
                        index: i + 1,
                        title: _tracks[i].name,
                        artist: _tracks[i].artist,
                        artworkUrl: _tracks[i].artworkUrl,
                        videoId: _tracks[i].videoId,
                        playing: playingKey == _tracks[i].key,
                        isCurrent: playingKey == _tracks[i].key,
                        onTap: () => playGenerated(
                          ref,
                          context,
                          _tracks[i],
                          sourceLabel: 'Mix Lab',
                          queueAll: _tracks,
                          startIndex: i,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}
