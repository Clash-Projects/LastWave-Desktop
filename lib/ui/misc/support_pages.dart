import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart'
    show playGenerated, playableFromGenerated;
import '../../features/feed/feed_repository.dart';
import '../../features/innertube/yt_library_providers.dart';
import '../../features/lastfm/auth_repository.dart';
import '../../features/lastfm/home_repository.dart';
import '../../features/player/playback_service.dart';
import '../components/buttons.dart';
import '../components/states.dart';
import '../components/track_row.dart';
import '../theme/tokens.dart';

final _waveFriendsProvider =
    FutureProvider<List<FriendEntry>>((ref) {
  final viewing = ref.watch(viewingProfileProvider);
  return ref.watch(homeRepositoryProvider).fetchFriends(viewingAs: viewing);
});

final _waveMixProvider = FutureProvider.autoDispose
    .family<List<GeneratedTrack>, int>((ref, total) {
  return ref.watch(feedRepositoryProvider).fetchMix(total: total);
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
        subtitle: 'Connect Last.fm to see your profile.',
        actionLabel: 'Connect',
        onAction: () => context.go('/welcome'),
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
                Button(
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
                trailing: Button(
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

class _WaveMixLabPageState
    extends ConsumerState<WaveMixLabPage> {
  int _total = 32;

  @override
  Widget build(BuildContext context) {
    final mix = ref.watch(_waveMixProvider(_total));
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
                'COLLECT',
                style: WaveType.overline.copyWith(
                  color: waveAccent(context),
                ),
              ),
              const Text(
                'Mix Lab',
                style: WaveType.pageTitle,
              ),
              const SizedBox(height: 2),
              Text(
                'A fresh $_total-track mix from your taste.',
                style: WaveType.body.copyWith(
                  color: waveTextSecondary(context),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final t in [24, 32, 40])
                    ToggleButton(
                      checked: _total == t,
                      onChanged: (_) =>
                          setState(() => _total = t),
                      child: Text('$t'),
                    ),
                  WavePrimaryButton(
                    label: 'Regenerate',
                    icon: FluentIcons.refresh,
                    onPressed: () => ref.invalidate(
                      _waveMixProvider(_total),
                    ),
                  ),
                  if ((mix.valueOrNull ?? []).isNotEmpty)
                    WaveGhostButton(
                      label: 'Play mix',
                      icon: FluentIcons.play,
                      onPressed: () {
                        final tracks =
                            mix.valueOrNull ?? [];
                        if (tracks.isEmpty) return;
                        playGenerated(
                          ref,
                          context,
                          tracks.first,
                          sourceLabel: 'Mix Lab',
                          queueAll: tracks,
                        );
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              mix.when(
                loading: () => const WaveLoading(
                  label: 'Generating mix…',
                ),
                error: (e, _) => WaveError(
                  title: 'Mix failed',
                  message: '$e',
                  onRetry: () => ref.invalidate(
                    _waveMixProvider(_total),
                  ),
                ),
                data: (tracks) {
                  if (tracks.isEmpty) {
                    return const WaveEmpty(
                      icon: FluentIcons.lightbulb,
                      title: 'No mix yet',
                      subtitle:
                          'Generate a mix to hear your taste distilled.',
                    );
                  }
                  final playingKey = ref.watch(
                    playbackServiceProvider.select(
                      (s) => s.current?.queueKey,
                    ),
                  );
                  return Column(
                    children: [
                      const WaveTrackTableHeader(
                        showAlbum: false,
                      ),
                      for (var i = 0;
                          i < tracks.length;
                          i++)
                        WaveTrackRow(
                          index: i + 1,
                          title: tracks[i].name,
                          artist: tracks[i].artist,
                          artworkUrl:
                              tracks[i].artworkUrl,
                          videoId: tracks[i].videoId,
                          playing: playingKey ==
                              tracks[i].key,
                          isCurrent: playingKey ==
                              tracks[i].key,
                          onTap: () => playGenerated(
                            ref,
                            context,
                            tracks[i],
                            sourceLabel: 'Mix Lab',
                            queueAll: tracks,
                            startIndex: i,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}
