import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/track_actions.dart' show playGenerated;
import '../../features/feed/feed_repository.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/innertube/yt_library_providers.dart';
import '../components/buttons.dart' show WavePlayPill;
import '../components/shelf.dart';
import '../components/states.dart';
import '../navigation/wave_nav.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Where a YouTube Music entity card leads — album, artist, playlist, mix.
///
/// Home's shelf rail and [WaveYtShelfPage] share this, so a card cannot mean
/// two different things on the two surfaces.
void openYtEntity(BuildContext context, YouTubeMusicEntity e) {
  final id = e.browseId.isNotEmpty ? e.browseId : e.playlistId;
  if (id.isEmpty) return;
  switch (e.kind) {
    case YouTubeEntityKind.artist:
      waveOpen(context, '/artist/${Uri.encodeComponent(e.name)}');
    case YouTubeEntityKind.album:
      // Albums are MPRE ids; anything else here is a misclassified playlist
      // id (recap-style cards) and belongs on the playlist page instead of a
      // dead Empty album.
      if (id.startsWith('MPRE')) {
        waveOpen(
            context,
            waveAlbumLocation(
              browseId: id,
              title: e.name,
              artist: e.artist.isNotEmpty ? e.artist : e.subtitle,
              artworkUrl: e.artworkUrl,
            ));
      } else {
        waveOpen(context, '/ytplaylist/${Uri.encodeComponent(id)}');
      }
    case YouTubeEntityKind.playlist:
    case YouTubeEntityKind.mix:
      waveOpen(context, '/ytplaylist/${Uri.encodeComponent(id)}');
  }
}

/// The whole of one YouTube Music home shelf.
///
/// Home keeps its rails to ten items so the feed stays a summary; this is the
/// other end of the "See all" on those headers, and the only place the shelf's
/// full length is on screen with Play all beside it. Tracks queue from
/// whichever card you press; entity shelves open the way their cards do on
/// Home.
class WaveYtShelfPage extends ConsumerWidget {
  final String title;
  const WaveYtShelfPage({super.key, required this.title});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shelves = ref.watch(ytHomeShelvesProvider);
    YtHomeShelf? match;
    for (final s in shelves.valueOrNull ?? const <YtHomeShelf>[]) {
      if (s.title == title) {
        match = s;
        break;
      }
    }
    if (match == null) {
      if (shelves.isLoading) return const WaveLoading();
      return WaveEmpty(
        icon: WaveIcons.playlists,
        title: 'Shelf not available',
        subtitle: 'YouTube Music did not return "$title" this time. '
            'Open it again from Home.',
      );
    }
    final shelf = match;

    final tracks = <GeneratedTrack>[
      if (shelf.isTrackShelf)
        for (final t in shelf.tracks) _track(t)
      else if (shelf.isTrackCardShelf)
        for (final t in shelf.trackCards) _track(t),
    ];
    final cards = <Widget>[
      if (tracks.isNotEmpty)
        for (var i = 0; i < tracks.length; i++)
          _card(
            title: tracks[i].name,
            subtitle: tracks[i].artist,
            artworkUrl: tracks[i].artworkUrl,
            artist: tracks[i].artist,
            videoId: tracks[i].videoId,
            onTap: () => playGenerated(
              ref,
              context,
              tracks[i],
              sourceLabel: shelf.title,
              queueAll: tracks,
              startIndex: i,
            ),
          )
      else
        for (final e in shelf.entities)
          _card(
            title: e.name,
            subtitle: e.subtitle,
            artworkUrl: e.artworkUrl,
            onTap: () => openYtEntity(context, e),
          ),
    ];

    final count = tracks.isNotEmpty
        ? '${tracks.length} songs'
        : '${shelf.entities.length} items';

    return WaveEntranceGroup(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 22, 28, 16),
              child: WaveEntrance(
                rise: 10,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'YOUTUBE MUSIC',
                            style: WaveType.overline.copyWith(
                              fontSize: 10,
                              color: waveTextTertiary(context),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            shelf.title,
                            style:
                                WaveType.pageTitle.copyWith(fontSize: 26),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            count,
                            style: WaveType.meta
                                .copyWith(color: waveTextSecondary(context)),
                          ),
                        ],
                      ),
                    ),
                    if (tracks.isNotEmpty)
                      WavePlayPill(
                        label: 'Play all',
                        onTap: () => playGenerated(
                          ref,
                          context,
                          tracks.first,
                          sourceLabel: shelf.title,
                          queueAll: tracks,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
            sliver: SliverToBoxAdapter(
              child: Wrap(
                spacing: 12,
                runSpacing: 16,
                children: [
                  for (var i = 0; i < cards.length; i++)
                    WaveEntrance(index: i, rise: 8, child: cards[i]),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static GeneratedTrack _track(YouTubeMusicTrack t) => GeneratedTrack(
        name: t.title,
        artist: t.artist,
        album: t.album,
        artworkUrl: t.artworkUrl,
        videoId: t.videoId,
        durationSeconds: t.durationSeconds,
      );

  static Widget _card({
    required String title,
    required String subtitle,
    required String artworkUrl,
    required VoidCallback onTap,
    String artist = '',
    String videoId = '',
  }) =>
      SizedBox(
        width: 160,
        child: WaveMediaCard(
          title: title,
          subtitle: subtitle,
          titleFallback: title,
          artworkUrl: artworkUrl,
          artist: artist,
          videoId: videoId,
          onTap: onTap,
        ),
      );
}
