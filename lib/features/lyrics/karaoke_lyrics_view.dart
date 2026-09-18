import 'dart:math' as math;
import 'dart:ui';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_lyric/flutter_lyric.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/audio/stream_models.dart';
import '../../core/storage/prefs.dart';
import '../../ui/components/buttons.dart' show LWTooltip;
import '../../ui/components/states.dart';
import '../../ui/lyrics/lyrics_panel.dart';
import '../../ui/theme/haze.dart';
import '../../ui/theme/tokens.dart';
import '../../ui/theme/wave_icons.dart';
import '../player/playback_service.dart';
import 'flutter_lyric_adapter.dart';
import 'lyrics_models.dart';

/// Provider for track-specific lyrics timing offset in milliseconds.
final lyricsOffsetProvider = StateNotifierProvider.family<LyricsOffsetNotifier, int, String>(
  (ref, trackKey) {
    final prefs = ref.watch(prefsProvider);
    return LyricsOffsetNotifier(prefs, trackKey);
  },
);

class LyricsOffsetNotifier extends StateNotifier<int> {
  final Prefs _prefs;
  final String _trackKey;

  LyricsOffsetNotifier(this._prefs, this._trackKey)
      : super(_prefs.getLyricsOffset(_trackKey));

  void adjust(int deltaMs) {
    final next = state + deltaMs;
    state = next;
    _prefs.setLyricsOffset(_trackKey, next);
  }

  void reset() {
    state = 0;
    _prefs.resetLyricsOffset(_trackKey);
  }

  void setOffset(int offsetMs) {
    state = offsetMs;
    _prefs.setLyricsOffset(_trackKey, offsetMs);
  }
}

/// Provider for transliteration display toggle.
final lyricsTransliterationProvider =
    StateNotifierProvider<LyricsTransliterationNotifier, bool>((ref) {
  final prefs = ref.watch(prefsProvider);
  return LyricsTransliterationNotifier(prefs);
});

class LyricsTransliterationNotifier extends StateNotifier<bool> {
  final Prefs _prefs;

  LyricsTransliterationNotifier(this._prefs)
      : super(_prefs.lyricsTransliteration);

  void toggle() {
    state = !state;
    _prefs.setLyricsTransliteration(state);
  }
}

/// Format offset in ms to display string (e.g. "+0.5s", "-1.0s", "0.0s").
String formatOffsetDisplay(int offsetMs) {
  if (offsetMs == 0) return '0.0s';
  final sign = offsetMs > 0 ? '+' : '-';
  final secs = (offsetMs.abs() / 1000.0).toStringAsFixed(1);
  return '$sign${secs}s';
}

/// Apple Music Karaoke-Style Lyrics Engine.
///
/// Features:
/// - Progressive syllable color wipe for word-synced lyrics.
/// - Inactive lines rendered with reduced opacity and soft blur (`ImageFilter.blur`).
/// - Active line pops with 1.025x scale and prominent Segoe UI typography.
/// - Timing offset controls: `[-] 0.0s [+] [Reset]` (persisted per track).
/// - Transliteration / Romaji toggle.
/// - Smooth auto-scrolling with manual scroll detection and "Return to current" pill.
/// - Interactive tap-to-seek on any lyric line.
class WaveKaraokeLyricsView extends ConsumerStatefulWidget {
  final PlayableTrack track;
  final bool compact;
  final bool showHeaderControls;
  final VoidCallback? onClose;
  final double? fontSize;
  final bool fillRemainingSpace;

  const WaveKaraokeLyricsView({
    super.key,
    required this.track,
    this.compact = false,
    this.showHeaderControls = true,
    this.onClose,
    this.fontSize,
    this.fillRemainingSpace = true,
  });

  @override
  ConsumerState<WaveKaraokeLyricsView> createState() =>
      _WaveKaraokeLyricsViewState();
}

