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
/// True when every cue shares the same timestamp (including Apple
/// `itunes:timing="None"` transcripts where every line is 0). Follow
/// scroll must not treat that as "already on the last line".
bool lyricsAreUntimed(List<LyricLine> lines) {
  if (lines.length < 2) return false;
  final first = lines.first.timeMs;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].timeMs != first) return false;
  }
  return true;
}

int lyricsBodyLength(LyricsResult result) {
  var n = 0;
  for (final line in result.lines) {
    n += line.text.trim().length;
  }
  if (n > 0) return n;
  return result.plainLyrics.replaceAll(RegExp(r'\s+'), '').length;
}

/// Apple unsynced TTML often packs two sung phrases into one `<p>`.
/// Split once at the midpoint so the second phrase is not clipped.
List<String> expandPackedLyricLine(String text, {int maxLen = 48}) {
  final t = text.trim();
  if (t.isEmpty) return const [];
  if (t.length <= maxLen) return [t];
  final mid = t.length ~/ 2;
  var at = t.lastIndexOf(' ', mid);
  if (at < (t.length * 0.35).floor()) {
    at = t.indexOf(' ', mid);
  }
  if (at <= 0 || at >= t.length - 1) return [t];
  final left = t.substring(0, at).trim();
  final right = t.substring(at + 1).trim();
  if (left.length < 16 || right.length < 16) return [t];
  return [left, right];
}

List<LyricLine> expandPackedLyricLines(List<LyricLine> lines) {
  final out = <LyricLine>[];
  for (final line in lines) {
    final parts = expandPackedLyricLine(line.text);
    if (parts.isEmpty) continue;
    if (parts.length == 1) {
      out.add(line);
      continue;
    }
    for (final part in parts) {
      out.add(LyricLine(
        timeMs: line.timeMs,
        durationMs: line.durationMs,
        text: part,
        transliteration: line.transliteration,
      ));
    }
  }
  return out;
}

int activeLyricLineIndex(List<LyricLine> lines, int positionMs) {
  if (lines.isEmpty) return -1;
  if (positionMs < lines.first.timeMs) return -1;
  if (lyricsAreUntimed(lines)) return -1;

  var nextDistinct = -1;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].timeMs != lines.first.timeMs) {
      nextDistinct = i;
      break;
    }
  }
  if (nextDistinct >= 0 && positionMs < lines[nextDistinct].timeMs) {
    return 0;
  }

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
///
/// Enhanced LRC carries inline word stamps (`<m:ss.xx>word`): the text
/// before the first stamp is sung from the line start, each stamped run
/// runs to the next stamp (or the next line, or +800ms), and stamps are
/// stripped from the display text. Unstamped input parses exactly as before.
List<LyricLine> parseLrc(String lrc) {
  final timestampRegex =
      RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{2,3}))?\]');
  final offsetRegex = RegExp(r'\[offset:\s*([+-]?\d+)\]');
  var offset = 0;
  final rawEntries = <({int timeMs, String body})>[];
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
    final body = line.replaceAll(timestampRegex, '');
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
      rawEntries.add((timeMs: totalMs, body: body));
    }
  }
  rawEntries.sort((a, b) => a.timeMs.compareTo(b.timeMs));

  // Compute duration and syllables (real word stamps, else interpolation
  // for smooth karaoke wipe).
  final result = <LyricLine>[];
  for (var i = 0; i < rawEntries.length; i++) {
    final current = rawEntries[i];
    final nextTime =
        (i + 1 < rawEntries.length) ? rawEntries[i + 1].timeMs : null;
    final text = current.body.replaceAll(_wordStampRegex, '').trim();
    final words = _parseWordRuns(current.body, current.timeMs, nextTime);
    if (words.isNotEmpty) {
      final lineStart = math.min(current.timeMs, words.first.timeMs);
      final calcDur = nextTime != null
          ? (nextTime - lineStart).clamp(80, 20000)
          : 4000;
      result.add(LyricLine(
        timeMs: lineStart,
        durationMs: calcDur,
        text: text.isNotEmpty
            ? text
            : words.map((w) => w.text).join(' '),
        syllables: words,
      ));
      continue;
    }
    if (text.isEmpty) continue;
    final calcDur = nextTime != null
        ? (nextTime - current.timeMs).clamp(80, 20000)
        : 4000;
    result.add(LyricLine(
      timeMs: current.timeMs,
      durationMs: calcDur,
      text: text,
      syllables: interpolateLineSyllables(
        text: text,
        startTimeMs: current.timeMs,
        durationMs: calcDur,
      ),
    ));
  }
  return result;
}

