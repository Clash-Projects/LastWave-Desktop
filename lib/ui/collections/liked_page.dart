import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/track_actions.dart'
    show
        formatDuration,
        mergeYtTracks,
        playGenerated,
        playableFromGenerated;
import '../../features/feed/feed_repository.dart';
import '../../features/innertube/yt_library_providers.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../components/buttons.dart';
import '../components/desktop_table.dart';
import '../components/hero.dart';
import '../components/select.dart';
import '../components/states.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Liked Songs: hero + filter + sort + dense table.
class WaveLikedPage extends ConsumerStatefulWidget {
  const WaveLikedPage({super.key});

  @override
  ConsumerState<WaveLikedPage> createState() =>
      _WaveLikedPageState();
}

class _WaveLikedPageState
    extends ConsumerState<WaveLikedPage> {
  final _filter = TextEditingController();
  String _q = '';
  String _sort = 'default';

  List<StoredTrack>? _lastAll;
  List<dynamic>? _lastYtLiked;
  String _lastQ = '';
  String _lastSort = '';
  List<GeneratedTrack>? _cachedMerged;
  int _cachedTotal = 0;
  String _cachedCover = '';

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistRepositoryProvider);
    final liked =
        playlists.where((p) => p.isLikedSongs).firstOrNull;
    final all = liked?.tracks ?? const [];
    final query = _q.trim().toLowerCase();
    final ytLiked =
        ref.watch(ytLikedSongsProvider).value ?? const [];

    final bool tracksChanged = !identical(all, _lastAll) || all != _lastAll;
    final bool ytChanged = !identical(ytLiked, _lastYtLiked) || ytLiked != _lastYtLiked;
    final bool filterChanged = query != _lastQ || _sort != _lastSort;

    if (tracksChanged || ytChanged || _lastAll == null) {
      _lastAll = all;
      _lastYtLiked = ytLiked;
      final allGen = all
          .map(
            (t) => GeneratedTrack(
              name: t.name,
              artist: t.artist,
              artworkUrl: t.artworkUrl,
              videoId: t.videoId,
            ),
          )
          .toList();
      _cachedTotal = mergeYtTracks(allGen, ytLiked).length;
      String cover = '';
      for (final t in all) {
        if (t.artworkUrl.isNotEmpty) {
          cover = t.artworkUrl;
          break;
        }
      }
      _cachedCover = cover;
    }

    if (tracksChanged || ytChanged || filterChanged || _cachedMerged == null) {
      _lastQ = query;
      _lastSort = _sort;
      var tracks = query.isEmpty
          ? List<StoredTrack>.from(all)
          : all
              .where(
                (t) => '${t.name} ${t.artist}'
                    .toLowerCase()
                    .contains(query),
              )
              .toList();
      if (_sort == 'title') {
        tracks.sort((a, b) => a.name.compareTo(b.name));
      } else if (_sort == 'artist') {
        tracks.sort((a, b) => a.artist.compareTo(b.artist));
      }

      final ytFiltered = query.isEmpty
          ? ytLiked
          : ytLiked
              .where(
                (t) => '${t.title} ${t.artist}'
                    .toLowerCase()
                    .contains(query),
              )
              .toList();
      final localGenerated = tracks
          .map(
            (t) => GeneratedTrack(
              name: t.name,
              artist: t.artist,
              artworkUrl: t.artworkUrl,
              videoId: t.videoId,
            ),
          )
          .toList();
      _cachedMerged = mergeYtTracks(localGenerated, ytFiltered);
    }

    final playingKey = ref.watch(
      playbackServiceProvider.select((s) => s.current?.queueKey),
    );
    final mergedGenerated = _cachedMerged!;
    List<GeneratedTrack> asGenerated() => mergedGenerated;
    final cover = _cachedCover;
    final mergedTotal = _cachedTotal;
    // Empty: ONE compact state only — simple text header, no artwork hero
    // plus a second giant icon.
    if (mergedTotal == 0) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: WaveDensity.contentMax,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('PLAYLIST',
                    style: WaveType.overline.copyWith(
                        fontSize: 10,
                        color: waveTextTertiary(context))),
                const SizedBox(height: 4),
                Text('Liked Songs',
                    style: WaveType.pageTitle
                        .copyWith(fontSize: 28)),
                const SizedBox(height: 4),
                Text('0 tracks',
                    style: WaveType.meta.copyWith(
                        color: waveTextTertiary(context))),
                const SizedBox(height: 8),
                const WaveEmpty(
                  icon: FluentIcons.heart,
                  title: 'No liked songs yet',
                  subtitle:
                      'Tap the heart on any track to save it here.',
                ),
              ],
            ),
          ),
        ],
      );
    }
    return WaveEntranceGroup(
      child: CustomScrollView(
        slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding:
                const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: WaveDensity.contentMax,
              ),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  WaveEntrance(
                    rise: 10,
                    child: WaveCollectionHero(
                    overline: 'Playlist',
                    title: 'Liked Songs',
                    meta:
                        '$mergedTotal tracks${_q.isNotEmpty ? ' · ${asGenerated().length} match' : ''}',
                    artworkUrl: cover,
                    fallbackIcon: FluentIcons.heart_fill,
                    primaryActions: [
                      if (asGenerated().isNotEmpty)
                        WavePrimaryButton(
                          label: 'Play all',
                          icon: FluentIcons.play,
                          onPressed: () =>
                              playGenerated(
                            ref,
                            context,
                            asGenerated().first,
                            sourceLabel: 'Liked Songs',
                            queueAll: asGenerated(),
                          ),
                        ),
                      WaveGhostButton(
                        label: 'Shuffle',
                        icon: WaveIcons.shuffle,
                        onPressed: asGenerated().isEmpty
                            ? null
                            : () {
                                // Shuffle BEFORE picking first —
                                // first must come from the shuffled list.
                                final shuffled =
                                    asGenerated()..shuffle();
                                playGenerated(
                                  ref,
                                  context,
                                  shuffled.first,
                                  sourceLabel: 'Liked Songs',
                                  queueAll: shuffled,
                                );
                              },
                      ),
                    ],
                  ),
                  ),
                  const SizedBox(height: 12),
                  WaveFilterBar(
                    controller: _filter,
                    onChanged: (v) =>
                        setState(() => _q = v),
                    hint: 'Filter liked songs…',
                    countLabel:
                        '${asGenerated().length} tracks',
                    sortSlot: LWTooltip(
                      message: 'Sort (also sortable via table headers)',
                      child: WaveSelect<String>(
                        value: _sort,
                        options: const [
                          WaveSelectOption(
                              value: 'default', label: 'Default order'),
                          WaveSelectOption(value: 'title', label: 'Title A–Z'),
                          WaveSelectOption(value: 'artist', label: 'Artist A–Z'),
                        ],
                        onChanged: (v) => setState(() => _sort = v),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
        if (asGenerated().isEmpty)
          const SliverToBoxAdapter(
            child: WaveEmpty(
              icon: FluentIcons.heart,
              title: 'No liked songs yet',
              subtitle:
                  'Tap the heart on any track to save it here.',
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: WaveDesktopTable<GeneratedTrack>(
              items: asGenerated(),
              keyOf: (t) => t.key,
              titleOf: (t) => t.name,
              subtitleOf: (t) => t.artist,
              albumOf: (_) => '',
              artworkOf: (t) => t.artworkUrl,
              playableOf: playableFromGenerated,
              durationOf: (t) => t.durationSeconds > 0
                  ? formatDuration(
                      Duration(seconds: t.durationSeconds))
                  : '',
              durationSortOf: (t) => t.durationSeconds,
              titleSortOf: (t) => t.name.toLowerCase(),
              artistSortOf: (t) => t.artist.toLowerCase(),
              isCurrent: (t) => playingKey == t.key,
              isPlaying: (t) {
                final playing = ref.watch(
                  playbackServiceProvider.select((p) => p.isPlaying),
                );
                return playingKey == t.key && playing;
              },
              showArtistColumn: true,
              sliver: true,
              selectable: true,
              onPlay: (i) => playGenerated(
                ref,
                context,
                asGenerated()[i],
                sourceLabel: 'Liked Songs',
                queueAll: asGenerated(),
                startIndex: i,
              ),
            ),
          ),
        const SliverToBoxAdapter(
          child: SizedBox(height: 24),
        ),
      ],
      ),
    );
  }
}