class _WaveKaraokeLyricsViewState extends ConsumerState<WaveKaraokeLyricsView>
    with SingleTickerProviderStateMixin {
  late final LyricController _lyricController;
  bool _following = true;
  late final Ticker _ticker;
  final ValueNotifier<int> _interpolatedPositionMs = ValueNotifier<int>(0);
  int _lastAudioMs = 0;
  DateTime _lastSyncTime = DateTime.now();
  bool _isPlaying = false;
  double _speed = 1.0;
  int _offsetMs = 0;
  String? _currentTrackKey;
  LyricsResult? _currentResult;
  bool _lastTransliteration = true;
  bool _lastWordByWord = true;

  @override
  void initState() {
    super.initState();
    _lyricController = LyricController();
    _lyricController.setOnTapLineCallback((duration) {
      final seekTargetMs = duration.inMilliseconds + _offsetMs;
      ref.read(playbackServiceProvider.notifier).seek(
            Duration(milliseconds: math.max(0, seekTargetMs)),
          );
      _lyricController.stopSelection();
      if (!_following) {
        setState(() => _following = true);
      }
    });

    _lyricController.isSelectingNotifier.addListener(_onSelectingChanged);
    _ticker = createTicker(_onTick);
  }

  void _onSelectingChanged() {
    final selecting = _lyricController.isSelectingNotifier.value;
    if (selecting && _following) {
      setState(() => _following = false);
    } else if (!selecting && !_following) {
      setState(() => _following = true);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _interpolatedPositionMs.dispose();
    _lyricController.isSelectingNotifier.removeListener(_onSelectingChanged);
    _lyricController.dispose();
    super.dispose();
  }

  void _onTick(Duration _) {
    if (!_isPlaying) return;
    final elapsed = DateTime.now().difference(_lastSyncTime).inMilliseconds;
    final currentMs =
        _lastAudioMs + (elapsed * _speed).round() - _offsetMs;
    _interpolatedPositionMs.value = currentMs;
    _lyricController.setProgress(Duration(milliseconds: math.max(0, currentMs)));
  }

  @override
  Widget build(BuildContext context) {
    final position = ref.watch(
      playbackServiceProvider.select((s) => s.position),
    );
    final isPlaying = ref.watch(
      playbackServiceProvider.select((s) => s.isPlaying),
    );
    final speed = ref.watch(
      playbackServiceProvider.select((s) => s.speed),
    );
    final offsetMs = ref.watch(lyricsOffsetProvider(widget.track.queueKey));
    final showTransliteration = ref.watch(lyricsTransliterationProvider);
    final wordByWord = ref.watch(prefsProvider).wordByWord;
    final async = ref.watch(waveLyricsProvider(widget.track.queueKey));

    _isPlaying = isPlaying;
    _speed = speed <= 0 ? 1.0 : speed;
    _offsetMs = offsetMs;
    final audioMs = position.inMilliseconds;
    if (!_isPlaying) {
      _lastAudioMs = audioMs;
      _lastSyncTime = DateTime.now();
      final effectiveMs = audioMs - offsetMs;
      _interpolatedPositionMs.value = effectiveMs;
      _lyricController.setProgress(Duration(milliseconds: math.max(0, effectiveMs)));
    } else if (audioMs != _lastAudioMs) {
      final elapsed = DateTime.now().difference(_lastSyncTime).inMilliseconds;
      final predicted = _lastAudioMs + (elapsed * _speed).round();
      final drift = audioMs - predicted;
      if (drift <= -450 || drift >= 250) {
        _lastAudioMs = audioMs;
        _lastSyncTime = DateTime.now();
        final effectiveMs = audioMs - offsetMs;
        _interpolatedPositionMs.value = effectiveMs;
        _lyricController.setProgress(
            Duration(milliseconds: math.max(0, effectiveMs)));
      }
    }

    if (_isPlaying && !_ticker.isActive) {
      _ticker.start();
    } else if (!_isPlaying && _ticker.isActive) {
      _ticker.stop();
    }

    return async.when(
      loading: () => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 200),
        child: const WaveLoading(label: 'Finding lyrics…'),
      ),
      error: (e, _) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 200),
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
            subtitle: 'Try another track or check back later.',
            actionLabel: 'Try again',
            onAction: () =>
                ref.invalidate(waveLyricsProvider(widget.track.queueKey)),
          );
        }
        if (!result.isSynced && result.lines.length < 2) {
          return _KaraokePlainLyrics(
            text: result.plainLyrics,
            compact: widget.compact,
            showHeaderControls: widget.showHeaderControls,
            onClose: widget.onClose,
          );
        }

        final isRtl = result.lines.any((l) => l.isRtl);

        if (_currentTrackKey != widget.track.queueKey ||
            _currentResult != result ||
            _lastTransliteration != showTransliteration ||
            _lastWordByWord != wordByWord) {
          _currentTrackKey = widget.track.queueKey;
          _currentResult = result;
          _lastTransliteration = showTransliteration;
          _lastWordByWord = wordByWord;
          if (wordByWord) {
            final model = convertToFlutterLyricModel(
              result,
              showTransliteration: showTransliteration,
              wordByWord: true,
            );
            _lyricController.loadLyricModel(model);
            final effectiveMs = _interpolatedPositionMs.value;
            _lyricController.setProgress(
                Duration(milliseconds: math.max(0, effectiveMs)));
          }
        }

        final style = buildAppleMusicLyricStyle(
          context,
          compact: widget.compact,
          fontSize: widget.fontSize,
          isDark: waveIsDark(context),
          isRtl: isRtl,
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showHeaderControls)
              _KaraokeToolbar(
                track: widget.track,
                result: result,
                offsetMs: offsetMs,
                showTransliteration: showTransliteration,
                following: _following,
                compact: widget.compact,
                wordByWord: wordByWord,
                onClose: widget.onClose,
                onToggleFollowing: () {
                  if (!_following) {
                    _lyricController.stopSelection();
                    setState(() => _following = true);
                  } else {
                    setState(() => _following = false);
                  }
                },
              ),
            Expanded(
              child: wordByWord && result.isSynced
                  ? Stack(
                      children: [
                        Positioned.fill(
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: LyricView(
                              controller: _lyricController,
                              style: style,
                            ),
                          ),
                        ),
                        if (!_following)
                          Positioned(
                            right: 16,
                            bottom: 16,
                            child: _ReturnToCurrentPill(
                              onTap: () {
                                _lyricController.stopSelection();
                                setState(() => _following = true);
                              },
                            ),
                          ),
                      ],
                    )
                  : _AppleLineLyricsView(
                      result: result,
                      positionListenable: _interpolatedPositionMs,
                      compact: widget.compact,
                      fontSize: widget.fontSize,
                      showTransliteration: showTransliteration,
                      following: _following,
                      onUserScroll: () {
                        if (_following) setState(() => _following = false);
                      },
                      onResume: () {
                        _lyricController.stopSelection();
                        setState(() => _following = true);
                      },
                      onSeekLineMs: (lineMs) {
                        final seekTargetMs = lineMs + _offsetMs;
                        ref.read(playbackServiceProvider.notifier).seek(
                              Duration(
                                  milliseconds: math.max(0, seekTargetMs)),
                            );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class KaraokeWordGroup {
  final List<LyricSyllable> syllables;
  final bool hasTrailingSpace;

  const KaraokeWordGroup({
    required this.syllables,
    this.hasTrailingSpace = true,
  });
}

List<KaraokeWordGroup> groupSyllablesIntoWords(
  List<LyricSyllable> syllables,
  String lineText,
) {
  final words = <KaraokeWordGroup>[];
  var currentWordSyllables = <LyricSyllable>[];

  for (var i = 0; i < syllables.length; i++) {
    final syl = syllables[i];
    currentWordSyllables.add(syl);

    var isWordEnd = false;
    if (syl.text.endsWith(' ')) {
      isWordEnd = true;
    } else if (i == syllables.length - 1) {
      isWordEnd = true;
    } else {
      final nextSyl = syllables[i + 1];
      if (nextSyl.text.startsWith(' ')) {
        isWordEnd = true;
      } else {
        final combined = '${syl.text}${nextSyl.text}';
        if (!lineText.contains(combined)) {
          isWordEnd = true;
        }
      }
    }

    if (isWordEnd) {
      words.add(KaraokeWordGroup(
        syllables: currentWordSyllables,
        hasTrailingSpace: i < syllables.length - 1,
      ));
      currentWordSyllables = [];
    }
  }

  if (currentWordSyllables.isNotEmpty) {
    words.add(KaraokeWordGroup(
      syllables: currentWordSyllables,
      hasTrailingSpace: false,
    ));
  }
  return words;
}

double calculateSyllableProgress(LyricSyllable syl, int posMs) {
  final startMs = syl.timeMs;
  final durMs = math.max(1, syl.durationMs);
  final endMs = startMs + durMs;
  if (posMs <= startMs) return 0.0;
  if (posMs >= endMs) return 1.0;
  return (posMs - startMs) / durMs;
}

/// Single Lyric Line rendering with Apple Music Karaoke progressive wipe,
/// blur falloff, and Segoe UI typography.
class WaveKaraokeLyricLine extends StatefulWidget {
  final LyricLine line;
  final int positionMs;
  final ValueListenable<int>? positionListenable;
  final bool isActive;
  final bool isPast;
  final bool compact;
  final bool showTransliteration;
  final double? fontSize;
  final bool karaoke;
  final bool softenIdle;

  const WaveKaraokeLyricLine({
    super.key,
    required this.line,
    required this.positionMs,
    this.positionListenable,
    required this.isActive,
    required this.isPast,
    this.compact = false,
    this.showTransliteration = true,
    this.fontSize,
    this.karaoke = true,
    this.softenIdle = true,
  });

  @override
  State<WaveKaraokeLyricLine> createState() => _WaveKaraokeLyricLineState();
}

class _WaveKaraokeLyricLineState extends State<WaveKaraokeLyricLine> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    final baseFontSize = widget.fontSize ?? (widget.compact ? 28.0 : 36.0);

    final activeTextColor = dark ? const Color(0xFFF6F4EF) : const Color(0xFF18181B);
    final idleTextColor = (dark ? const Color(0xFFF6F4EF) : const Color(0xFF18181B))
        .withValues(
          alpha: widget.softenIdle ? (widget.isPast ? 0.38 : 0.44) : 0.92,
        );

    final activeStyle = TextStyle(
      fontSize: baseFontSize,
      fontWeight: FontWeight.w700,
      color: activeTextColor,
      height: 1.42,
      letterSpacing: -0.3,
      shadows: widget.isActive
          ? [
              Shadow(
                color: activeTextColor.withValues(alpha: dark ? 0.28 : 0.14),
                blurRadius: 16,
                offset: const Offset(0, 1),
              ),
            ]
          : null,
    );

    // Style for unsung words on the ACTIVE line: identical font metrics to prevent character jitter!
    final activeUnsungStyle = TextStyle(
      fontSize: baseFontSize,
      fontWeight: FontWeight.w700,
      color: activeTextColor.withValues(alpha: 0.38),
      height: 1.42,
      letterSpacing: -0.3,
    );

    final idleStyle = TextStyle(
      fontSize: baseFontSize,
      fontWeight: FontWeight.w600,
      color: _isHovered
          ? (dark ? Colors.white : Colors.black).withValues(alpha: 0.88)
          : idleTextColor,
      height: 1.42,
      letterSpacing: -0.3,
    );

    Widget content;

    final useKaraokeWipe = widget.karaoke && widget.isActive;
    final effectiveSyllables = useKaraokeWipe
        ? (widget.line.hasSyllables
            ? widget.line.syllables
            : interpolateLineSyllables(
                text: widget.line.text,
                startTimeMs: widget.line.timeMs,
                durationMs: widget.line.durationMs,
              ))
        : const <LyricSyllable>[];

    if (effectiveSyllables.isNotEmpty) {
      final words =
          groupSyllablesIntoWords(effectiveSyllables, widget.line.text);

      Widget buildSyllableWrap(int posMs) {
        return Wrap(
          textDirection:
              widget.line.isRtl ? TextDirection.rtl : TextDirection.ltr,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final word in words)
              Row(
                mainAxisSize: MainAxisSize.min,
                textDirection:
                    widget.line.isRtl ? TextDirection.rtl : TextDirection.ltr,
                children: [
                  for (final syl in word.syllables)
                    _KaraokeSyllableWidget(
                      text: syl.text.trimRight(),
                      progress: calculateSyllableProgress(syl, posMs),
                      activeStyle: activeStyle,
                      idleStyle: activeUnsungStyle,
                      highlightColor: accent,
                      isRtl: widget.line.isRtl,
                    ),
                  if (word.hasTrailingSpace) Text(' ', style: activeUnsungStyle),
                ],
              ),
          ],
        );
      }

      if (widget.positionListenable != null) {
        content = ValueListenableBuilder<int>(
          valueListenable: widget.positionListenable!,
          builder: (context, posMs, _) => buildSyllableWrap(posMs),
        );
      } else {
        content = buildSyllableWrap(widget.positionMs);
      }
    } else {
      // Standard line-timed or idle line
      content = Text(
        widget.line.text,
        style: widget.isActive ? activeStyle : idleStyle,
        textDirection: widget.line.isRtl ? TextDirection.rtl : TextDirection.ltr,
        softWrap: true,
        overflow: TextOverflow.visible,
      );
    }

    final showBlur =
        widget.softenIdle && !widget.isActive && !_isHovered && !reduceMotion;

    Widget body = AnimatedDefaultTextStyle(
      duration: WaveMotion.fast,
      style: widget.isActive ? activeStyle : idleStyle,
      child: Column(
        crossAxisAlignment:
            widget.line.isRtl ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          content,
          if (widget.showTransliteration && widget.line.transliteration.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                widget.line.transliteration,
                style: TextStyle(
                  fontSize: baseFontSize * 0.52,
                  fontStyle: FontStyle.italic,
                  color: (dark ? Colors.white : Colors.black).withValues(
                    alpha: widget.isActive ? 0.72 : 0.40,
                  ),
                ),
                textDirection:
                    widget.line.isRtl ? TextDirection.rtl : TextDirection.ltr,
              ),
            ),
        ],
      ),
    );

    if (showBlur) {
      body = ImageFiltered(
        imageFilter: ImageFilter.blur(
          sigmaX: widget.karaoke ? 1.15 : 1.8,
          sigmaY: widget.karaoke ? 1.15 : 1.8,
        ),
        child: Opacity(
          opacity: widget.karaoke ? 0.88 : 0.92,
          child: body,
        ),
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: WaveMotion.normal,
        curve: Curves.easeOutCubic,
        transform: Matrix4.diagonal3Values(
          widget.isActive ? 1.025 : 1.0,
          widget.isActive ? 1.025 : 1.0,
          1.0,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: widget.compact ? 8 : 12,
          vertical: widget.karaoke ? 4 : 8,
        ),
        decoration: BoxDecoration(
          color: _isHovered && !widget.isActive
              ? (dark ? Colors.white : Colors.black).withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: body,
      ),
    );
  }
}

