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

/// Parse a lyric cue that may be milliseconds, seconds, or a fractional
/// second (e.g. `12.45`). Fractional values under 1000 are seconds.
int parseLyricTimestampMs(dynamic raw) {
  if (raw == null) return 0;
  final n = raw is num ? raw.toDouble() : double.tryParse('$raw') ?? 0;
  if (n <= 0) return 0;
  if (n < 1000 && n != n.roundToDouble()) {
    return (n * 1000).round();
  }
  return n.round();
}

/// Index of the line currently being sung, or `-1` if playback is
/// still before the first cue. Never treats upcoming lines as active,
/// which would scroll a short track to the last line at start.
int activeLyricLineIndex(List<LyricLine> lines, int positionMs) {
  if (lines.isEmpty) return -1;
  if (positionMs < lines.first.timeMs) return -1;
  var active = 0;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].timeMs <= positionMs) {
      active = i;
    } else {
      break;
    }
  }
  return active;
}

/// Viewport alignment for follow-scroll. Opening lines stay at the
/// top; only later lines pin to the Apple ~34% karaoke anchor.
double lyricFollowAlignment(int activeIndex, {required bool compact}) {
  if (activeIndex <= 0) return 0;
  if (activeIndex == 1) return compact ? 0.12 : 0.14;
  return compact ? 0.28 : 0.34;
}

/// Scale cues that were clearly authored in seconds (or microseconds)
/// into milliseconds so a 3-minute song is not treated as already
/// finished after the first second of playback.
LyricsResult ensureMillisecondTimestamps(LyricsResult result) {
  if (!result.isSynced || result.lines.length < 3) return result;
  final times = result.lines.map((l) => l.timeMs).toList()
    ..sort();
  final first = times.first;
  final last = times.last;
  final span = last - first;
  if (last <= 0) return result;

  final int Function(int value) scale;
  // Seconds: last cue under 12 minutes. A millisecond-timed song of
  // that length would already be in the 10_000+ range.
  if (last <= 720 && span <= 720) {
    scale = (v) => v * 1000;
  } else if (last >= 10 * 60 * 1000 * 1000) {
    scale = (v) => (v / 1000).round();
  } else {
    return result;
  }

  return LyricsResult(
    lines: [
      for (final line in result.lines)
        LyricLine(
          timeMs: scale(line.timeMs),
          durationMs: scale(line.durationMs),
          text: line.text,
          syllables: [
            for (final s in line.syllables)
              LyricSyllable(
                timeMs: scale(s.timeMs),
                durationMs: scale(s.durationMs),
                text: s.text,
                isBackground: s.isBackground,
              ),
          ],
          transliteration: line.transliteration,
        ),
    ],
    isSynced: result.isSynced,
    isWordSynced: result.isWordSynced,
    plainLyrics: result.plainLyrics,
    isInstrumental: result.isInstrumental,
    source: result.source,
  );
}

/// Fill missing syllable/line durations and clip overlaps so karaoke
/// wipe lasts until the next word instead of flashing then jumping.
LyricsResult normalizeKaraokeTimings(LyricsResult result) {
  result = ensureMillisecondTimestamps(result);
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