final _wordStampRegex = RegExp(r'<(\d{1,3}):(\d{2})[.:](\d{2,3})>');

int _wordStampToMs(String minRaw, String secRaw, String fracRaw) {
  final min = int.tryParse(minRaw) ?? 0;
  final sec = int.tryParse(secRaw) ?? 0;
  var fracMs = 0;
  if (fracRaw.length == 1) {
    fracMs = (int.tryParse(fracRaw) ?? 0) * 100;
  } else if (fracRaw.length == 2) {
    fracMs = (int.tryParse(fracRaw) ?? 0) * 10;
  } else if (fracRaw.length == 3) {
    fracMs = int.tryParse(fracRaw) ?? 0;
  }
  return min * 60000 + sec * 1000 + fracMs;
}

/// Split an enhanced-LRC body at its inline word stamps. Text before the
/// first stamp is sung from the line start; each stamped run ends at the
/// next stamp, the next line, or +800ms.
List<LyricSyllable> _parseWordRuns(
  String body,
  int lineStartMs,
  int? lineEndMs,
) {
  final marks = _wordStampRegex.allMatches(body).toList();
  if (marks.isEmpty) return const [];
  final words = <LyricSyllable>[];
  final leading = body.substring(0, marks.first.start).trim();
  if (leading.isNotEmpty) {
    final firstStart = _wordStampToMs(
      marks.first.group(1)!,
      marks.first.group(2)!,
      marks.first.group(3)!,
    );
    words.add(LyricSyllable(
      timeMs: lineStartMs,
      durationMs: (firstStart - lineStartMs).clamp(0, 1 << 31),
      text: leading,
    ));
  }
  for (var i = 0; i < marks.length; i++) {
    final mark = marks[i];
    final until =
        i + 1 < marks.length ? marks[i + 1].start : body.length;
    final text = body.substring(mark.end, until).trim();
    if (text.isEmpty) continue;
    final startMs = _wordStampToMs(
      mark.group(1)!,
      mark.group(2)!,
      mark.group(3)!,
    );
    final endMs = i + 1 < marks.length
        ? _wordStampToMs(
            marks[i + 1].group(1)!,
            marks[i + 1].group(2)!,
            marks[i + 1].group(3)!,
          )
        : (lineEndMs ?? (startMs + 800));
    words.add(LyricSyllable(
      timeMs: startMs.clamp(0, 1 << 31),
      durationMs: (endMs - startMs).clamp(0, 1 << 31),
      text: text,
    ));
  }
  return words;
}

/// Parse enhanced LRC (inline `<m:ss.xx>` word stamps) only: returns
/// empty when the source carries no word stamps at all.
List<LyricLine> parseEnhancedLrc(String lrc) {
  if (!_wordStampRegex.hasMatch(lrc)) return const [];
  return parseLrc(lrc);
}

/// Recording-version tags that distinguish releases of one song.
/// Remaster/radio-edit style markers are deliberately absent: cleaning
/// normalizes those, and they denote the same recording.
const _versionKeywords = <String, String>{
  'live': 'live',
  'concert': 'live',
  'session': 'live',
  'unplugged': 'unplugged',
  'acoustic': 'acoustic',
  'remix': 'remix',
  'cover': 'cover',
  'karaoke': 'karaoke',
  'instrumental': 'instrumental',
  'slowed': 'slowed',
  'sped up': 'sped',
  'speed up': 'sped',
  'spedup': 'sped',
  'sped': 'sped',
  'nightcore': 'sped',
  'demo': 'demo',
  'lullaby': 'lullaby',
  '8d': '8d',
};