/// Progressive fill / wipe for an individual syllable with soft anti-aliased edge.
class _KaraokeSyllableWidget extends StatelessWidget {
  final String text;
  final double progress;
  final TextStyle activeStyle;
  final TextStyle idleStyle;
  final Color highlightColor;
  final bool isRtl;

  const _KaraokeSyllableWidget({
    required this.text,
    required this.progress,
    required this.activeStyle,
    required this.idleStyle,
    required this.highlightColor,
    this.isRtl = false,
  });

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    if (progress <= 0.0) {
      return Text(text, style: idleStyle);
    }
    if (progress >= 1.0) {
      return Text(text, style: activeStyle);
    }

    final activeColor = activeStyle.color ?? Colors.white;
    final idleColor = idleStyle.color ?? const Color(0x61FFFFFF);

    const feather = 0.035;
    final stop1 = (progress - feather).clamp(0.0, 1.0);
    final stop2 = (progress + feather).clamp(0.0, 1.0);

    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) {
        return LinearGradient(
          begin: isRtl ? Alignment.centerRight : Alignment.centerLeft,
          end: isRtl ? Alignment.centerLeft : Alignment.centerRight,
          colors: [
            activeColor,
            activeColor,
            idleColor,
            idleColor,
          ],
          stops: [0.0, stop1, stop2, 1.0],
        ).createShader(bounds);
      },
      child: Text(text, style: activeStyle),
    );
  }
}



