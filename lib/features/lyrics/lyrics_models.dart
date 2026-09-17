import 'dart:math' as math;

/// Lyrics models. Ported from LastWave-native
/// `data/lyrics/LyricsRepository.kt`.
class LyricSyllable {
  final int timeMs;
  final int durationMs;
  final String text;
  final bool isBackground;
  const LyricSyllable({
    required this.timeMs,
    required this.durationMs,
    required this.text,
    this.isBackground = false,
  });
}

class LyricLine {
  final int timeMs;
  final int durationMs;
  final String text;
  final List<LyricSyllable> syllables;
  final String transliteration;

  const LyricLine({
    required this.timeMs,
    this.durationMs = 0,
    required this.text,
    this.syllables = const [],
    this.transliteration = '',
  });

  bool get hasSyllables => syllables.isNotEmpty;

  bool get isRtl => isRtlText(text);
}

class LyricsResult {
  final List<LyricLine> lines;
  final bool isSynced;
  final bool isWordSynced;
  final String plainLyrics;
  final bool isInstrumental;
  final String source;

  const LyricsResult({
    this.lines = const [],
    this.isSynced = false,
    this.isWordSynced = false,
    this.plainLyrics = '',
    this.isInstrumental = false,
    this.source = '',
  });

  const LyricsResult.empty()
      : this(lines: const [], isSynced: false);

  bool get isEmpty =>
      lines.isEmpty && plainLyrics.isEmpty && !isInstrumental;
}

/// Synthesize proportional word syllables across a line's duration
/// for smooth Apple Music karaoke wipe on line-synced lyrics.
List<LyricSyllable> interpolateLineSyllables({
  required String text,
  required int startTimeMs,
  required int durationMs,
}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];
  final words = trimmed.split(RegExp(r'\s+'));
  if (words.isEmpty) return const [];

  final totalChars = words.fold<int>(0, (acc, w) => acc + w.length);
  if (totalChars <= 0) return const [];

  final safeDuration = durationMs > 0 ? durationMs : math.max(1500, words.length * 350);
  final syllables = <LyricSyllable>[];
  var currentMs = startTimeMs;

  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    final isLast = i == words.length - 1;
    final wordDur = math.max(
      120,
      ((word.length / totalChars) * safeDuration).round(),
    );
    syllables.add(LyricSyllable(
      timeMs: currentMs,
      durationMs: wordDur,
      text: isLast ? word : '$word ',
    ));
    currentMs += wordDur;
  }
  return syllables;
}

/// Fill missing syllable/line durations and clip overlaps so karaoke
/// wipe lasts until the next word instead of flashing then jumping.
LyricsResult normalizeKaraokeTimings(LyricsResult result) {
  if (!result.isSynced || result.lines.isEmpty) return result;
  final src = List<LyricLine>.of(result.lines)
    ..sort((a, b) => a.timeMs.compareTo(b.timeMs));
  final lines = <LyricLine>[];
  for (var i = 0; i < src.length; i++) {
    final line = src[i];
    final nextStart = i + 1 < src.length ? src[i + 1].timeMs : null;
    var duration = line.durationMs;
    if (nextStart != null) {
      final gap = nextStart - line.timeMs;
      if (gap <= 0) {
        duration = 80;
      } else if (duration <= 0 || duration > gap) {
        duration = gap;
      }
    } else if (duration <= 0) {
      duration = 4000;
    }
    duration = duration.clamp(80, 30000);
    final syllables = line.hasSyllables
        ? _normalizeSyllables(line.syllables, line.timeMs, duration)
        : interpolateLineSyllables(
            text: line.text,
            startTimeMs: line.timeMs,
            durationMs: duration,
          );
    lines.add(LyricLine(
      timeMs: line.timeMs,
      durationMs: duration,
      text: line.text,
      syllables: syllables,
      transliteration: line.transliteration,
    ));
  }
  return LyricsResult(
    lines: lines,
    isSynced: result.isSynced,
    isWordSynced: result.isWordSynced,
    plainLyrics: result.plainLyrics,
    isInstrumental: result.isInstrumental,
    source: result.source,
  );
}

