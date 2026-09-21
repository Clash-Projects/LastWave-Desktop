import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/audio/stream_models.dart';
import '../../design_system/components.dart';
import '../../design_system/icons.dart';
import '../../design_system/tokens.dart';
import '../../ui/components/skeletons.dart';
import '../../ui/components/states.dart';
import '../player/playback_service.dart';
import 'lyrics_models.dart';
import 'lyrics_repository.dart';

final _lyricsForTrackProvider = FutureProvider.autoDispose
    .family<LyricsResult, String>((ref, key) async {
  // Fetch keyed by track identity only — never by playback position.
  final player = ref.watch(playbackServiceProvider.select(
      (s) => (current: s.current, duration: s.duration)));
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

/// Editorial lyrics ledger: typography is the visual. Readable 640px
/// column, active-line + sung-word emphasis, tap-to-seek, follow toggle,
/// return-to-current.
///
/// States: word-timed · line-timed · plain · instrumental · loading ·
/// unavailable. Used by LyricsScreen (full) and QueuePanel (compact).
class LyricsColumn extends ConsumerStatefulWidget {
  final PlayableTrack track;
  final bool autoScroll;
  final bool compact;
  const LyricsColumn({
    super.key,
    required this.track,
    this.autoScroll = true,
    this.compact = false,
  });

  @override
  ConsumerState<LyricsColumn> createState() =>
      _LyricsColumnState();
}

class _LyricsColumnState extends ConsumerState<LyricsColumn> {
  final ItemScrollController _scroll = ItemScrollController();
  final ItemPositionsListener _positions =
      ItemPositionsListener.create();
  late bool _following;
  int _lastIndex = -1;

  @override
  void initState() {
    super.initState();
    _following = widget.autoScroll;
  }

  int _activeIndex(LyricsResult result, int posMs) =>
      activeLyricLineIndex(result.lines, posMs);

  void _scrollTo(int lineIndex, {bool animate = true}) {
    if (!_scroll.isAttached) return;
    // Item 0 is the source header; lyrics start at 1.
    final itemIndex = lineIndex < 0 ? 0 : lineIndex + 1;
    final alignment = lyricFollowAlignment(
      lineIndex,
      compact: widget.compact,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.isAttached || !mounted) return;
      if (animate) {
        _scroll.scrollTo(
          index: itemIndex,
          alignment: alignment,
          duration: LwMotion.slow,
          curve: LwMotion.emphasized,
        );
      } else {
        _scroll.jumpTo(index: itemIndex, alignment: alignment);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = Theme.of(context).colorScheme.primary;
    final position = ref.watch(
        playbackServiceProvider.select((s) => s.position));
    final async = ref.watch(
        _lyricsForTrackProvider(widget.track.queueKey));
    return async.when(
      loading: () => const SkeletonRow(count: 8),
      error: (e, _) => WaveEmpty(
        icon: LucideIcons.micVocal,
        title: 'Lyrics unavailable',
        subtitle: e.toString(),
      ),
      data: (result) {
        if (result.isInstrumental) {
          return const WaveEmpty(
            icon: Icons.music_note_outlined,
            title: 'Instrumental',
            subtitle: 'No lyrics for this track.',
          );
        }
        if (result.isEmpty) {
          return const WaveEmpty(
            icon: Icons.lyrics_outlined,
            title: 'No lyrics found',
            subtitle:
                'Try another track or check back later.',
          );
        }
        if (!result.isSynced) {
          return _PlainBody(
              text: result.plainLyrics,
              compact: widget.compact);
        }
        final posMs = position.inMilliseconds;
        final active = _activeIndex(result, posMs);
        if (_following &&
            active != _lastIndex &&
            _scroll.isAttached) {
          final wasUninitialized = _lastIndex < 0;
          _lastIndex = active;
          _scrollTo(
            active,
            animate: !wasUninitialized && active > 0,
          );
        } else if (!_following) {
          _lastIndex = active;
        } else if (_lastIndex == -1) {
          _lastIndex = active;
        }

        final maxW = widget.compact
            ? double.infinity
            : LwDensity.lyricMax;
        return Stack(
          children: [
            NotificationListener<
                ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollStartNotification &&
                    n.dragDetails != null) {
                  if (_following) {
                    setState(
                        () => _following = false);
                  }
                }
                return false;
              },
              child: ScrollablePositionedList.builder(
                itemScrollController: _scroll,
                itemPositionsListener: _positions,
                initialScrollIndex: 0,
                initialAlignment: 0,
                itemCount: result.lines.length + 1,
                padding: EdgeInsets.symmetric(
                    vertical: widget.compact
                        ? LwSpacing.md
                        : LwSpacing.xl,
                    horizontal: widget.compact
                        ? LwSpacing.sm
                        : LwSpacing.lg),
                itemBuilder: (context, i) {
                  if (i == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(
                          bottom: LwSpacing.sm),
                      child: Row(
                        children: [
                          EdKicker(result
                                  .isWordSynced
                              ? 'Word-timed'
                              : 'Line-timed'),
                          const SizedBox(width: 6),
                          Text('· ${result.source}',
                              style: LwType.caption.copyWith(
                                  color: dark
                                      ? LwColors
                                          .textTertiary
                                      : LwColors
                                          .lightTextTertiary)),
                          const Spacer(),
                          _FollowToggle(
                            following: _following,
                            onChanged: (v) {
                              setState(() =>
                                  _following = v);
                              if (v) {
                                _scrollTo(active);
                              }
                            },
                          ),
                        ],
                      ),
                    );
                  }
                  final li = i - 1;
                  final line = result.lines[li];
                  final isActive = li == active;
                  final isPast = li < active;
                  return Padding(
                    padding:
                        const EdgeInsets.symmetric(
                            vertical: 7),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                            maxWidth: maxW),
                        child: GestureDetector(
                          onTap: () => ref
                              .read(
                                  playbackServiceProvider
                                      .notifier)
                              .seek(Duration(
                                  milliseconds:
                                      line.timeMs)),
                          child: _LyricLineText(
                            line: line,
                            positionMs: posMs,
                            highlighted: isActive,
                            dimmed: isPast,
                            compact: widget.compact,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (!_following)
              Positioned(
                right: 12,
                bottom: 12,
                child: Material(
                  color: dark
                      ? LwColors.surfaceRaised
                      : LwColors.lightSurface,
                  shape: const StadiumBorder(),
                  elevation: 4,
                  child: InkWell(
                    onTap: () {
                      setState(
                          () => _following = true);
                      _scrollTo(active);
                    },
                    customBorder:
                        const StadiumBorder(),
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                              LucideIcons
                                  .arrowDownToLine,
                              size: 13,
                              color: accent),
                          const SizedBox(width: 6),
                          Text('Return to current',
                              style: LwType.label
                                  .copyWith(
                                      fontSize: 11.5)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _FollowToggle extends StatelessWidget {
  final bool following;
  final ValueChanged<bool> onChanged;
  const _FollowToggle(
      {required this.following, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () => onChanged(!following),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            following
                ? LucideIcons.locateFixed
                : LucideIcons.locate,
            size: 13,
            color: following
                ? Theme.of(context)
                    .colorScheme
                    .primary
                : (dark
                    ? LwColors.textTertiary
                    : LwColors.lightTextTertiary),
          ),
          const SizedBox(width: 4),
          Text(following ? 'Following' : 'Free scroll',
              style: LwType.caption.copyWith(
                  fontSize: 11.5,
                  color: dark
                      ? LwColors.textTertiary
                      : LwColors.lightTextTertiary)),
        ],
      ),
    );
  }
}

class _PlainBody extends StatelessWidget {
  final String text;
  final bool compact;
  const _PlainBody(
      {required this.text, this.compact = false});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ListView(
      padding: EdgeInsets.all(
          compact ? LwSpacing.sm : LwSpacing.lg),
      children: [
        const EdKicker('Plain lyrics'),
        const SizedBox(height: LwSpacing.xs),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
                maxWidth: LwDensity.lyricMax),
            child: Text(text,
                style: LwType.body.copyWith(
                    height: 1.85,
                    fontSize: compact ? 13 : 14,
                    color: dark
                        ? LwColors.textPrimary
                        : LwColors
                            .lightTextPrimary)),
          ),
        ),
      ],
    );
  }
}

class _LyricLineText extends StatelessWidget {
  final LyricLine line;
  final int positionMs;
  final bool highlighted;
  final bool dimmed;
  final bool compact;
  const _LyricLineText({
    required this.line,
    required this.positionMs,
    required this.highlighted,
    required this.dimmed,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final baseStyle = (highlighted
            ? LwType.lyricActive
            : LwType.lyricIdle)
        .copyWith(
      fontSize: compact
          ? (highlighted ? 17 : 14.5)
          : (highlighted ? 21 : 17),
      color: highlighted
          ? (dark
              ? LwColors.textPrimary
              : LwColors.lightTextPrimary)
          : dimmed
              ? (dark
                      ? LwColors.textTertiary
                      : LwColors.lightTextTertiary)
                  .withValues(alpha: 0.65)
              : (dark
                  ? LwColors.textSecondary
                  : LwColors.lightTextSecondary),
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
            backgroundColor: (highlighted && sung)
                ? accent.withValues(alpha: 0.08)
                : Colors.transparent,
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
      padding: highlighted
          ? const EdgeInsets.only(left: 10)
          : EdgeInsets.zero,
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: highlighted
                ? accent
                : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: text,
    );
  }
}