/// Top toolbar with timing controls, transliteration toggle, and close button.
class _KaraokeToolbar extends ConsumerWidget {
  final PlayableTrack track;
  final LyricsResult result;
  final int offsetMs;
  final bool showTransliteration;
  final bool following;
  final bool compact;
  final bool wordByWord;
  final VoidCallback? onClose;
  final VoidCallback onToggleFollowing;

  const _KaraokeToolbar({
    required this.track,
    required this.result,
    required this.offsetMs,
    required this.showTransliteration,
    required this.following,
    required this.compact,
    this.wordByWord = true,
    this.onClose,
    required this.onToggleFollowing,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final offsetNotifier =
        ref.read(lyricsOffsetProvider(track.queueKey).notifier);
    final transliterationNotifier =
        ref.read(lyricsTransliterationProvider.notifier);

    final offsetDisplay = formatOffsetDisplay(offsetMs);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 28,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border(
          bottom: BorderSide(
            color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.06),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              wordByWord
                  ? (result.isWordSynced
                      ? 'Karaoke · Syllable Synced'
                      : result.isSynced
                          ? 'Synced Lyrics'
                          : result.source.isNotEmpty
                              ? result.source
                              : 'Lyrics')
                  : result.isSynced
                      ? 'Apple Music · Line Synced'
                      : result.source.isNotEmpty
                          ? result.source
                          : 'Lyrics',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WaveType.meta.copyWith(
                fontWeight: FontWeight.w600,
                color: waveTextSecondary(context),
              ),
            ),
          ),
          // Timing Offset Controls: [-] offset [+] [Reset]
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(WaveRadius.controls),
              border: Border.all(color: waveDivider(context)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                LWTooltip(
                  message: 'Lyrics earlier (-0.5s)',
                  child: _MiniIconButton(
                    icon: FluentIcons.remove,
                    onTap: () => offsetNotifier.adjust(-500),
                  ),
                ),
                LWTooltip(
                  message: 'Timing offset for this track',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      offsetDisplay,
                      style: WaveType.meta.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                        color: offsetMs != 0
                            ? accent
                            : waveTextSecondary(context),
                      ),
                    ),
                  ),
                ),
                LWTooltip(
                  message: 'Lyrics later (+0.5s)',
                  child: _MiniIconButton(
                    icon: FluentIcons.add,
                    onTap: () => offsetNotifier.adjust(500),
                  ),
                ),
                if (offsetMs != 0)
                  LWTooltip(
                    message: 'Reset offset to 0.0s',
                    child: _MiniIconButton(
                      icon: FluentIcons.reset,
                      onTap: offsetNotifier.reset,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Transliteration / Romaji Toggle
          LWTooltip(
            message: showTransliteration
                ? 'Transliteration enabled'
                : 'Enable transliteration',
            child: _MiniIconButton(
              icon: FluentIcons.globe,
              active: showTransliteration,
              onTap: transliterationNotifier.toggle,
            ),
          ),
          const SizedBox(width: 4),
          LWTooltip(
            message: following
                ? 'Pause automatic scrolling'
                : 'Return to the line being sung',
            child: _MiniIconButton(
              icon: following ? FluentIcons.pin : FluentIcons.unpin,
              active: following,
              onTap: onToggleFollowing,
            ),
          ),
          if (onClose != null) ...[
            const SizedBox(width: 6),
            LWTooltip(
              message: 'Close panel',
              child: _MiniIconButton(
                icon: WaveIcons.close,
                onTap: onClose!,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MiniIconButton extends StatefulWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _MiniIconButton({
    required this.icon,
    this.active = false,
    required this.onTap,
  });

  @override
  State<_MiniIconButton> createState() => _MiniIconButtonState();
}

class _MiniIconButtonState extends State<_MiniIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final color = widget.active
        ? accent
        : _hover
            ? (dark ? WaveColors.textPrimary : WaveColors.lightTextPrimary)
            : (dark ? WaveColors.textSecondary : WaveColors.lightTextSecondary);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: _hover
                ? (dark ? Colors.white : Colors.black).withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Center(
            child: Icon(widget.icon, size: 13, color: color),
          ),
        ),
      ),
    );
  }
}