/// Version tags found in brackets or a trailing `- X` suffix.
Set<String> _versionTags(String rawTitle) {
  final tags = <String>{};
  final segments = <String>[];
  for (final m in RegExp(r'[\(\[](.*?)[\)\]]').allMatches(rawTitle)) {
    segments.add(m.group(1) ?? '');
  }
  final trailing =
      RegExp(r'\s*[-–—:]\s*([^-–—:\(\[]+)\s*$').firstMatch(rawTitle);
  if (trailing != null) segments.add(trailing.group(1) ?? '');
  for (final segment in segments) {
    final lower = ' ${segment.toLowerCase()} ';
    _versionKeywords.forEach((keyword, tag) {
      if (lower.contains(keyword)) tags.add(tag);
    });
  }
  return tags;
}

/// True only when both titles describe the same recording version —
/// a live/remix/cover tag on one side but not the other rejects.
bool lyricsSameVersion(String requestTitle, String candidateTitle) {
  final a = _versionTags(requestTitle);
  final b = _versionTags(candidateTitle);
  return a.length == b.length && a.containsAll(b);
}

/// Removes a leading `Artist - ` / `Artist – ` / `Artist: ` segment.
String stripLeadingArtistPrefix(String raw) => _stripLeadingArtistPrefix(raw);

String _stripLeadingArtistPrefix(String raw) {
  final stripped =
      raw.replaceFirst(RegExp(r'^\s*.+?\s*[-–—:]\s+(?=\S)'), '').trim();
  return stripped.length >= 2 ? stripped : raw.trim();
}

bool _tokenOverlap(String a, String b, double floor) {
  final aTokens = a.toLowerCase().split(RegExp(r'\s+')).toSet();
  final bTokens = b.toLowerCase().split(RegExp(r'\s+')).toSet();
  final union = aTokens.union(bTokens).length;
  if (union == 0) return false;
  return aTokens.intersection(bTokens).length / union >= floor;
}

/// Title match that also tolerates dirty community titles carrying an
/// `Artist - Title` prefix. Bare `contains` is length-gated (shorter
/// side must cover >=70% of the longer side), else token overlap decides.
bool lyricsTitlesMatchStrict(String candidateTitle, String requestTitle) {
  for (final cand in [candidateTitle, _stripLeadingArtistPrefix(candidateTitle)]) {
    final ca = cand.trim();
    final cb = requestTitle.trim();
    if (ca.isEmpty || cb.isEmpty) continue;
    if (ca.toLowerCase() == cb.toLowerCase()) return true;
    if (ca.toLowerCase().contains(cb.toLowerCase()) ||
        cb.toLowerCase().contains(ca.toLowerCase())) {
      final ratio =
          math.min(ca.length, cb.length) / math.max(ca.length, cb.length);
      if (ratio >= 0.7) return true;
    }
    if (_tokenOverlap(ca, cb, 0.5)) return true;
  }
  return false;
}

/// Artist agreement for search-result filtering. Bare `contains` both
/// ways accepted `Ann` for `Annie` — exact wins, substring needs length
/// cover, otherwise token overlap.
bool lyricsArtistsMatchStrict(String candidateArtist, String requestArtist) {
  final ca = candidateArtist.trim();
  final ra = requestArtist.trim();
  if (ca.isEmpty || ra.isEmpty) return false;
  if (ca.toLowerCase() == ra.toLowerCase()) return true;
  if (ca.toLowerCase().contains(ra.toLowerCase()) ||
      ra.toLowerCase().contains(ca.toLowerCase())) {
    if (math.min(ca.length, ra.length) < 4) {
      return _tokenOverlap(ca, ra, 0.5);
    }
    final ratio =
        math.min(ca.length, ra.length) / math.max(ca.length, ra.length);
    if (ratio >= 0.6) return true;
  }
  return _tokenOverlap(ca, ra, 0.5);
}

final _searchWhitespace = RegExp(r'\s+');
final _searchCredits = [
  RegExp(r'\s*[(\[]\s*(feat|ft|featuring|with)\b[^)\]]*[)\]]',
      caseSensitive: false),
  RegExp(r'\s+(feat|ft|featuring)\.?\s+.*$', caseSensitive: false),
  RegExp(
      r'\s*[(\[]\s*(official\s*)?(music\s*)?'
      r'(video|audio|visuali[sz]er|lyrics?\s*video|lyrics?|m/?v|hd|hq|4k|full\s*song)'
      r'\s*[)\]]',
      caseSensitive: false),
  RegExp(r'\s*[(\[]\s*official\s*[)\]]', caseSensitive: false),
];

