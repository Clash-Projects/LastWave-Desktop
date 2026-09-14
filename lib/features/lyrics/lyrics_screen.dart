import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design_system/components.dart';
import '../../design_system/icons.dart';
import '../../design_system/tokens.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import '../player/playback_service.dart';
import 'lyrics_view.dart';

/// Editorial lyrics screen: ledger masthead + typographic reader.
/// Replaces 300px rail + centered column split with a unified reading
/// ledger (56 art + title ledger left, reader below).
class LyricsScreen extends ConsumerWidget {
  const LyricsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current =
        ref.watch(playbackServiceProvider.select((s) => s.current));
    if (current == null) {
      return const EmptyState(
        icon: LucideIcons.mic,
        title: 'Nothing playing',
        subtitle:
            'Play a track to see synced lyrics here.',
      );
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              LwSpacing.xl, LwSpacing.lg, LwSpacing.xl, 0),
          child: EdPage(
            child: Row(
              children: [
                Artwork(
                    url: current.artworkUrl,
                    size: 56,
                    radius: LwRadius.md),
                const SizedBox(width: LwSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const EdKicker('Lyrics'),
                      Text(current.title,
                          maxLines: 1,
                          overflow:
                              TextOverflow.ellipsis,
                          style: LwType.headline),
                      Text(current.artist,
                          maxLines: 1,
                          overflow:
                              TextOverflow.ellipsis,
                          style: LwType.body.copyWith(
                              color: dark
                                  ? LwColors.textSecondary
                                  : LwColors
                                      .lightTextSecondary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: LwSpacing.xs),
        const Padding(
          padding: EdgeInsets.symmetric(
              horizontal: LwSpacing.xl),
          child: EdPage(
            child: LwSeparator.horizontal(),
          ),
        ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                  maxWidth: LwDensity.contentMax),
              child: LyricsColumn(
                key: ValueKey(current.queueKey),
                track: current,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