/// Floating "Return to current" pill when manual scrolling is engaged.
class _ReturnToCurrentPill extends StatelessWidget {
  final VoidCallback onTap;
  const _ReturnToCurrentPill({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);

    return WaveHaze(
      level: LwHazeLevel.l2,
      base: (dark ? WaveColors.surfaceRaised : WaveColors.lightSurfaceRaised)
          .withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: waveDivider(context)),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(FluentIcons.down, size: 12, color: accent),
                const SizedBox(width: 6),
                Text(
                  'Return to current',
                  style: WaveType.label.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Apple Music default lyrics: the whole current line is sharp and
/// fully lit. Past and upcoming lines stay dim with a slight blur.
class _AppleLineLyricsView extends StatefulWidget {
  final LyricsResult result;
  final ValueNotifier<int> positionListenable;
  final bool compact;
  final double? fontSize;
  final bool showTransliteration;
  final bool following;
  final VoidCallback onUserScroll;
  final VoidCallback onResume;
  final ValueChanged<int> onSeekLineMs;

  const _AppleLineLyricsView({
    required this.result,
    required this.positionListenable,
    required this.compact,
    required this.fontSize,
    required this.showTransliteration,
    required this.following,
    required this.onUserScroll,
    required this.onResume,
    required this.onSeekLineMs,
  });

  @override
  State<_AppleLineLyricsView> createState() => _AppleLineLyricsViewState();
}

class _AppleLineLyricsViewState extends State<_AppleLineLyricsView> {
  final ItemScrollController _scroll = ItemScrollController();
  int _lastIndex = -1;
  bool _pinnedOpening = false;

  int _activeIndex(int posMs) =>
      activeLyricLineIndex(widget.result.lines, posMs);

  void _scrollTo(int index, {bool animate = true}) {
    if (!_scroll.isAttached) return;
    if (index < 0) index = 0;
    final alignment = lyricFollowAlignment(
      index,
      compact: widget.compact,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.isAttached || !mounted) return;
      if (animate) {
        _scroll.scrollTo(
          index: index,
          alignment: alignment,
          duration: WaveMotion.normal,
          curve: Curves.easeOutCubic,
        );
      } else {
        _scroll.jumpTo(index: index, alignment: alignment);
      }
    });
  }

  void _pinOpeningToTop() {
    if (_pinnedOpening || !_scroll.isAttached) return;
    _pinnedOpening = true;
    _scrollTo(0, animate: false);
  }

  @override
  void didUpdateWidget(covariant _AppleLineLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result != widget.result) {
      _pinnedOpening = false;
      _lastIndex = -1;
    }
    if (widget.following && !oldWidget.following) {
      final untimed = lyricsAreUntimed(widget.result.lines);
      _scrollTo(
        untimed ? 0 : _activeIndex(widget.positionListenable.value),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final untimed = lyricsAreUntimed(widget.result.lines);
    if (untimed) {
      // Do not rebuild on the playback clock — that remounts the list
      // and hides every line past the first screen.
      return _buildLineList(posMs: 0, active: -1, untimed: true);
    }

    return ValueListenableBuilder<int>(
      valueListenable: widget.positionListenable,
      builder: (context, posMs, _) {
        final active = _activeIndex(posMs);
        if (widget.following && _scroll.isAttached) {
          if (active <= 0 || posMs < 400) {
            _pinOpeningToTop();
            _lastIndex = active;
          } else if (active != _lastIndex) {
            final wasUninitialized = _lastIndex < 0;
            _lastIndex = active;
            _scrollTo(
              active,
              animate: !wasUninitialized && active > 0,
            );
          }
        } else if (!widget.following) {
          _lastIndex = active;
        }

        return _buildLineList(
          posMs: posMs,
          active: active,
          untimed: false,
        );
      },
    );
  }

  Widget _buildLineList({
    required int posMs,
    required int active,
    required bool untimed,
  }) {
    Widget lineAt(int i) {
      final line = widget.result.lines[i];
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => widget.onSeekLineMs(line.timeMs),
            child: WaveKaraokeLyricLine(
              line: line,
              positionMs: posMs,
              isActive: i == active,
              isPast: !untimed && i < active,
              compact: widget.compact,
              fontSize: widget.fontSize,
              showTransliteration: widget.showTransliteration,
              karaoke: false,
              softenIdle: !untimed,
            ),
          ),
        ),
      );
    }