List<LyricSyllable> _normalizeSyllables(
  List<LyricSyllable> raw,
  int lineStartMs,
  int lineDurationMs,
) {
  if (raw.isEmpty) return const [];
  final sorted = List<LyricSyllable>.of(raw)
    ..sort((a, b) => a.timeMs.compareTo(b.timeMs));
  final lineEnd = lineStartMs + lineDurationMs;
  final out = <LyricSyllable>[];
  for (var i = 0; i < sorted.length; i++) {
    final s = sorted[i];
    final nextStart =
        i + 1 < sorted.length ? sorted[i + 1].timeMs : lineEnd;
    var start = s.timeMs < lineStartMs ? lineStartMs : s.timeMs;
    if (start >= nextStart) start = math.max(lineStartMs, nextStart - 40);
    final gap = math.max(40, nextStart - start);
    const minSungMs = 80;
    final provided = s.durationMs;
    final int dur;
    if (provided >= minSungMs && provided <= gap) {
      dur = provided;
    } else {
      dur = gap;
    }
    out.add(LyricSyllable(
      timeMs: start,
      durationMs: dur,
      text: s.text,
      isBackground: s.isBackground,
    ));
  }
  return out;
}

/// RTL detection for Arabic/Hebrew lyrics rendering.
bool isRtlText(String text) {
  for (final rune in text.runes) {
    if ((rune >= 0x0590 && rune <= 0x08FF) ||
        (rune >= 0xFB00 && rune <= 0xFDFF) ||
        (rune >= 0xFE70 && rune <= 0xFEFF)) {
      return true;
    }
  }
  return false;
}

/// Parse standard LRC into [LyricLine]s with line durations and
/// word-by-word syllable interpolation.
List<LyricLine> parseLrc(String lrc) {
  final timestampRegex =
      RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{2,3}))?\]');
  final offsetRegex = RegExp(r'\[offset:\s*([+-]?\d+)\]');
  var offset = 0;
  final rawLines = <LyricLine>[];
  for (final raw in lrc.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final offsetMatch = offsetRegex.firstMatch(line);
    if (offsetMatch != null) {
      offset = int.tryParse(offsetMatch.group(1) ?? '') ?? 0;
      continue;
    }
    final matches = timestampRegex.allMatches(line).toList();
    if (matches.isEmpty) continue;
    final text = line.replaceAll(timestampRegex, '').trim();
    if (text.isEmpty) continue;
    for (final m in matches) {
      final min = int.tryParse(m.group(1) ?? '') ?? 0;
      final sec = int.tryParse(m.group(2) ?? '') ?? 0;
      final fracRaw = m.group(3) ?? '';
      var fracMs = 0;
      if (fracRaw.length == 1) {
        fracMs = (int.tryParse(fracRaw) ?? 0) * 100;
      } else if (fracRaw.length == 2) {
        fracMs = (int.tryParse(fracRaw) ?? 0) * 10;
      } else if (fracRaw.length == 3) {
        fracMs = int.tryParse(fracRaw) ?? 0;
      }
      final totalMs =
          (min * 60000 + sec * 1000 + fracMs + offset)
              .clamp(0, 1 << 31);
      rawLines.add(LyricLine(timeMs: totalMs, text: text));
    }
  }
  rawLines.sort((a, b) => a.timeMs.compareTo(b.timeMs));

  // Compute duration and synthesize word syllables for smooth karaoke wipe
  final result = <LyricLine>[];
  for (var i = 0; i < rawLines.length; i++) {
    final current = rawLines[i];
    final nextTime = (i + 1 < rawLines.length) ? rawLines[i + 1].timeMs : null;
    final calcDur = nextTime != null
        ? (nextTime - current.timeMs).clamp(80, 20000)
        : 4000;
    final syllables = current.hasSyllables
        ? current.syllables
        : interpolateLineSyllables(
            text: current.text,
            startTimeMs: current.timeMs,
            durationMs: calcDur,
          );
    result.add(LyricLine(
      timeMs: current.timeMs,
      durationMs: calcDur,
      text: current.text,
      syllables: syllables,
      transliteration: current.transliteration,
    ));
  }
  return result;
}