/// Search-form title: strip credits/packaging only. Version markers
/// (remix, live, acoustic …) name a different recording and survive so
/// [lyricsSameVersion] can reject the wrong cut.
String lyricsForSearchTitle(String raw) {
  var name = raw;
  for (final pattern in _searchCredits) {
    name = name.replaceAll(pattern, ' ');
  }
  return name
      .replaceAll(_searchWhitespace, ' ')
      .trim()
      .replaceAll(RegExp(r'[,–—-]+$'), '')
      .trim()
      .ifEmpty(raw.trim());
}

/// Search-form artist: strip the YouTube `- Topic` suffix.
String lyricsForSearchArtist(String raw) {
  final stripped = raw.replaceAll(RegExp(r'\s*-\s*Topic$'), '').trim();
  return stripped.isEmpty ? raw.trim() : stripped;
}

extension _IfEmpty on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

/// Decode HTML/XML entities (`&#x..;`, `&#..;`, named — `&amp;` last).
String lyricsDecodeEntities(String raw) {
  if (!raw.contains('&')) return raw;
  var out = raw.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
    final code = int.tryParse(m.group(1)!, radix: 16);
    return code == null ? m.group(0)! : String.fromCharCode(code);
  });
  out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final code = int.tryParse(m.group(1)!);
    return code == null ? m.group(0)! : String.fromCharCode(code);
  });
  return out
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}

/// Duration plausibility for providers whose responses carry no
/// candidate identity: the lyric timeline must roughly fit the track.
/// Rejects timelines running 45s+ past the end, or covering under half
/// of a track while missing 90s+. Lenient by design.
bool lyricsPlausibleDuration(List<LyricLine> lines, int? durationSeconds) {
  if (durationSeconds == null || durationSeconds <= 0) return true;
  if (lines.length < 3) return true;
  final expectedMs = durationSeconds * 1000;
  if (expectedMs < 60000) return true;
  var endMs = 0;
  for (final line in lines) {
    var sylEnd = 0;
    for (final s in line.syllables) {
      final e = s.timeMs + s.durationMs;
      if (e > sylEnd) sylEnd = e;
    }
    final e = math.max(line.timeMs + line.durationMs, sylEnd);
    if (e > endMs) endMs = e;
  }
  if (endMs <= 0) return true;
  if (endMs > expectedMs + 45000) return false;
  if (endMs < expectedMs * 0.5 && expectedMs - endMs > 90000) return false;
  return true;
}

