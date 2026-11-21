import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/spotify/spotify_api.dart';
import '../components/shelf.dart' show WaveMediaCard, WaveRail;
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
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(section.title, style: WaveType.sectionTitle),
                  const SizedBox(height: 10),
                  WaveRail(
                    height: 216,
                    itemCount: section.items.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, j) {
                      final item = section.items[j];
                      return SizedBox(
                        width: 160,
                        child: WaveMediaCard(
                          title: item.name,
                          subtitle: item.subtitle,
                          titleFallback: item.name,
                          artworkUrl: item.artworkUrl,
                          onTap: () => _open(context, item),
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
