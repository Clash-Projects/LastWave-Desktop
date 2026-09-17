import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart' show BuildContext;
import 'package:flutter/material.dart'
    show
        Color,
        Curves,
        EdgeInsets,
        FontWeight,
        LinearGradient,
        MainAxisAlignment,
        TextAlign,
        TextStyle;
import 'package:flutter/widgets.dart' show CrossAxisAlignment;
import 'package:flutter_lyric/core/lyric_model.dart' as fl;
import 'package:flutter_lyric/flutter_lyric.dart';

import 'lyrics_models.dart' as lm;

/// Converts LastWave [lm.LyricsResult] into flutter_lyric [fl.LyricModel],
/// inserting standalone Apple Music 3-dot instrumental lines ('•  •  •')
/// into the lyrics flow for intros and breaks >= 4000ms.
fl.LyricModel convertToFlutterLyricModel(
  lm.LyricsResult result, {
  bool showTransliteration = true,
}) {
  final lines = <fl.LyricLine>[];
  if (result.lines.isEmpty) {
    return fl.LyricModel(lines: lines);
  }

  fl.LyricLine createInstrumentalLine(int gapStartMs, int gapEndMs) {
    final gapDuration = gapEndMs - gapStartMs;
    // In Apple Music, the 3 dots countdown during the last 3.5 to 4.5 seconds before vocal entry
    final countdownDuration = math.min(gapDuration, 4500);
    final countdownStart = gapEndMs - countdownDuration;
    final dotDuration = (countdownDuration / 3).round();

    final dotWords = <fl.LyricWord>[
      fl.LyricWord(
        text: '•  ',
        start: Duration(milliseconds: countdownStart),
        end: Duration(milliseconds: countdownStart + dotDuration),
      ),
      fl.LyricWord(
        text: '•  ',
        start: Duration(milliseconds: countdownStart + dotDuration),
        end: Duration(milliseconds: countdownStart + 2 * dotDuration),
      ),
      fl.LyricWord(
        text: '•',
        start: Duration(milliseconds: countdownStart + 2 * dotDuration),
        end: Duration(milliseconds: gapEndMs),
      ),
    ];

    return fl.LyricLine(
      start: Duration(milliseconds: gapStartMs),
      end: Duration(milliseconds: gapEndMs),
      text: '•  •  •',
      words: dotWords,
    );
  }

  // 1. Intro gap: if the song has an instrumental intro >= 4000ms before first vocal
  final firstLine = result.lines.first;
  if (firstLine.timeMs >= 4000) {
    lines.add(createInstrumentalLine(0, firstLine.timeMs));
  }

  // 2. Iterate through lyric lines and insert standalone instrumental lines between gaps >= 4000ms
  for (var i = 0; i < result.lines.length; i++) {
    final line = result.lines[i];
    final nextLine = (i + 1 < result.lines.length) ? result.lines[i + 1] : null;
    final nextStartMs = nextLine?.timeMs;

    final start = Duration(milliseconds: line.timeMs);

    // Compute effective line duration and end time
    int lineDurationMs;
    if (line.durationMs > 0) {
      if (nextStartMs != null &&
          (nextStartMs - line.timeMs >= 7000) &&
          line.durationMs > 4500) {
        lineDurationMs = 4000;
      } else {
        lineDurationMs = line.durationMs;
      }
    } else {
      lineDurationMs = nextStartMs != null
          ? (nextStartMs - line.timeMs >= 7000
              ? 4000
              : (nextStartMs - line.timeMs))
          : 4000;
    }
    final lineEndMs = line.timeMs + lineDurationMs;
    final end = Duration(milliseconds: lineEndMs);

    final words = <fl.LyricWord>[];
    final syllables = line.hasSyllables
        ? line.syllables
        : lm.interpolateLineSyllables(
            text: line.text,
            startTimeMs: line.timeMs,
            durationMs: lineDurationMs,
          );

    var searchOffset = 0;
    for (var i = 0; i < syllables.length; i++) {
      final syl = syllables[i];
      final nextMs = i + 1 < syllables.length
          ? syllables[i + 1].timeMs
          : lineEndMs;
      final sylStartMs = syl.timeMs;
      var sylEndMs = syl.durationMs > 0
          ? syl.timeMs + syl.durationMs
          : nextMs;
      if (sylEndMs <= sylStartMs || sylEndMs > nextMs) {
        sylEndMs = nextMs;
      }
      if (sylEndMs <= sylStartMs) {
        sylEndMs = sylStartMs + 80;
      }
      final sylStart = Duration(milliseconds: sylStartMs);
      final sylEnd = Duration(milliseconds: sylEndMs);

      var wordText = syl.text;
      var matchIdx = line.text.indexOf(wordText, searchOffset);
      if (matchIdx == -1) {
        final trimmed = wordText.trim();
        matchIdx = line.text.indexOf(trimmed, searchOffset);
        if (matchIdx != -1) {
          wordText = trimmed;
        }
      }
      if (matchIdx != -1) {
        searchOffset = matchIdx + wordText.length;
      }

      words.add(fl.LyricWord(
        text: wordText,
        start: sylStart,
        end: sylEnd,
      ));
    }

    lines.add(fl.LyricLine(
      start: start,
      end: end,
      text: line.text,
      translation: (showTransliteration && line.transliteration.isNotEmpty)
          ? line.transliteration
          : null,
      words: words.isNotEmpty ? words : null,
    ));

    // Inter-line gap >= 4000ms
    if (nextStartMs != null) {
      final gapMs = nextStartMs - lineEndMs;
      if (gapMs >= 4000) {
        lines.add(createInstrumentalLine(lineEndMs, nextStartMs));
      }
    }
  }

  return fl.LyricModel(lines: lines);
}

