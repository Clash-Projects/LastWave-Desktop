import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'lyric_texture_cache.dart';

class SweepState {
  final int posMs;
  final double sweepXLogical;
  final int activeRowIndex;
  final double liftY;
  final bool isWordBouncing;

  const SweepState({
    required this.posMs,
    required this.sweepXLogical,
    required this.activeRowIndex,
    this.liftY = 0.0,
    this.isWordBouncing = false,
  });

  static const initial = SweepState(
    posMs: 0,
    sweepXLogical: 0.0,
    activeRowIndex: 0,
  );
}

/// Adaptive 3-mode lyric clock:
/// 1. Paused / hidden / minimized: 0 Hz (0% CPU)
/// 2. Instrumental break / gaps > 80 ms: Ticker stopped + Timer wake 16 ms before next word (0% CPU)
/// 3. Steady sweep: Paced at 60 fps (< 15.5 ms frames skipped) (0.2–0.8% CPU)
/// 4. Line-switch scroll / word bounce: Full native VSync rate (burst only)
class LyricClockController {
  final TickerProvider vsync;
  late final Ticker _ticker;
  final ValueNotifier<SweepState> sweepNotifier =
      ValueNotifier<SweepState>(SweepState.initial);

  bool _isPlaying = false;
  bool _isVisible = true;
  bool _isScrolling = false;
  double _playbackSpeed = 1.0;

  int _baseAudioMs = 0;
  int _lastSyncEpoch = 0;

  BakedLyricLine? _activeBakedLine;
  Timer? _gapTimer;
  Duration? _lastSweepTick;

  LyricClockController({required this.vsync}) {
    _ticker = vsync.createTicker(_onTick);
  }

  bool get isTickerActive => _ticker.isActive;
  bool get isPlaying => _isPlaying;

  void setScrolling(bool scrolling) {
    if (_isScrolling == scrolling) return;
    _isScrolling = scrolling;
    if (_isScrolling && _isPlaying && _isVisible && !_ticker.isActive) {
      _ticker.start();
    }
  }

  void setActiveBakedLine(BakedLyricLine? bakedLine) {
    if (_activeBakedLine?.lineIndex == bakedLine?.lineIndex) return;
    _activeBakedLine = bakedLine;
    _cancelGapTimer();
    _recomputeSweep(currentPositionMs);
    _updateTickerRunning();
  }

  void syncPlayback({
    required bool isPlaying,
    required bool isVisible,
    required int audioMs,
    double speed = 1.0,
  }) {
    final wasPlaying = _isPlaying;
    _isPlaying = isPlaying;
    _isVisible = isVisible;
    _playbackSpeed = speed <= 0 ? 1.0 : speed;

    final now = DateTime.now().millisecondsSinceEpoch;
    final drift = (audioMs - currentPositionMs).abs();

    if (!wasPlaying && isPlaying) {
      _cancelGapTimer();
      _baseAudioMs = audioMs;
      _lastSyncEpoch = now;
    } else if (drift > 75 || !isPlaying) {
      _cancelGapTimer();
      _baseAudioMs = audioMs;
      _lastSyncEpoch = now;
    }

    _recomputeSweep(currentPositionMs);
    _updateTickerRunning();
  }

  int get currentPositionMs {
    if (!_isPlaying) return _baseAudioMs;
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = ((now - _lastSyncEpoch) * _playbackSpeed).round();
    return _baseAudioMs + elapsed;
  }

  void _cancelGapTimer() {
    _gapTimer?.cancel();
    _gapTimer = null;
  }

  void _updateTickerRunning() {
    final shouldRun = _isPlaying && _isVisible;
    if (!shouldRun) {
      _cancelGapTimer();
      if (_ticker.isActive) _ticker.stop();
      return;
    }

    // Check if currently sitting in a long gap
    final pos = currentPositionMs;
    final baked = _activeBakedLine;
    if (baked != null && baked.words.isNotEmpty && !_isScrolling) {
      final words = baked.words;
      if (pos < words.first.startMs) {
        final gap = words.first.startMs - pos;
        if (gap > 80) {
          if (_ticker.isActive) _ticker.stop();
          _scheduleGapWakeup(gap);
          return;
        }
      }
    }

    if (!_ticker.isActive && _gapTimer == null) {
      _ticker.start();
    }
  }

