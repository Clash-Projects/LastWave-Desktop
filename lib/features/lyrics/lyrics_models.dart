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

/// Parse standard LRC into [LyricLine]s.
///
/// Mirrors `LyricsRepository.parseLrc`: `[mm:ss.xx]` timestamps,
/// `[offset:±ms]` support, sorted by time, offset clamped ≥ 0.
List<LyricLine> parseLrc(String lrc) {
  final timestampRegex =
      RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{2,3}))?\]');
  final offsetRegex = RegExp(r'\[offset:\s*([+-]?\d+)\]');
  var offset = 0;
  final lines = <LyricLine>[];
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
      lines.add(LyricLine(timeMs: totalMs, text: text));
    }
  }
  lines.sort((a, b) => a.timeMs.compareTo(b.timeMs));
  return lines;
}
