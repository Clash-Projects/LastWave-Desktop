import 'dart:convert';

import 'lyrics_models.dart';

/// Compact JSON for a [LyricsResult], including the karaoke syllable trees,
/// for the on-disk lyrics cache (group `lyrics` in `snapshot_cache`).
///
/// Short keys on purpose: a word-synced song is a few hundred syllables and
/// the cache keeps hundreds of songs.

const _version = 1;

/// Cache-key prefix; bump [_version] and this together when the shape changes.
const lyricsCacheKeyPrefix = 'lyr1|';

/// How long a stored result is trusted before the race runs again.
const lyricsCacheMaxAge = Duration(days: 90);

String encodeLyrics(LyricsResult r) => jsonEncode({
      'v': _version,
      'sy': r.isSynced,
      'ws': r.isWordSynced,
      'in': r.isInstrumental,
      'pl': r.plainLyrics,
      'src': r.source,
      'ln': [
        for (final l in r.lines)
          {
            't': l.timeMs,
            'd': l.durationMs,
            'x': l.text,
            if (l.transliteration.isNotEmpty) 'tr': l.transliteration,
            if (l.syllables.isNotEmpty)
              's': [
                for (final s in l.syllables)
                  {
                    't': s.timeMs,
                    'd': s.durationMs,
                    'x': s.text,
                    if (s.isBackground) 'b': 1,
                  },
              ],
          },
      ],
    });

/// Null when the payload is unreadable, from another version, or holds no
/// lyrics (an empty result is never worth serving from cache).
LyricsResult? decodeLyrics(String raw) {
  try {
    final j = jsonDecode(raw);
    if (j is! Map || j['v'] != _version) return null;
    final lines = <LyricLine>[
      for (final l in (j['ln'] as List? ?? const []))
        if (l is Map)
          LyricLine(
            timeMs: (l['t'] as num?)?.toInt() ?? 0,
            durationMs: (l['d'] as num?)?.toInt() ?? 0,
            text: l['x']?.toString() ?? '',
            transliteration: l['tr']?.toString() ?? '',
            syllables: [
              for (final s in (l['s'] as List? ?? const []))
                if (s is Map)
                  LyricSyllable(
                    timeMs: (s['t'] as num?)?.toInt() ?? 0,
                    durationMs: (s['d'] as num?)?.toInt() ?? 0,
                    text: s['x']?.toString() ?? '',
                    isBackground: s['b'] == 1,
                  ),
            ],
          ),
    ];
    final result = LyricsResult(
      lines: lines,
      isSynced: j['sy'] == true,
      isWordSynced: j['ws'] == true,
      plainLyrics: j['pl']?.toString() ?? '',
      isInstrumental: j['in'] == true,
      source: j['src']?.toString() ?? '',
    );
    return result.isEmpty ? null : result;
  } catch (_) {
    return null;
  }
}
