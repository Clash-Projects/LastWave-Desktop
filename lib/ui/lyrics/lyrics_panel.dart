import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/audio/stream_models.dart';
import '../../features/lyrics/lyrics_models.dart';
import '../../features/lyrics/lyrics_repository.dart';
import '../../features/player/playback_service.dart';
import '../components/buttons.dart' show LWTooltip;
import '../components/states.dart';
import '../theme/tokens.dart';

// Lyrics fetch is keyed by track identity — never by the playback clock
// or duration (duration arrives late and would refetch). Position ticks
// only drive the highlight index.
final waveLyricsProvider = StreamProvider.autoDispose
    .family<LyricsResult, String>((ref, key) {
  final current = ref.watch(
      playbackServiceProvider.select((s) => s.current));
  if (current == null || current.queueKey != key) {
    return Stream.value(const LyricsResult.empty());
  }
  final repo = ref.watch(lyricsRepositoryProvider);
  // Duration read once (no watch) so late duration arrival doesn't refetch.
  final durationSecs =
      ref.read(playbackServiceProvider).duration.inSeconds;
  final results = StreamController<LyricsResult>();
  var disposed = false;
  ref.onDispose(() {
    disposed = true;
    unawaited(results.close());
  });
  unawaited(repo.getLyrics(
    title: current.title,
    artist: current.artist,
    album: current.album,
    durationSeconds: durationSecs > 0 ? durationSecs : null,
    onPartialResult: (result) {
      if (!disposed) results.add(result);
    },
  ).then((result) {
    if (!disposed) results.add(result);
  }, onError: (Object error, StackTrace stack) {
    if (!disposed) results.addError(error, stack);
  }).whenComplete(() {
    if (!disposed) unawaited(results.close());
  }));
  return results.stream;
});

/// Premium lyrics reading experience.
///
/// - Centered readable column (560px max, 640 in full page).
/// - Large active line, muted surroundings.
/// - Word-level highlight where syllable timestamps exist, line-level
///   otherwise. No fake timing.
/// - Auto-scroll with manual-scroll override + Return-to-current.
/// - Click a timed line to seek. Translated/transliterated lines shown
///   where available.
/// - Clear states: loading / plain / instrumental / unavailable / error.
class WaveLyricsPanel extends ConsumerStatefulWidget {
  final PlayableTrack track;
  final bool compact;
  const WaveLyricsPanel({
    super.key,
    required this.track,
    this.compact = false,
  });

  @override
  ConsumerState<WaveLyricsPanel> createState() =>
      _WaveLyricsPanelState();
}

