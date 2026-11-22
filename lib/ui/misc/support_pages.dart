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
import '../../features/lastfm/lastfm_snapshot.dart';
import '../../features/home/home_snapshot.dart';
import '../../core/storage/prefs.dart';
import '../../features/player/playback_service.dart';
import '../components/artwork.dart';
import '../components/buttons.dart';
import '../components/states.dart';
import 'friends_page.dart' show localFriendsProvider;
import '../components/track_row.dart';
import '../theme/tokens.dart';

export 'friends_page.dart' show WaveFriendsPage;

/// Secondary pages re-homed in the Fluent system.
///
/// These routes remain functional but are no longer separate visual
/// languages: each uses the same hero + table / card patterns as the
/// primary collections. Logic is reused through existing providers.
/// Top tracks query: friend view (or self) + Last.fm period.
typedef _TopQuery = ({String? viewing, String period});

final _profileStatsProvider =
    FutureProvider.autoDispose.family<HomeStats, String?>((ref, viewing) {
  final home = ref.watch(homeRepositoryProvider);
  return swrLoad<HomeStats>(
    ref,
    key: lastFmCacheKey('stats', ref.read(prefsProvider).username,
        viewing: viewing),
    codec: homeStatsSnapshotCodec,
    group: cacheGroupLastFm,
    maxAge: lastFmCacheMaxAge,
    everyBuild: true,
    fetch: () => home.fetchStats(viewingAs: viewing),
  );
});

final _waveTopTracksProvider =
    FutureProvider.family<List<HomeTrack>, _TopQuery>(
        (ref, q) {
  final home = ref.watch(homeRepositoryProvider);
  return swrLoad<List<HomeTrack>>(
    ref,
    key: lastFmCacheKey('top', ref.read(prefsProvider).username,
        viewing: q.viewing, extra: q.period),
    codec: homeTracksSnapshotCodec,
    group: cacheGroupLastFm,
    maxAge: lastFmCacheMaxAge,
    fetch: () => home.fetchTopTracks(
      viewingAs: q.viewing,
      period: q.period,
      limit: 100,
    ),
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
      padding: waveDockPadding(context, const EdgeInsets.fromLTRB(24, 20, 24, 24)),
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
              Builder(builder: (context) {
                final stats =
                    ref.watch(_profileStatsProvider(viewing)).valueOrNull;
                final isFriend = viewing != null &&
                    ref.watch(localFriendsProvider).any(
                          (n) => n.toLowerCase() == viewing.toLowerCase(),
                        );
                String n(int v) => v.toString().replaceAllMapped(
                      RegExp(r'\B(?=(\d{3})+(?!\d))'),
                      (m) => ',',
                    );
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    WaveArtwork.circle(
                      url: stats?.avatarUrl ?? '',
                      size: 88,
                      label: user,
                      title: user,
                      artist: user,
                      upgrade: false,
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(user, style: WaveType.pageTitle),
                          const SizedBox(height: 4),
                          Text(
                            viewing != null
                                ? 'Last.fm profile'
                                : 'Your Last.fm profile',
                            style: WaveType.body.copyWith(
                              color: waveTextSecondary(context),
                            ),
                          ),
                          if (stats != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              [
                                '${n(stats.scrobbles)} scrobbles',
                                '${n(stats.artistCount)} artists',
                                '${n(stats.albumCount)} albums',
                                '${n(stats.trackCount)} tracks',
                              ].join(' · '),
                              style: WaveType.meta.copyWith(
                                color: waveTextTertiary(context),
                              ),
                            ),
                          ],
                          if (viewing != null) ...[
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (isFriend)
                                  WaveGhostButton(
                                    label: 'Remove friend',
                                    onPressed: () => ref
                                        .read(localFriendsProvider.notifier)
                                        .remove(viewing),
                                  )
                                else
                                  WavePrimaryButton(
                                    label: 'Add friend',
                                    icon: FluentIcons.add,
                                    onPressed: () => ref
                                        .read(localFriendsProvider.notifier)
                                        .add(viewing),
                                  ),
                                WaveButton(
                                  onPressed: () => ref
                                      .read(viewingProfileProvider.notifier)
                                      .clear(),
                                  child: const Text('Back to my profile'),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                );
              }),
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
