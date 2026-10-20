import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_lyric/flutter_lyric.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/audio/stream_models.dart';
import '../../core/error/fatal_crumbs.dart';
import '../../core/storage/prefs.dart';
import '../../ui/components/buttons.dart' show LWTooltip;
import '../../ui/components/menus.dart'
    show WaveMenuAction, WaveMenuButton, WaveMenuSeparator;
import '../../ui/components/states.dart';
import '../../ui/lyrics/lyrics_panel.dart';
import '../../ui/theme/haze.dart';
import '../../ui/theme/tokens.dart';
import '../../ui/theme/wave_icons.dart';
import '../player/playback_service.dart';
import 'lyrics_models.dart';
import 'lyrics_providers.dart';

/// Provider for track-specific lyrics timing offset in milliseconds.
final lyricsOffsetProvider = StateNotifierProvider.family<LyricsOffsetNotifier, int, String>(
  (ref, trackKey) {
    final prefs = ref.read(prefsProvider);
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
  final prefs = ref.read(prefsProvider);
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
  final bool isActive;

  const WaveKaraokeLyricsView({
    super.key,
    required this.track,
    this.compact = false,
    this.showHeaderControls = true,
    this.onClose,
    this.fontSize,
    this.fillRemainingSpace = true,
    this.isActive = true,
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
  final ValueNotifier<int> _activeLineIndex = ValueNotifier<int>(-1);
  // Clock subscriptions owned here (initState/dispose), not watched in
  // build: position/isPlaying/speed tick 10Hz and feed only ticker/drift
  // side effects, never widget output.
  ProviderSubscription<Duration>? _posSub;
  ProviderSubscription<bool>? _playingSub;
  ProviderSubscription<double>? _speedSub;
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
    // Subscribe without rebuilding: each emission only re-syncs the
    // interpolation clock (same math the in-build block used to run).
    _posSub = ref.listenManual(
      playbackServiceProvider.select((s) => s.position),
      (_, _) => _syncPlaybackClock(),
    );
    _playingSub = ref.listenManual(
      playbackServiceProvider.select((s) => s.isPlaying),
      (_, _) => _syncPlaybackClock(),
    );
    _speedSub = ref.listenManual(
      playbackServiceProvider.select((s) => s.speed),
      (_, _) => _syncPlaybackClock(),
    );
    // NOTE: deliberately NOT calling _syncPlaybackClock() here. It reads
    // ModalRoute.of(context) / TickerMode.valuesOf(context) via
    // _isEffectivelyActive — inherited-widget lookups are illegal before
    // initState completes (FlutterError → debugger stop). The initial
    // sync runs in didChangeDependencies below (and again in build).
  }

  void _onSelectingChanged() {
    final selecting = _lyricController.isSelectingNotifier.value;
    if (selecting && _following) {
      setState(() => _following = false);
    } else if (!selecting && !_following) {
      setState(() => _following = true);
    }
  }

  bool get _isEffectivelyActive {
    if (!mounted || !widget.isActive) return false;
    final routeCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    final tickerEnabled = TickerMode.valuesOf(context).enabled;
    return routeCurrent && tickerEnabled;
  }

  int _lastTickMs = 0;

  int _getCurrentPositionMs() {
    if (_ticker.isActive) {
      return _interpolatedPositionMs.value;
    }
    final snap = ref.read(playbackServiceProvider);
    return snap.position.inMilliseconds - _offsetMs;
  }

  bool _shouldTickerRun() {
    if (!_isEffectivelyActive || !_isPlaying) return false;
    final res = _currentResult;
    if (res == null || !res.isSynced || res.lines.isEmpty || res.isInstrumental) {
      return false;
    }
    if (!_lastWordByWord && !res.isWordSynced) {
      return false;
    }
    final pos = _getCurrentPositionMs();
    final firstStart = res.lines.first.timeMs;
    // Before song intro starts:
    if (pos < firstStart - 600) return false;

    // After last line ends:
    final lastLine = res.lines.last;
    final lastEnd = lastLine.timeMs + math.max(lastLine.durationMs, 3000);
    if (pos > lastEnd + 1000) return false;

    // In an instrumental break between lines:
    final activeIdx = _activeLineIndex.value;
    if (activeIdx >= 0 && activeIdx < res.lines.length - 1) {
      final curLine = res.lines[activeIdx];
      final curEnd = curLine.timeMs + math.max(curLine.durationMs, 1000);
      final nextStart = res.lines[activeIdx + 1].timeMs;
      if (nextStart - curEnd > 1800) {
        if (pos > curEnd + 300 && pos < nextStart - 600) {
          return false;
        }
      }
    }
    return true;
  }

  void _updateTickerState() {
    final shouldRun = _shouldTickerRun();
    if (shouldRun && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Inherited lookups (ModalRoute/TickerMode) are only legal from here
    // on, so this is the first place the ticker state can be evaluated.
    _syncPlaybackClock();
  }

  @override
  void didUpdateWidget(WaveKaraokeLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) {
      _updateTickerState();
    }
  }

  @override
  void dispose() {
    _posSub?.close();
    _playingSub?.close();
    _speedSub?.close();
    _ticker.dispose();
    _interpolatedPositionMs.dispose();
    _activeLineIndex.dispose();
    _lyricController.isSelectingNotifier.removeListener(_onSelectingChanged);
    _lyricController.dispose();
    super.dispose();
  }

  void _onTick(Duration _) {
    runGuarded('karaoke.tick', () {
      if (!_isEffectivelyActive || !_isPlaying) return;
      final now = DateTime.now();
      final nowMs = now.millisecondsSinceEpoch;
      // Cap tick rate to ~60Hz (min 16ms between ticks).
      // On 120Hz/144Hz/240Hz monitors, this cuts CPU usage drastically
      // while remaining completely smooth for text wipe animation.
      if (nowMs - _lastTickMs < 16) return;
      _lastTickMs = nowMs;

      final elapsed = now.difference(_lastSyncTime).inMilliseconds;
      final currentMs =
          _lastAudioMs + (elapsed * _speed).round() - _offsetMs;
      _interpolatedPositionMs.value = currentMs;
      if (_currentResult != null && _currentResult!.lines.isNotEmpty) {
        final lineIndex = activeLyricLineIndex(_currentResult!.lines, currentMs);
        if (_activeLineIndex.value != lineIndex) {
          _activeLineIndex.value = lineIndex;
        }
      }

      // Check if we entered an idle gap or reached the end
      if (!_shouldTickerRun()) {
        _ticker.stop();
      }
    });
  }

  /// Syncs the interpolation clock from the playback snapshot.
  /// Runs from tick listeners and rare rebuilds — writes only the ticker,
  /// the position notifier, and the lyric controller, never setState, so
  /// it never schedules extra frames.
  void _syncPlaybackClock() {
    final snap = ref.read(playbackServiceProvider);
    final audioMs = snap.position.inMilliseconds;
    _isPlaying = snap.isPlaying;
    _speed = snap.speed <= 0 ? 1.0 : snap.speed;
    final now = DateTime.now();

    if (!_isPlaying || !_ticker.isActive) {
      _lastAudioMs = audioMs;
      _lastSyncTime = now;
      final effectiveMs = audioMs - _offsetMs;
      _interpolatedPositionMs.value = effectiveMs;
      if (_currentResult != null && _currentResult!.lines.isNotEmpty) {
        final lineIndex = activeLyricLineIndex(_currentResult!.lines, effectiveMs);
        if (_activeLineIndex.value != lineIndex) {
          _activeLineIndex.value = lineIndex;
        }
      }
    } else if (audioMs != _lastAudioMs) {
      final elapsed = now.difference(_lastSyncTime).inMilliseconds;
      final predicted = _lastAudioMs + (elapsed * _speed).round();
      final drift = audioMs - predicted;
      if (drift < -80 || drift > 80) {
        _lastAudioMs = audioMs;
        _lastSyncTime = now;
        final effectiveMs = audioMs - _offsetMs;
        _interpolatedPositionMs.value = effectiveMs;
        if (_currentResult != null && _currentResult!.lines.isNotEmpty) {
          final lineIndex = activeLyricLineIndex(_currentResult!.lines, effectiveMs);
          if (_activeLineIndex.value != lineIndex) {
            _activeLineIndex.value = lineIndex;
          }
        }
      }
    }

    _updateTickerState();
  }

  @override
  Widget build(BuildContext context) {
    // NOTE: position/isPlaying/speed are subscribed in initState
    // (_syncPlaybackClock), not watched here. They tick 10Hz and feed
    // only ticker/drift side effects, never widget output — watching them
    // rebuilt the whole toolbar + style + list 10x/sec for nothing.
    final offsetMs = ref.watch(lyricsOffsetProvider(widget.track.queueKey));
    final showTransliteration = ref.watch(lyricsTransliterationProvider);
    // Select the single pref: toggling theme/quality elsewhere must
    // not rebuild the karaoke view (it recreates the lyric adapter).
    final wordByWord =
        ref.watch(prefsProvider.select((p) => p.wordByWord));
    final async = ref.watch(waveLyricsProvider(widget.track));

    _offsetMs = offsetMs;
    // Covers offset/track/data-driven syncs; clock ticks arrive via the
    // initState subscriptions. Rare either way (no per-tick rebuilds).
    _syncPlaybackClock();

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
              ref.invalidate(waveLyricsProvider(widget.track)),
        ),
      ),
      data: (result) {
        final effectiveResult = (result.lines.isEmpty && result.plainLyrics.isNotEmpty)
            ? LyricsResult(
                lines: result.plainLyrics
                    .split('\n')
                    .map((l) => l.trim())
                    .where((l) => l.isNotEmpty)
                    .map((l) => LyricLine(timeMs: 0, text: l))
                    .toList(),
                isSynced: false,
                isWordSynced: false,
                plainLyrics: result.plainLyrics,
                isInstrumental: result.isInstrumental,
                source: result.source,
              )
            : result;

        // Header controls (the source switcher + close) must survive the
        // no-lyrics states. Switching source can legitimately land on a
        // provider with no match, and dropping the switcher then strands
        // the user on "Try again" against the same provider — with no way
        // back to another one. So the empty states render the toolbar too.
        Widget withHeader(Widget body) {
          if (!widget.showHeaderControls) return body;
          return RepaintBoundary(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _KaraokeToolbar(
                  track: widget.track,
                  result: effectiveResult,
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
                Expanded(child: body),
              ],
            ),
          );
        }

        if (effectiveResult.isInstrumental) {
          return withHeader(const WaveEmpty(
            icon: FluentIcons.music_note,
            title: 'Instrumental',
            subtitle: 'No lyrics for this track.',
          ));
        }
        if (effectiveResult.isEmpty) {
          return withHeader(WaveEmpty(
            icon: FluentIcons.microphone,
            title: 'No lyrics found',
            subtitle: 'Pick another source, or check back later.',
            actionLabel: 'Try again',
            onAction: () =>
                ref.invalidate(waveLyricsProvider(widget.track)),
          ));
        }

        if (_currentTrackKey != widget.track.queueKey ||
            _currentResult != effectiveResult ||
            _lastTransliteration != showTransliteration ||
            _lastWordByWord != wordByWord) {
          _currentTrackKey = widget.track.queueKey;
          _currentResult = effectiveResult;
          _lastTransliteration = showTransliteration;
          _lastWordByWord = wordByWord;
          if (effectiveResult.lines.isNotEmpty && effectiveResult.isSynced) {
            final lineIndex =
                activeLyricLineIndex(effectiveResult.lines, _interpolatedPositionMs.value);
            if (_activeLineIndex.value != lineIndex) {
              _activeLineIndex.value = lineIndex;
            }
          } else {
            _activeLineIndex.value = -1;
          }
        }

        return RepaintBoundary(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.showHeaderControls)
                _KaraokeToolbar(
                  track: widget.track,
                  result: effectiveResult,
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
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: _AppleLineLyricsView(
                          result: effectiveResult,
                          activeLineListenable: _activeLineIndex,
                          positionListenable: _interpolatedPositionMs,
                          compact: widget.compact,
                          fontSize: widget.fontSize,
                          showTransliteration: showTransliteration,
                          following: _following,
                          onUserScroll: () {
                            if (_following) setState(() => _following = false);
                          },
                          onResume: () {
                            setState(() => _following = true);
                          },
                          onSeekLineMs: (lineMs) {
                            if (!effectiveResult.isSynced || lineMs <= 0) return;
                            final seekTargetMs = lineMs + _offsetMs;
                            ref.read(playbackServiceProvider.notifier).seek(
                                  Duration(
                                      milliseconds: math.max(0, seekTargetMs)),
                                );
                          },
                        ),
                      ),
                    ),
                    if (!_following && effectiveResult.isSynced)
                      Positioned(
                        right: 16,
                        bottom: 16,
                        child: _ReturnToCurrentPill(
                          onTap: () {
                            setState(() => _following = true);
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
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
  final double lineOpacity;

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
    this.lineOpacity = 1.0,
  });

  @override
  State<WaveKaraokeLyricLine> createState() => _WaveKaraokeLyricLineState();
}

class _WaveKaraokeLyricLineState extends State<WaveKaraokeLyricLine> {
  bool _isHovered = false;
  int _lastPos = 0;
  int _seekGen = 0;
  LyricLine? _cachedLine;
  bool? _cachedUseKaraokeWipe;
  List<LyricSyllable> _cachedSyllables = const [];
  List<KaraokeWordGroup> _cachedWords = const [];

  @override
  void initState() {
    super.initState();
    _lastPos = widget.positionListenable?.value ?? 0;
    widget.positionListenable?.addListener(_onLineTick);
  }

  @override
  void didUpdateWidget(covariant WaveKaraokeLyricLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.positionListenable != widget.positionListenable) {
      oldWidget.positionListenable?.removeListener(_onLineTick);
      _lastPos = widget.positionListenable?.value ?? 0;
      widget.positionListenable?.addListener(_onLineTick);
    }
    if (oldWidget.line != widget.line ||
        oldWidget.karaoke != widget.karaoke ||
        oldWidget.isActive != widget.isActive) {
      _cachedLine = null;
    }
  }

  @override
  void dispose() {
    widget.positionListenable?.removeListener(_onLineTick);
    super.dispose();
  }

  void _onLineTick() {
    final pos = widget.positionListenable?.value ?? 0;
    if (pos < _lastPos - 200) {
      setState(() => _seekGen++);
    }
    _lastPos = pos;
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);

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
    // shadows must be explicit: [Text] merges the ambient DefaultTextStyle
    // (AnimatedDefaultTextStyle above, = activeStyle WITH its glow) into its
    // style, while the wipe's raw TextPainter never sees the ambient. With
    // shadows left null the resting word carried the glow and dropped it the
    // frame the wipe front arrived — a visible dark flash per word.
    final activeUnsungStyle = TextStyle(
      fontSize: baseFontSize,
      fontWeight: FontWeight.w700,
      color: activeTextColor.withValues(alpha: 0.38),
      height: 1.42,
      letterSpacing: -0.3,
      shadows: const [],
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
    if (_cachedLine != widget.line || _cachedUseKaraokeWipe != useKaraokeWipe) {
      _cachedLine = widget.line;
      _cachedUseKaraokeWipe = useKaraokeWipe;
      _cachedSyllables = useKaraokeWipe
          ? (widget.line.hasSyllables
              ? widget.line.syllables
              : interpolateLineSyllables(
                  text: widget.line.text,
                  startTimeMs: widget.line.timeMs,
                  durationMs: widget.line.durationMs,
                ))
          : const <LyricSyllable>[];
      _cachedWords = _cachedSyllables.isNotEmpty
          ? groupSyllablesIntoWords(_cachedSyllables, widget.line.text)
          : const <KaraokeWordGroup>[];
    }

    if (_cachedWords.isNotEmpty) {
      content = Wrap(
        textDirection:
            widget.line.isRtl ? TextDirection.rtl : TextDirection.ltr,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final word in _cachedWords)
            Row(
              mainAxisSize: MainAxisSize.min,
              textDirection:
                  widget.line.isRtl ? TextDirection.rtl : TextDirection.ltr,
              children: [
                for (final syl in word.syllables)
                  _KaraokeSyllableWidget(
                    key: ValueKey('syl_${syl.timeMs}_$_seekGen'),
                    syllable: syl,
                    positionListenable: widget.positionListenable,
                    initialPosMs: widget.positionMs,
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

    final Widget body = AnimatedDefaultTextStyle(
      duration: waveMotion(context, WaveMotion.fast),
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

    return IgnorePointer(
      ignoring: widget.lineOpacity < 0.05,
      child: AnimatedOpacity(
        duration:
            waveMotion(context, const Duration(milliseconds: 220)),
        curve: Curves.easeOutCubic,
        opacity: widget.lineOpacity.clamp(0.0, 1.0),
        child: RepaintBoundary(
          child: MouseRegion(
            onEnter: (_) => setState(() => _isHovered = true),
            onExit: (_) => setState(() => _isHovered = false),
            child: AnimatedContainer(
              duration: waveMotion(context, WaveMotion.normal),
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
          ),
        ),
      ),
    );
  }
}

enum _SyllableState { idle, singing, sung }

/// Bands used to feather the karaoke wipe edge (alpha steps of 1/N).
const _wipeFeatherBands = 2;

/// Progressive fill / wipe for an individual syllable with soft anti-aliased edge.
class _KaraokeSyllableWidget extends StatefulWidget {
  final LyricSyllable syllable;
  final ValueListenable<int>? positionListenable;
  final int initialPosMs;
  final TextStyle activeStyle;
  final TextStyle idleStyle;
  final Color highlightColor;
  final bool isRtl;

  const _KaraokeSyllableWidget({
    super.key,
    required this.syllable,
    this.positionListenable,
    this.initialPosMs = 0,
    required this.activeStyle,
    required this.idleStyle,
    required this.highlightColor,
    this.isRtl = false,
  });

  @override
  State<_KaraokeSyllableWidget> createState() => _KaraokeSyllableWidgetState();
}

class _KaraokeSyllableWidgetState extends State<_KaraokeSyllableWidget> {
  _SyllableState _state = _SyllableState.idle;
  bool _isListening = false;

  int get _startMs => widget.syllable.timeMs;
  int get _endMs =>
      widget.syllable.timeMs + math.max(1, widget.syllable.durationMs);

  _SyllableState _stateFor(int pos) {
    if (pos >= _endMs) return _SyllableState.sung;
    if (pos >= _startMs) return _SyllableState.singing;
    return _SyllableState.idle;
  }

  void _startListening() {
    if (_isListening || widget.positionListenable == null) return;
    widget.positionListenable!.addListener(_onPositionTick);
    _isListening = true;
  }

  void _stopListening() {
    if (!_isListening || widget.positionListenable == null) return;
    widget.positionListenable!.removeListener(_onPositionTick);
    _isListening = false;
  }

  @override
  void initState() {
    super.initState();
    final pos = widget.positionListenable?.value ?? widget.initialPosMs;
    _state = _stateFor(pos);
    if (_state != _SyllableState.sung) {
      _startListening();
    }
  }

  @override
  void didUpdateWidget(covariant _KaraokeSyllableWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.positionListenable != widget.positionListenable) {
      if (_isListening) {
        oldWidget.positionListenable?.removeListener(_onPositionTick);
        _isListening = false;
      }
    }
    final pos = widget.positionListenable?.value ?? widget.initialPosMs;
    final newState = _stateFor(pos);
    if (newState != _state) {
      _state = newState;
    }
    if (_state != _SyllableState.sung) {
      _startListening();
    } else {
      _stopListening();
    }
  }

  TextPainter? _idlePainter;
  TextPainter? _activePainter;
  List<TextPainter> _featherPainters = const [];
  String? _cachedText;
  String? _cachedActiveText;
  TextStyle? _cachedIdleStyle;
  TextStyle? _cachedActiveStyle;
  TextScaler? _cachedScaler;
  TextScaler? _cachedActiveScaler;

  /// Copy of the active style at `cover` opacity — used for the feather
  /// bands so glyphs and their glow both fade toward the unsung state.
  TextStyle _featherStyle(double cover) {
    final base = widget.activeStyle;
    final color = base.color;
    final shadows = base.shadows;
    return base.copyWith(
      color: color?.withValues(alpha: color.a * cover),
      shadows: shadows == null
          ? null
          : [
              for (final s in shadows)
                Shadow(
                  color: s.color.withValues(alpha: s.color.a * cover),
                  blurRadius: s.blurRadius,
                  offset: s.offset,
                ),
            ],
    );
  }

  void _rebuildFeatherPainters(
    String text,
    TextScaler scaler,
    TextDirection textDirection,
  ) {
    for (final p in _featherPainters) {
      p.dispose();
    }
    _featherPainters = [
      for (var i = 1; i < _wipeFeatherBands; i++)
        TextPainter(
          text: TextSpan(
            text: text,
            style: _featherStyle(1.0 - i / _wipeFeatherBands),
          ),
          textDirection: textDirection,
          textScaler: scaler,
        )..layout(),
    ];
  }

  void _ensurePainters(BuildContext context) {
    final text = widget.syllable.text.trimRight();
    final scaler = MediaQuery.textScalerOf(context);
    final textDirection = widget.isRtl ? TextDirection.rtl : TextDirection.ltr;

    if (_idlePainter == null ||
        _cachedText != text ||
        _cachedIdleStyle != widget.idleStyle ||
        _cachedScaler != scaler) {
      _cachedText = text;
      _cachedIdleStyle = widget.idleStyle;
      _cachedScaler = scaler;
      _idlePainter?.dispose();
      _idlePainter = TextPainter(
        text: TextSpan(text: text, style: widget.idleStyle),
        textDirection: textDirection,
        textScaler: scaler,
      )..layout();
    }

    if (_activePainter == null ||
        _cachedActiveText != text ||
        _cachedActiveStyle != widget.activeStyle ||
        _cachedActiveScaler != scaler) {
      _cachedActiveText = text;
      _cachedActiveStyle = widget.activeStyle;
      _cachedActiveScaler = scaler;
      _activePainter?.dispose();
      _activePainter = TextPainter(
        text: TextSpan(text: text, style: widget.activeStyle),
        textDirection: textDirection,
        textScaler: scaler,
      )..layout();
      _rebuildFeatherPainters(text, scaler, textDirection);
    }
  }

  @override
  void dispose() {
    _stopListening();
    _idlePainter?.dispose();
    _activePainter?.dispose();
    for (final p in _featherPainters) {
      p.dispose();
    }
    super.dispose();
  }

  void _onPositionTick() {
    final listenable = widget.positionListenable;
    if (listenable == null) return;
    final pos = listenable.value;
    final newState = _stateFor(pos);

    // Only rebuild on state transitions (idle -> singing, singing -> sung).
    // During active wipe (singing), the CustomPainter repaints directly via
    // Listenable with zero widget rebuild overhead.
    if (newState != _state) {
      if (newState == _SyllableState.sung) {
        _stopListening();
      }
      setState(() {
        _state = newState;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.syllable.text.trimRight();
    if (text.isEmpty) return const SizedBox.shrink();

    // Fast-path 1: Completed syllable -> Plain Text with active style (zero canvas overhead)
    if (_state == _SyllableState.sung) {
      return Text(text, style: widget.activeStyle);
    }

    // Fast-path 2: Future syllable -> Plain Text with idle style (zero canvas overhead)
    if (_state == _SyllableState.idle) {
      return Text(text, style: widget.idleStyle);
    }

    // Active syllable: Zero-allocation direct canvas clip driven directly by positionListenable
    _ensurePainters(context);
    final size = Size(_idlePainter!.width, _idlePainter!.height);

    return RepaintBoundary(
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: CustomPaint(
          size: size,
          painter: _KaraokeSyllablePainter(
            positionListenable: widget.positionListenable,
            syllable: widget.syllable,
            initialPosMs: widget.initialPosMs,
            idlePainter: _idlePainter!,
            activePainter: _activePainter!,
            featherPainters: _featherPainters,
            isRtl: widget.isRtl,
          ),
        ),
      ),
    );
  }
}

/// Zero-allocation canvas clip painter for syllable wipe (replaces ShaderMask / saveLayer).
///
/// Driven directly by [positionListenable] to isolate repaints to the active syllable
/// without scheduling widget rebuilds or thrashing the element tree.
class _KaraokeSyllablePainter extends CustomPainter {
  final ValueListenable<int>? positionListenable;
  final LyricSyllable syllable;
  final int initialPosMs;
  final TextPainter idlePainter;
  final TextPainter activePainter;
  final List<TextPainter> featherPainters;
  final bool isRtl;

  _KaraokeSyllablePainter({
    required this.positionListenable,
    required this.syllable,
    required this.initialPosMs,
    required this.idlePainter,
    required this.activePainter,
    required this.featherPainters,
    required this.isRtl,
  }) : super(repaint: positionListenable);

  @override
  void paint(Canvas canvas, Size size) {
    final pos = positionListenable?.value ?? initialPosMs;
    final progress = calculateSyllableProgress(syllable, pos);

    // 1. Draw base idle text
    idlePainter.paint(canvas, Offset.zero);

    if (progress <= 0.0) return;

    // 2. Wipe: hard-clipped active text, then alpha-stepped bands feathering
    // the leading edge so the fill does not cut a hard line across glyphs.
    final width = size.width;
    final front = width * progress.clamp(0.0, 1.0);
    final feather = math.min(width * 0.08, front * 0.8).clamp(0.0, 18.0);
    final inner = front - feather;

    Rect dirRect(double s0, double s1) {
      if (s1 - s0 < 0.05) return Rect.zero;
      return isRtl
          ? Rect.fromLTRB(width - s1, 0, width - s0, size.height)
          : Rect.fromLTRB(s0, 0, s1, size.height);
    }

    if (inner > 0.05) {
      canvas.save();
      canvas.clipRect(dirRect(0, inner));
      activePainter.paint(canvas, Offset.zero);
      canvas.restore();
    }

    if (feather > 0.05 && featherPainters.isNotEmpty) {
      final step = feather / _wipeFeatherBands;
      for (var j = 0; j < featherPainters.length; j++) {
        final s0 = (inner + j * step).clamp(0.0, front);
        final s1 = (inner + (j + 1) * step).clamp(0.0, front);
        final rect = dirRect(s0, s1);
        if (rect == Rect.zero) continue;
        canvas.save();
        canvas.clipRect(rect);
        featherPainters[j].paint(canvas, Offset.zero);
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(_KaraokeSyllablePainter oldDelegate) {
    return oldDelegate.positionListenable != positionListenable ||
        oldDelegate.syllable != syllable ||
        oldDelegate.idlePainter != idlePainter ||
        oldDelegate.activePainter != activePainter ||
        oldDelegate.featherPainters != featherPainters ||
        oldDelegate.isRtl != isRtl;
  }
}



/// Top toolbar with timing controls, transliteration toggle, and close button.
/// Lyrics source switcher (Now Playing toolbar): Auto + every provider
/// with the effective pick checked, plus `Try another source` which
/// re-runs the race excluding the current provider.
class _SourceMenu extends ConsumerWidget {
  final PlayableTrack track;
  final LyricsResult result;

  const _SourceMenu({required this.track, required this.result});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queueKey = track.queueKey;
    final override = ref.watch(lyricsProviderOverrideProvider(queueKey));
    final defaultId =
        ref.watch(prefsProvider.select((p) => p.lyricsProviderId));
    final effective = override ?? defaultId;
    final currentId = lyricsSourceToProviderId(result.source);

    void apply(String? pickedId) {
      if (pickedId == null) {
        ref
            .read(lyricsExcludedProvidersProvider(queueKey).notifier)
            .state = retryLyricsExcludingCurrent(
          currentId: currentId,
          excludes: ref.read(lyricsExcludedProvidersProvider(queueKey)),
        );
      } else {
        final next = nextLyricsSelection(
          pickedId: pickedId,
          currentId: currentId,
          currentExcludes:
              ref.read(lyricsExcludedProvidersProvider(queueKey)),
        );
        ref.read(lyricsProviderOverrideProvider(queueKey).notifier).state =
            next.override;
        ref.read(lyricsExcludedProvidersProvider(queueKey).notifier).state =
            next.excludes;
      }
      ref.invalidate(waveLyricsProvider(track));
    }

    return LWTooltip(
      message: result.source.isNotEmpty
          ? 'Source: ${result.source} · Change'
          : 'Change lyrics source',
      child: WaveMenuButton(
        placement: FlyoutPlacementMode.bottomRight,
        entries: [
          for (final provider in LyricsProviderId.values)
            WaveMenuAction(
              leading: effective == provider.id
                  ? const Icon(FluentIcons.check_mark, size: 13)
                  : const SizedBox(width: 13),
              label: provider.title,
              onPressed: () => apply(provider.id),
            ),
          const WaveMenuSeparator(),
          WaveMenuAction(
            leading: const Icon(FluentIcons.refresh, size: 13),
            label: 'Try another source',
            onPressed: () => apply(null),
          ),
        ],
        buttonBuilder: (context, onOpen) => _MiniIconButton(
          icon: WaveIcons.lyrics,
          onTap: onOpen,
        ),
      ),
    );
  }
}

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
    // Offset / transliteration / follow all act on lyric content. With no
    // lyrics (empty or instrumental) they are dead controls, but the
    // source switcher must stay: a miss is exactly when it is needed.
    final hasLyrics = !result.isEmpty && !result.isInstrumental;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 8 : 4,
        4,
        compact ? 8 : 4,
        8,
      ),
      child: WaveGlass(
        blur: false,
        borderRadius: WaveRadius.menuRadius,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 14,
          vertical: 6,
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
                color: waveTextPrimary(context),
              ),
            ),
          ),
          // Lyrics source switcher: pick a provider (tried first, the
          // current one excluded from fallback) or retry with the best
          // provider excluding the current one.
          _SourceMenu(
            track: track,
            result: result,
          ),
          const SizedBox(width: 8),
          // Timing Offset Controls: [-] offset [+] [Reset]
          if (hasLyrics && result.isSynced) Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(WaveRadius.controls),
              border: Border.all(
                color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.12),
              ),
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
                            : waveTextPrimary(context),
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
          if (hasLyrics && result.isSynced) const SizedBox(width: 8),
          // Transliteration / Romaji Toggle
          if (hasLyrics) LWTooltip(
            message: showTransliteration
                ? 'Transliteration enabled'
                : 'Enable transliteration',
            child: _MiniIconButton(
              icon: FluentIcons.globe,
              active: showTransliteration,
              onTap: transliterationNotifier.toggle,
            ),
          ),
          if (hasLyrics && result.isSynced) const SizedBox(width: 4),
          if (hasLyrics && result.isSynced) LWTooltip(
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
            : (dark ? WaveColors.textPrimary : WaveColors.lightTextPrimary)
                .withValues(alpha: 0.88);

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
            borderRadius: WaveRadius.controlsRadius,
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
      borderRadius: WaveRadius.heroRadius,
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
  final ValueNotifier<int> activeLineListenable;
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
    required this.activeLineListenable,
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

  @override
  void initState() {
    super.initState();
    widget.activeLineListenable.addListener(_onActiveLineChanged);
    _lastIndex = widget.activeLineListenable.value;
  }

  @override
  void dispose() {
    widget.activeLineListenable.removeListener(_onActiveLineChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _AppleLineLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeLineListenable != widget.activeLineListenable) {
      oldWidget.activeLineListenable.removeListener(_onActiveLineChanged);
      widget.activeLineListenable.addListener(_onActiveLineChanged);
    }
    if (oldWidget.result != widget.result) {
      _pinnedOpening = false;
      _lastIndex = -1;
    }
    if (widget.following && !oldWidget.following) {
      final untimed = !widget.result.isSynced || lyricsAreUntimed(widget.result.lines);
      _scrollTo(
        untimed ? 0 : widget.activeLineListenable.value,
      );
    }
  }

  void _onActiveLineChanged() {
    final active = widget.activeLineListenable.value;
    if (widget.following && _scroll.isAttached) {
      if (active <= 0) {
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
    } else {
      _lastIndex = active;
    }
  }

  void _scrollTo(int index, {bool animate = true}) {
    if (!_scroll.isAttached) return;
    if (index < 0) index = 0;
    final alignment = lyricFollowAlignment(
      index,
      compact: widget.compact,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      runGuarded('karaoke.scroll', () {
        if (!_scroll.isAttached || !mounted) return;
        if (animate) {
          _scroll.scrollTo(
            index: index,
            alignment: alignment,
            duration: waveMotion(context, WaveMotion.normal),
            curve: Curves.easeOutCubic,
          );
        } else {
          _scroll.jumpTo(index: index, alignment: alignment);
        }
      });
    });
  }

  void _pinOpeningToTop() {
    if (_pinnedOpening || !_scroll.isAttached) return;
    _pinnedOpening = true;
    _scrollTo(0, animate: false);
  }

  @override
  Widget build(BuildContext context) {
    final untimed = !widget.result.isSynced || lyricsAreUntimed(widget.result.lines);
    final padding = EdgeInsets.fromLTRB(
      widget.compact ? 12 : 28,
      widget.compact ? 36 : 64,
      widget.compact ? 12 : 28,
      widget.compact ? 80 : 120,
    );

    if (untimed) {
      return ShaderMask(
        shaderCallback: (Rect bounds) {
          return const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black,
              Colors.black,
              Colors.transparent,
            ],
            stops: [0.0, 0.14, 0.86, 1.0],
          ).createShader(bounds);
        },
        blendMode: BlendMode.dstIn,
        child: ListView.builder(
          physics: const ClampingScrollPhysics(),
          padding: padding,
          itemCount: widget.result.lines.length,
          itemBuilder: (context, i) {
            final line = widget.result.lines[i];
            final canSeek = widget.result.isSynced && line.timeMs > 0;
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: MouseRegion(
                cursor: canSeek
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic,
                child: GestureDetector(
                  onTap: canSeek ? () => widget.onSeekLineMs(line.timeMs) : null,
                  child: WaveKaraokeLyricLine(
                    line: line,
                    positionMs: 0,
                    isActive: false,
                    isPast: false,
                    compact: widget.compact,
                    fontSize: widget.fontSize,
                    showTransliteration: widget.showTransliteration,
                    karaoke: false,
                    softenIdle: false,
                  ),
                ),
              ),
            );
          },
        ),
      );
    }

    final initialActive = widget.activeLineListenable.value;

    final list = NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollStartNotification && n.dragDetails != null) {
          widget.onUserScroll();
        }
        return false;
      },
      child: ValueListenableBuilder<int>(
        valueListenable: widget.activeLineListenable,
        builder: (context, active, _) {
          return ScrollablePositionedList.builder(
            itemScrollController: _scroll,
            initialScrollIndex: initialActive > 0 ? initialActive : 0,
            initialAlignment: lyricFollowAlignment(
              initialActive > 0 ? initialActive : 0,
              compact: widget.compact,
            ),
            itemCount: widget.result.lines.length,
            padding: padding,
            itemBuilder: (context, i) {
              final line = widget.result.lines[i];
              final isActive = i == active;

              // Distance-based attenuation when following:
              // Only lines that safely fit without being edged are shown.
              // Lines that would touch or get clipped at the edges fade out.
              double lineOpacity = 1.0;
              if (widget.following && active >= 0) {
                final dist = (i - active).abs();
                if (dist == 0) {
                  lineOpacity = 1.0;
                } else if (dist == 1) {
                  lineOpacity = 0.45;
                } else if (dist == 2) {
                  lineOpacity = 0.16;
                } else {
                  lineOpacity = 0.0;
                }
              }

              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => widget.onSeekLineMs(line.timeMs),
                    child: WaveKaraokeLyricLine(
                      line: line,
                      positionMs: 0,
                      positionListenable:
                          isActive ? widget.positionListenable : null,
                      isActive: isActive,
                      isPast: i < active,
                      compact: widget.compact,
                      fontSize: widget.fontSize,
                      showTransliteration: widget.showTransliteration,
                      karaoke: widget.result.isWordSynced,
                      softenIdle: true,
                      lineOpacity: lineOpacity,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );

    final maskedList = ShaderMask(
      shaderCallback: (Rect bounds) {
        return const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black,
            Colors.black,
            Colors.transparent,
          ],
          stops: [0.0, 0.18, 0.82, 1.0],
        ).createShader(bounds);
      },
      blendMode: BlendMode.dstIn,
      child: list,
    );

    return Stack(
      children: [
        maskedList,
        if (!widget.following && widget.result.isSynced)
          Positioned(
            right: 16,
            bottom: 16,
            child: _ReturnToCurrentPill(onTap: widget.onResume),
          ),
      ],
    );
  }
}