class _WaveLyricsPanelState
    extends ConsumerState<WaveLyricsPanel> {
  final ItemScrollController _scroll = ItemScrollController();
  bool _following = true;
  int _lastIndex = -1;

  int _activeIndex(LyricsResult result, int posMs) {
    var active = -1;
    for (var i = 0; i < result.lines.length; i++) {
      if (result.lines[i].timeMs <= posMs) {
        active = i;
      } else {
        break;
      }
    }
    return active;
  }

  void _scrollTo(int index) {
    final trackKey = widget.track.queueKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.isAttached || !_following ||
          widget.track.queueKey != trackKey) {
        return;
      }
      _scroll.scrollTo(
        index: index < 0 ? 0 : index,
        alignment: index < 0 ? 0 : 0.32,
        duration: WaveMotion.slow,
        curve: Curves.easeInOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    // Highlight subscription is isolated: only position ticks rebuild
    // this panel, never the shell or lists.
    final position = ref.watch(
      playbackServiceProvider.select((s) => s.position),
    );
    final async =
        ref.watch(waveLyricsProvider(widget.track.queueKey));
    return async.when(
      loading: () => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 180),
        child: const WaveLoading(label: 'Finding lyrics…'),
      ),
      error: (e, _) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 180),
        child: WaveError(
          title: 'Lyrics unavailable',
          message: 'Check your connection and try again.',
          onRetry: () =>
              ref.invalidate(waveLyricsProvider(widget.track.queueKey)),
        ),
      ),
      data: (result) {
        if (result.isInstrumental) {
          return const WaveEmpty(
            icon: FluentIcons.music_note,
            title: 'Instrumental',
            subtitle: 'No lyrics for this track.',
          );
        }
        if (result.isEmpty) {
          return WaveEmpty(
            icon: FluentIcons.microphone,
            title: 'No lyrics found',
            subtitle:
                'Try another track or check back later.',
            actionLabel: 'Try again',
            onAction: () => ref.invalidate(waveLyricsProvider(widget.track.queueKey)),
          );
        }
        if (!result.isSynced) {
          return _PlainLyrics(
            text: result.plainLyrics,
            compact: widget.compact,
          );
        }
        final posMs = position.inMilliseconds;
        final active = _activeIndex(result, posMs);
        if (_following && active != _lastIndex) {
          _scrollTo(active);
        }
        _lastIndex = active;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: widget.compact ? 12 : 24,
                vertical: 8,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${result.isWordSynced ? 'Word synced' : 'Synced lyrics'}'
                      '${result.source.isEmpty ? '' : ' · ${result.source}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.meta.copyWith(
                        color: waveTextSecondary(context),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  LWTooltip(
                    message: _following
                        ? 'Pause automatic scrolling'
                        : 'Return to the line being sung',
                    child: HyperlinkButton(
                      onPressed: () {
                        setState(() => _following = !_following);
                        if (_following) _scrollTo(active);
                      },
                      child: Text(_following ? 'Following' : 'Resume lyrics'),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(builder: (context, constraints) {
                final gutter = widget.compact ? 12.0 : 24.0;
                return NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (_following &&
                        ((notification is UserScrollNotification &&
                            notification.direction != ScrollDirection.idle) ||
                         (notification is ScrollStartNotification &&
                            notification.dragDetails != null))) {
                      setState(() => _following = false);
                    }
                    return false;
                  },
                  child: ScrollablePositionedList.builder(
                    initialScrollIndex: active < 0 ? 0 : active,
                    initialAlignment: active < 0 ? 0 : 0.32,
                    itemScrollController: _scroll,
                    itemCount: result.lines.length,
                    padding: EdgeInsets.fromLTRB(
                      gutter, 20, gutter, constraints.maxHeight * 0.65,
                    ),
                    itemBuilder: (context, index) {
                      final line = result.lines[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Align(
                          alignment: Alignment.center,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: WaveDensity.lyricMax,
                            ),
                            child: SizedBox(
                              width: double.infinity,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    ref.read(playbackServiceProvider.notifier)
                                        .seek(Duration(milliseconds: line.timeMs));
                                    setState(() => _following = true);
                                    _scrollTo(index);
                                  },
                                  child: _LyricLine(
                                    line: line,
                                    positionMs: posMs,
                                    highlighted: index == active,
                                    dimmed: index < active,
                                    compact: widget.compact,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              }),
            ),
          ],
        );
      },
    );
  }
}

class _PlainLyrics extends StatelessWidget {
  final String text;
  final bool compact;
  const _PlainLyrics({
    required this.text,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return ListView(
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.all(compact ? 12 : 24),
      children: [
        Text(
          'PLAIN LYRICS',
          style: WaveType.overline.copyWith(
            fontSize: 9.5,
            color: waveAccent(context),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: WaveDensity.lyricMax,
            ),
            child: SelectableText(
              text,
              style: WaveType.body.copyWith(
                height: 1.7,
                fontSize: compact ? 16 : 20,
                color: dark
                    ? WaveColors.textPrimary
                    : WaveColors.lightTextPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LyricLine extends StatelessWidget {
  final LyricLine line;
  final int positionMs;
  final bool highlighted;
  final bool dimmed;
  final bool compact;
  const _LyricLine({
    required this.line,
    required this.positionMs,
    required this.highlighted,
    required this.dimmed,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = waveAccent(context);
    final dark = waveIsDark(context);
    final baseStyle = (highlighted
            ? WaveType.lyricActive
            : WaveType.lyricIdle)
        .copyWith(
      fontSize: compact ? 19 : 26,
      height: 1.5,
      color: highlighted
          ? (dark
              ? WaveColors.textPrimary
              : WaveColors.lightTextPrimary)
          : dimmed
              ? (dark
                      ? WaveColors.textTertiary
                      : WaveColors.lightTextTertiary)
                  .withValues(alpha: 0.9)
              : (dark
                  ? WaveColors.textSecondary
                  : WaveColors.lightTextSecondary),
    );
    Widget text;
    if (line.hasSyllables && highlighted) {
      final spans = <TextSpan>[];
      for (final syl in line.syllables) {
        final sung = positionMs >= syl.timeMs;
        spans.add(
          TextSpan(
            text: syl.text,
            style: TextStyle(
              color: sung ? accent : baseStyle.color,
              backgroundColor: (highlighted && sung)
                  ? accent.withValues(alpha: 0.12)
                  : const Color(0x00000000),
            ),
          ),
        );
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
      duration: WaveMotion.normal,
      // Fixed gutter always reserved (transparent when inactive) so the
      // active line never shifts layout when highlight moves.
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color:
                highlighted ? accent : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          text,
          if (line.transliteration.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                line.transliteration,
                style: WaveType.meta.copyWith(
                  fontSize: 12,
                  color: dark
                      ? WaveColors.textTertiary
                      : WaveColors.lightTextTertiary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