    final padding = EdgeInsets.fromLTRB(
      widget.compact ? 12 : 28,
      24,
      widget.compact ? 12 : 28,
      80,
    );

    final list = untimed
        ? ListView.builder(
            physics: const ClampingScrollPhysics(),
            padding: padding,
            itemCount: widget.result.lines.length,
            itemBuilder: (context, i) => lineAt(i),
          )
        : NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n is ScrollStartNotification && n.dragDetails != null) {
                widget.onUserScroll();
              }
              return false;
            },
            child: ScrollablePositionedList.builder(
              itemScrollController: _scroll,
              initialScrollIndex: 0,
              initialAlignment: 0,
              itemCount: widget.result.lines.length,
              padding: padding,
              itemBuilder: (context, i) => lineAt(i),
            ),
          );

    return Stack(
      children: [
        list,
        if (!untimed && !widget.following)
          Positioned(
            right: 16,
            bottom: 16,
            child: _ReturnToCurrentPill(onTap: widget.onResume),
          ),
      ],
    );
  }
}

class _KaraokePlainLyrics extends StatelessWidget {
  final String text;
  final bool compact;
  final bool showHeaderControls;
  final VoidCallback? onClose;

  const _KaraokePlainLyrics({
    required this.text,
    this.compact = false,
    this.showHeaderControls = true,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeaderControls)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 12 : 24,
              vertical: 8,
            ),
            child: Row(
              children: [
                Text(
                  'PLAIN LYRICS',
                  style: WaveType.overline.copyWith(
                    fontSize: 9.5,
                    color: waveAccent(context),
                  ),
                ),
                const Spacer(),
                if (onClose != null)
                  _MiniIconButton(
                    icon: WaveIcons.close,
                    onTap: onClose!,
                  ),
              ],
            ),
          ),
        Expanded(
          child: ListView(
            physics: const ClampingScrollPhysics(),
            padding: EdgeInsets.all(compact ? 14 : 28),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: WaveDensity.lyricMax,
                  ),
                  child: SelectableText(
                    text,
                    style: WaveType.body.copyWith(
                      height: 1.75,
                      fontSize: compact ? 18 : 22,
                      color: dark
                          ? WaveColors.textPrimary
                          : WaveColors.lightTextPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