/// Parse TTML (`<p begin end>` lines, `<span begin end>` words).
List<LyricLine> parseTtml(String ttml) {
  final pTag = RegExp(
      r'<p\s+([^>]*?)>(.*?)</p>',
      dotAll: true);
  final spanTag = RegExp(
      r'<span\s+([^>]*?)>(.*?)</span>(\s*)',
      dotAll: true);
  final xmlTag = RegExp(r'<[^>]+>');
  final lines = <LyricLine>[];

  for (final p in pTag.allMatches(ttml)) {
    final pAttrs = p.group(1) ?? '';
    final inner = p.group(2) ?? '';
    final pBeginMatch = RegExp(r'begin="([^"]+)"').firstMatch(pAttrs);
    final pEndMatch = RegExp(r'end="([^"]+)"').firstMatch(pAttrs);
    final start = _parseTtmlTime(pBeginMatch?.group(1) ?? '');
    final end = _parseTtmlTime(pEndMatch?.group(1) ?? '');
    final duration = (end - start).clamp(0, 1 << 31);
    final spans = spanTag.allMatches(inner).toList();

    if (spans.isEmpty) {
      final text = _unescapeXml(inner.replaceAll(xmlTag, '').trim());
      if (text.isEmpty) continue;
      final syllables = interpolateLineSyllables(
        text: text,
        startTimeMs: start,
        durationMs: duration > 0 ? duration : 4000,
      );
      lines.add(LyricLine(
        timeMs: start,
        durationMs: duration,
        text: text,
        syllables: syllables,
      ));
    } else {
      final syllables = <LyricSyllable>[];
      final buf = StringBuffer();
      final hasExplicitInterTagSpaces =
          RegExp(r'</span>\s+<span').hasMatch(inner);

      for (var i = 0; i < spans.length; i++) {
        final s = spans[i];
        final isLast = i == spans.length - 1;
        final attrs = s.group(1) ?? '';
        final rawContent = s.group(2) ?? '';
        final trailingSpace = s.group(3) ?? '';

        final beginMatch = RegExp(r'begin="([^"]+)"').firstMatch(attrs);
        final endMatch = RegExp(r'end="([^"]+)"').firstMatch(attrs);

        if (beginMatch == null || endMatch == null) {
          // Nested or container span (e.g. <span ttm:role="x-bg">)
          final innerSpans = spanTag.allMatches(rawContent).toList();
          final isBg = attrs.contains('role="x-bg"');
          for (var j = 0; j < innerSpans.length; j++) {
            final ispan = innerSpans[j];
            final isInnerLast = isLast && j == innerSpans.length - 1;
            final iattrs = ispan.group(1) ?? '';
            final ibMatch = RegExp(r'begin="([^"]+)"').firstMatch(iattrs);
            final ieMatch = RegExp(r'end="([^"]+)"').firstMatch(iattrs);
            if (ibMatch == null || ieMatch == null) continue;
            final ws = _parseTtmlTime(ibMatch.group(1) ?? '');
            final we = _parseTtmlTime(ieMatch.group(1) ?? '');
            final wt = _unescapeXml(ispan.group(2)?.replaceAll(xmlTag, '') ?? '');
            final iTrailing = ispan.group(3) ?? '';
            final addSpace = hasExplicitInterTagSpaces
                ? (wt.endsWith(' ') || iTrailing.isNotEmpty)
                : (!isInnerLast && !wt.endsWith(' '));
            final sylText = addSpace ? '${wt.trimRight()} ' : wt;
            syllables.add(LyricSyllable(
              timeMs: ws,
              durationMs: (we - ws).clamp(0, 1 << 31),
              text: hasExplicitInterTagSpaces ? sylText : wt.trim(),
              isBackground: isBg,
            ));
            buf.write(sylText);
          }
          continue;
        }

        final ws = _parseTtmlTime(beginMatch.group(1) ?? '');
        final we = _parseTtmlTime(endMatch.group(1) ?? '');
        final wt = _unescapeXml(rawContent.replaceAll(xmlTag, ''));
        final isBg = attrs.contains('role="x-bg"');
        final addSpace = hasExplicitInterTagSpaces
            ? (wt.endsWith(' ') || trailingSpace.isNotEmpty)
            : (!isLast && !wt.endsWith(' '));
        final sylText = addSpace ? '${wt.trimRight()} ' : wt;
        syllables.add(LyricSyllable(
          timeMs: ws,
          durationMs: (we - ws).clamp(0, 1 << 31),
          text: hasExplicitInterTagSpaces ? sylText : wt.trim(),
          isBackground: isBg,
        ));
        buf.write(sylText);
      }

      final text = buf.toString().trim();
      if (text.isEmpty) continue;
      lines.add(LyricLine(
        timeMs: start,
        durationMs: duration,
        text: text,
        syllables: syllables,
      ));
    }
  }
  lines.sort((a, b) => a.timeMs.compareTo(b.timeMs));
  return lines;
}

int _parseTtmlTime(String s) {
  s = s.trim();
  if (s.isEmpty) return 0;
  try {
    if (s.endsWith('ms')) {
      return double.parse(s.substring(0, s.length - 2)).round();
    }
    if (s.endsWith('s')) {
      return (double.parse(s.substring(0, s.length - 1)) * 1000).round();
    }
    if (s.contains(':')) {
      final parts = s.split(':');
      final nums = parts.map(double.parse).toList().reversed.toList();
      var total = 0.0;
      var mult = 1.0;
      for (final n in nums) {
        total += n * mult;
        mult *= 60.0;
      }
      return (total * 1000).round();
    }
    return (double.parse(s) * 1000).round();
  } catch (_) {
    return 0;
  }
}

String _unescapeXml(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'");