/// Builds Apple Music style [LyricStyle] for [LyricView].
LyricStyle buildAppleMusicLyricStyle(
  BuildContext context, {
  bool compact = false,
  double? fontSize,
  bool isDark = true,
  bool isRtl = false,
}) {
  final baseFontSize = fontSize ?? (compact ? 28.0 : 36.0);
  final idleFontSize =
      (fontSize != null ? fontSize * 0.92 : (compact ? 25.0 : 32.0));
  final activeColor =
      isDark ? const Color(0xFFF6F4EF) : const Color(0xFF18181B);
  final idleColor = activeColor.withValues(alpha: 0.28);
  final highlightColor =
      isDark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);

  return LyricStyle(
    textStyle: TextStyle(
      fontSize: idleFontSize,
      fontWeight: FontWeight.w600,
      color: idleColor,
      height: 1.28,
      letterSpacing: -0.4,
    ),
    activeStyle: TextStyle(
      fontSize: baseFontSize,
      fontWeight: FontWeight.w700,
      color: idleColor,
      height: 1.28,
      letterSpacing: -0.4,
    ),
    activeHighlightColor: highlightColor,
    activeHighlightGradient: LinearGradient(
      colors: [
        highlightColor,
        highlightColor.withValues(alpha: 0.95),
      ],
    ),
    activeHighlightExtraFadeWidth: 20.0,
    translationStyle: TextStyle(
      fontSize: compact ? 13.0 : 16.0,
      fontWeight: FontWeight.w500,
      color: activeColor.withValues(alpha: 0.50),
      height: 1.3,
      letterSpacing: -0.2,
    ),
    translationActiveColor: activeColor.withValues(alpha: 0.85),
    lineTextAlign: isRtl ? TextAlign.right : TextAlign.left,
    contentAlignment: isRtl ? CrossAxisAlignment.end : CrossAxisAlignment.start,
    lineGap: compact ? 28.0 : 36.0,
    translationLineGap: 8.0,
    contentPadding: EdgeInsets.symmetric(
      horizontal: compact ? 24.0 : 36.0,
      vertical: 32.0,
    ),
    activeAnchorPosition: 0.34,
    selectionAnchorPosition: 0.42,
    selectionAlignment: MainAxisAlignment.start,
    fadeRange: FadeRange(top: 90, bottom: 180),
    scrollDuration: const Duration(milliseconds: 380),
    scrollCurve: Curves.easeOutCubic,
    enableSwitchAnimation: true,
    switchEnterDuration: const Duration(milliseconds: 220),
    switchExitDuration: const Duration(milliseconds: 220),
    switchEnterCurve: Curves.easeOutCubic,
    switchExitCurve: Curves.easeOutCubic,
    selectedColor: highlightColor,
    selectedTranslationColor: activeColor.withValues(alpha: 0.9),
    selectionAutoResumeDuration: const Duration(seconds: 3),
    activeAutoResumeDuration: const Duration(seconds: 5),
    selectionAutoResumeMode: SelectionAutoResumeMode.afterSelecting,
  );
}
