import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/track_actions.dart' show playGenerated;
import '../../features/feed/feed_repository.dart' show GeneratedTrack;
import '../../features/innertube/innertube_api.dart' show innertubeProvider;
import '../../features/player/playback_service.dart';
import '../../features/spotify/spotify_api.dart';
import '../components/menus.dart';
import '../components/shelf.dart';
import '../components/states.dart';
import '../navigation/wave_nav.dart';
import '../theme/tokens.dart';

/// Home when Spotify is the recommendation source: Spotify's own Home
/// sections, kept apart from the YouTube Music / Last.fm feed (never
/// blended). A sliver, dropped into the Home scroll view.
class SpotifyHomeSlivers extends ConsumerWidget {
  final double side;
  final Widget loading;
  const SpotifyHomeSlivers({
    super.key,
    required this.side,
    required this.loading,
  });

  void _open(BuildContext context, SpotifyHomeItem item) {
    if (item.kind == 'playlist') {
      waveOpen(
        context,
        '/spotifyplaylist/${Uri.encodeComponent(item.id)}'
        '?title=${Uri.encodeComponent(item.name)}'
        '&art=${Uri.encodeComponent(item.artworkUrl)}',
      );
      return;
    }
    // Albums and artists play through the app's own catalogue.
    final q = item.kind == 'album' && item.subtitle.isNotEmpty
        ? '${item.name} ${item.subtitle}'
        : item.name;
    context.go('/search?q=${Uri.encodeComponent(q)}');
  }

  Future<void> _play(
    BuildContext context,
    WidgetRef ref,
    SpotifyHomeItem item,
  ) async {
    if (item.kind == 'playlist') {
      final content = await ref.read(spotifyApiProvider).playlist(item.id);
      if (content != null && content.tracks.isNotEmpty && context.mounted) {
        final gen = [
          for (final t in content.tracks)
            GeneratedTrack(
              name: t.name,
              artist: t.artist,
              album: t.album,
              artworkUrl: t.artworkUrl,
              durationSeconds: t.durationSeconds,
            ),
        ];
        await playGenerated(
          ref,
          context,
          gen.first,
          sourceLabel: item.name,
          queueAll: gen,
        );
      }
      return;
    }
    // Albums and artists play through the app's own catalogue.
    final q = item.kind == 'album' && item.subtitle.isNotEmpty
        ? '${item.name} ${item.subtitle}'
        : item.name;
    final match = await ref
        .read(innertubeProvider)
        .findBestMatchOrNull(item.name, item.subtitle);
    if (match != null && context.mounted) {
      await playGenerated(
        ref,
        context,
        GeneratedTrack(
          name: match.title,
          artist: match.artist,
          album: item.name,
          artworkUrl:
              match.artworkUrl.isNotEmpty ? match.artworkUrl : item.artworkUrl,
          videoId: match.videoId,
          durationSeconds: match.durationSeconds,
        ),
        sourceLabel: item.name,
      );
    } else if (context.mounted) {
      context.go('/search?q=${Uri.encodeComponent(q)}');
    }
  }

  List<WaveMenuItem> _cardMenuItems(
    BuildContext context,
    WidgetRef ref,
    SpotifyHomeItem item,
  ) {
    return [
      WaveMenuAction(
        leading: const Icon(FluentIcons.play, size: 15),
        label: 'Play',
        onPressed: () => _play(context, ref, item),
      ),
      if (item.kind == 'playlist') ...[
        WaveMenuAction(
          leading: const Icon(FluentIcons.add, size: 15),
          label: 'Play next',
          onPressed: () async {
            final content =
                await ref.read(spotifyApiProvider).playlist(item.id);
            if (content != null && content.tracks.isNotEmpty) {
              final playable = [
                for (final t in content.tracks)
                  PlayableTrack(
                    title: t.name,
                    artist: t.artist,
                    album: t.album,
                    artworkUrl: t.artworkUrl,
                    duration: Duration(seconds: t.durationSeconds),
                  ),
              ];
              await ref
                  .read(playbackServiceProvider.notifier)
                  .playNextAll(playable);
            }
          },
        ),
        WaveMenuAction(
          leading: const Icon(FluentIcons.list, size: 15),
          label: 'Add to queue',
          onPressed: () async {
            final content =
                await ref.read(spotifyApiProvider).playlist(item.id);
            if (content != null && content.tracks.isNotEmpty) {
              final playable = [
                for (final t in content.tracks)
                  PlayableTrack(
                    title: t.name,
                    artist: t.artist,
                    album: t.album,
                    artworkUrl: t.artworkUrl,
                    duration: Duration(seconds: t.durationSeconds),
                  ),
              ];
              await ref
                  .read(playbackServiceProvider.notifier)
                  .addToQueueAll(playable);
            }
          },
        ),
      ],
      const WaveMenuSeparator(),
      WaveMenuAction(
        leading: const Icon(FluentIcons.open_folder_horizontal, size: 15),
        label: item.kind == 'playlist' ? 'Open playlist' : 'Open',
        onPressed: () => _open(context, item),
      ),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(spotifyHomeProvider);
    final padding = EdgeInsets.fromLTRB(side, 18, side, 32);
    return home.when(
      loading: () => SliverPadding(
        padding: padding,
        sliver: SliverToBoxAdapter(child: loading),
      ),
      error: (e, _) => SliverPadding(
        padding: padding,
        sliver: SliverToBoxAdapter(
          child: WaveError(
            title: 'Could not load Spotify Home',
            message: '$e',
            onRetry: () => ref.invalidate(spotifyHomeProvider),
          ),
        ),
      ),
      data: (sections) {
        if (sections.isEmpty) {
          return SliverPadding(
            padding: padding,
            sliver: SliverToBoxAdapter(
              child: WaveEmpty(
                icon: FluentIcons.music_note,
                title: "Spotify Home didn't load",
                subtitle: 'Spotify sent nothing back. Retry, or sign in to '
                    'Spotify again in Settings.',
                actionLabel: 'Retry',
                onAction: () => ref.invalidate(spotifyHomeProvider),
              ),
            ),
          );
        }
        return SliverPadding(
          padding: padding,
          sliver: SliverList.separated(
            itemCount: sections.length,
            separatorBuilder: (_, _) => const SizedBox(height: 26),
            itemBuilder: (context, i) {
              final section = sections[i];
              final hasPlayable =
                  section.items.any((it) => it.kind == 'playlist');
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LWSectionHeader(
                    title: section.title,
                    count: section.items.length,
                    actionLabel: hasPlayable ? 'Play all' : null,
                    onAction: hasPlayable
                        ? () => _play(
                              context,
                              ref,
                              section.items
                                  .firstWhere((it) => it.kind == 'playlist'),
                            )
                        : null,
                  ),
                  const SizedBox(height: 10),
                  WaveRail(
                    height: 216,
                    itemCount: section.items.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, j) {
                      final item = section.items[j];
                      return SizedBox(
                        width: 160,
                        child: WaveContextMenu(
                          items: () => _cardMenuItems(context, ref, item),
                          child: WaveMediaCard(
                            title: item.name,
                            subtitle: item.subtitle,
                            titleFallback: item.name,
                            artworkUrl: item.artworkUrl,
                            onTap: () => _open(context, item),
                            onPlay: () => _play(context, ref, item),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
