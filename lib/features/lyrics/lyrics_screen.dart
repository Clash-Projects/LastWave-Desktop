import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../design_system/icons.dart';

import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
import '../player/playback_service.dart';
import 'lyrics_view.dart';

/// Full-screen lyrics: artwork rail + large synced lines.
class LyricsScreen extends ConsumerWidget {
  const LyricsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current =
        ref.watch(playbackServiceProvider).current;
    if (current == null) {
      return const EmptyState(
        icon: LwIcons.mic,
        title: 'Nothing playing',
        subtitle:
            'Play a track to see synced lyrics here.',
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 300,
          padding:
              const EdgeInsets.all(LwSpacing.xl),
          decoration: const BoxDecoration(
            border: Border(
                right: BorderSide(
                    color: LwColors.outlineSoft)),
          ),
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Artwork(
                  url: current.artworkUrl,
                  size: 236,
                  radius: LwRadius.lg),
              const SizedBox(height: LwSpacing.md),
              Text(current.title,
                  style: LwType.headline,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
              Text(current.artist,
                  style: LwType.body.copyWith(
                      color: LwColors.textSecondary)),
              const SizedBox(height: 4),
              const Text(
                'Synced lyrics follow playback automatically.',
                style: LwType.caption,
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(maxWidth: 760),
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
