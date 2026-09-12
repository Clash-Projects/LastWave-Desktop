import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/audio/stream_models.dart';
import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
import '../player/playback_service.dart';
import 'lyrics_models.dart';
import 'lyrics_repository.dart';

final _lyricsForTrackProvider = FutureProvider.autoDispose
    .family<LyricsResult, String>((ref, key) async {
  final player = ref.watch(playbackServiceProvider);
  final current = player.current;
  if (current == null || current.queueKey != key) {
    return const LyricsResult.empty();
  }
  final repo = ref.watch(lyricsRepositoryProvider);
  return repo.getLyrics(
    title: current.title,
    artist: current.artist,
    album: current.album,
    durationSeconds:
        player.duration.inSeconds > 0 ? player.duration.inSeconds : null,
  );
});

/// Shared lyrics column: synced auto-scroll, word-by-word highlight,
/// RTL support. Used by the lyrics screen and the queue side panel.
class LyricsColumn extends ConsumerStatefulWidget {
  final PlayableTrack track;
  final bool autoScroll;
  const LyricsColumn({
    super.key,
    required this.track,
    this.autoScroll = true,
  });

  @override
  ConsumerState<LyricsColumn> createState() => _LyricsColumnState();
}

class _LyricsColumnState extends ConsumerState<LyricsColumn> {
  final ItemScrollController _scroll = ItemScrollController();
  int _lastIndex = -1;

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playbackServiceProvider);
    final async = ref.watch(
        _lyricsForTrackProvider(widget.track.queueKey));
    return async.when(
      loading: () => const SkeletonRow(count: 8),
      error: (e, _) => EmptyState(
        icon: Icons.lyrics_outlined,
        title: 'Lyrics unavailable',
        subtitle: e.toString(),
      ),
      data: (result) {
        if (result.isInstrumental) {
          return const EmptyState(
            icon: Icons.music_note_outlined,
            title: 'Instrumental',
            subtitle: 'No lyrics for this track.',
          );
        }
        if (result.isEmpty) {
          return const EmptyState(
            icon: Icons.lyrics_outlined,
            title: 'No lyrics found',
            subtitle:
                'Try another track or check back later.',
          );
        }
        if (!result.isSynced) {
          return ListView(
            padding:
                const EdgeInsets.all(LwSpacing.lg),
            children: [
              Text(result.plainLyrics,
                  style: LwType.body.copyWith(height: 1.8)),
            ],
          );
        }
        final posMs = player.position.inMilliseconds;
        var active = 0;
        for (var i = 0; i < result.lines.length; i++) {
          if (result.lines[i].timeMs <= posMs) {
            active = i;
          } else {
            break;
          }
        }
        if (widget.autoScroll &&
            active != _lastIndex &&
            _scroll.isAttached) {
          _lastIndex = active;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_scroll.isAttached) return;
            _scroll.scrollTo(
              index: active,
              alignment: 0.35,
              duration: LwMotion.slow,
              curve: LwMotion.emphasized,
            );
          });
        }
        return ScrollablePositionedList.builder(
          itemScrollController: _scroll,
          itemCount: result.lines.length,
          padding: const EdgeInsets.symmetric(
              vertical: LwSpacing.xl,
              horizontal: LwSpacing.lg),
          itemBuilder: (context, i) {
            final line = result.lines[i];
            final isActive = i == active;
            final isPast = i < active;
            return Padding(
              padding: const EdgeInsets.symmetric(
                  vertical: 7),
              child: _LyricLineText(
                line: line,
                positionMs: posMs,
                highlighted: isActive,
                dimmed: isPast,
              ),
            );
          },
        );
      },
    );
  }
}

class _LyricLineText extends StatelessWidget {
  final LyricLine line;
  final int positionMs;
  final bool highlighted;
  final bool dimmed;
  const _LyricLineText({
    required this.line,
    required this.positionMs,
    required this.highlighted,
    required this.dimmed,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final baseStyle = LwType.headline.copyWith(
      fontSize: highlighted ? 19 : 16,
      fontWeight:
          highlighted ? FontWeight.w700 : FontWeight.w500,
      color: highlighted
          ? LwColors.textPrimary
          : dimmed
              ? LwColors.textTertiary.withValues(alpha: 0.6)
              : LwColors.textSecondary,
      height: 1.5,
    );
    Widget text;
    if (line.hasSyllables && (highlighted || dimmed)) {
      final spans = <TextSpan>[];
      for (final syl in line.syllables) {
        final sung = positionMs >= syl.timeMs;
        spans.add(TextSpan(
          text: syl.text,
          style: TextStyle(
            color: sung
                ? accent
                : baseStyle.color,
          ),
        ));
        spans.add(const TextSpan(text: ' '));
      }
      text = Text.rich(
        TextSpan(children: spans, style: baseStyle),
        textDirection:
            line.isRtl ? TextDirection.rtl : TextDirection.ltr,
      );
    } else {
      text = Text(
        line.text,
        style: baseStyle,
        textDirection:
            line.isRtl ? TextDirection.rtl : TextDirection.ltr,
      );
    }
    return AnimatedContainer(
      duration: LwMotion.normal,
      curve: LwMotion.standard,
      child: text,
    );
  }
}