  void _scheduleGapWakeup(int gapMs) {
    _cancelGapTimer();
    final wakeDelayMs = math.max(1, gapMs - 16);
    _gapTimer = Timer(Duration(milliseconds: wakeDelayMs), () {
      _gapTimer = null;
      if (_isPlaying && _isVisible && !_ticker.isActive) {
        _ticker.start();
      }
    });
  }

  void _onTick(Duration elapsed) {
    if (!_isPlaying || !_isVisible) {
      if (_ticker.isActive) _ticker.stop();
      return;
    }

    final pos = currentPositionMs;
    final baked = _activeBakedLine;

    if (baked == null || baked.words.isEmpty) {
      sweepNotifier.value = SweepState(
        posMs: pos,
        sweepXLogical: 0.0,
        activeRowIndex: 0,
        liftY: 0.0,
        isWordBouncing: false,
      );
      return;
    }

    final words = baked.words;

    // Check gap sleep between words
    for (var i = 0; i < words.length - 1; i++) {
      final cur = words[i];
      final next = words[i + 1];
      if (pos >= cur.endMs && pos < next.startMs) {
        final gap = next.startMs - pos;
        if (gap > 80 && !_isScrolling) {
          // Emit resting position at end of word
          sweepNotifier.value = SweepState(
            posMs: pos,
            sweepXLogical: cur.x1,
            activeRowIndex: cur.rowIndex,
            liftY: 0.0,
            isWordBouncing: false,
          );
          _ticker.stop();
          _scheduleGapWakeup(gap);
          return;
        }
      }
    }

    final sweep = _computeSweepFrom(baked, pos);

    // Frame pacing:
    // If not scrolling and not actively bouncing words, cap steady sweep to 60 fps
    if (!_isScrolling && !sweep.isWordBouncing) {
      if (_lastSweepTick != null &&
          (elapsed - _lastSweepTick!).inMicroseconds < 15500) {
        return;
      }
    }
    _lastSweepTick = elapsed;
    sweepNotifier.value = sweep;
  }

  void _recomputeSweep(int pos) {
    final baked = _activeBakedLine;
    if (baked == null || baked.words.isEmpty) {
      sweepNotifier.value = SweepState(
        posMs: pos,
        sweepXLogical: 0.0,
        activeRowIndex: 0,
      );
      return;
    }
    sweepNotifier.value = _computeSweepFrom(baked, pos);
  }

  SweepState _computeSweepFrom(BakedLyricLine baked, int pos) {
    final words = baked.words;

    if (pos < words.first.startMs) {
      return SweepState(
        posMs: pos,
        sweepXLogical: 0.0,
        activeRowIndex: words.first.rowIndex,
        liftY: 0.0,
        isWordBouncing: false,
      );
    }

    if (pos >= words.last.endMs) {
      return SweepState(
        posMs: pos,
        sweepXLogical: baked.logicalSize.width,
        activeRowIndex: words.last.rowIndex,
        liftY: 0.0,
        isWordBouncing: false,
      );
    }

    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      if (pos >= w.startMs && pos < w.endMs) {
        final dur = math.max(1, w.endMs - w.startMs);
        final progress = ((pos - w.startMs) / dur).clamp(0.0, 1.0);
        final sweepX = w.x0 + progress * (w.x1 - w.x0);
        // Spring lift during singing word
        final liftY = -2.5 * math.sin(math.pi * progress);
        return SweepState(
          posMs: pos,
          sweepXLogical: sweepX,
          activeRowIndex: w.rowIndex,
          liftY: liftY,
          isWordBouncing: liftY.abs() > 0.05,
        );
      }
      if (i + 1 < words.length && pos >= w.endMs && pos < words[i + 1].startMs) {
        return SweepState(
          posMs: pos,
          sweepXLogical: w.x1,
          activeRowIndex: w.rowIndex,
          liftY: 0.0,
          isWordBouncing: false,
        );
      }
    }

    return SweepState(
      posMs: pos,
      sweepXLogical: baked.logicalSize.width,
      activeRowIndex: words.last.rowIndex,
      liftY: 0.0,
      isWordBouncing: false,
    );
  }

  void dispose() {
    _cancelGapTimer();
    _ticker.dispose();
    sweepNotifier.dispose();
  }
}
