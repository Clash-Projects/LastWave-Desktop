import 'dart:convert';

import '../home/home_snapshot.dart';
import 'home_repository.dart';

/// Disk snapshots for the Last.fm pages (profile stats, top tracks, recent
/// history, friends list). Same stale-while-revalidate contract as the Home
/// snapshots; entries live in the `lastfm` group of `snapshot_cache`.
const cacheGroupLastFm = 'lastfm';

/// Last.fm data is cheap to re-fetch and changes by the minute, so a copy
/// older than this is not worth painting.
const lastFmCacheMaxAge = Duration(days: 14);

/// Key for one Last.fm view. [owner] is the signed-in user and [viewing] the
/// friend being browsed (null = own profile). Null when nobody is signed in.
String? lastFmCacheKey(String what, String owner, {String? viewing, String extra = ''}) {
  if (owner.isEmpty) return null;
  final subject = (viewing == null || viewing.isEmpty) ? owner : viewing;
  return 'lf_${what}_v1|${owner.toLowerCase()}|${subject.toLowerCase()}'
      '${extra.isEmpty ? '' : '|$extra'}';
}

List<T>? _list<T>(String raw, T Function(Map<String, dynamic>) read) {
  try {
    final j = jsonDecode(raw);
    if (j is! Map || j['v'] != 1) return null;
    return [
      for (final e in (j['items'] as List? ?? const []))
        if (e is Map) read(Map<String, dynamic>.from(e)),
    ];
  } catch (_) {
    return null;
  }
}

final homeTracksSnapshotCodec = SnapshotCodec<List<HomeTrack>>(
  encode: (list) => jsonEncode({
    'v': 1,
    'items': [
      for (final t in list)
        {
          'n': t.name,
          'a': t.artist,
          'art': t.artworkUrl,
          if (t.timestampMillis != null) 't': t.timestampMillis,
          'pc': t.playCount,
        },
    ],
  }),
  decode: (raw) => _list(
    raw,
    (e) => HomeTrack(
      name: e['n']?.toString() ?? '',
      artist: e['a']?.toString() ?? '',
      artworkUrl: e['art']?.toString() ?? '',
      timestampMillis: (e['t'] as num?)?.toInt(),
      playCount: (e['pc'] as num?)?.toInt() ?? 0,
    ),
  ),
  isEmpty: (list) => list.isEmpty,
);

final friendEntriesSnapshotCodec = SnapshotCodec<List<FriendEntry>>(
  encode: (list) => jsonEncode({
    'v': 1,
    'items': [
      for (final f in list)
        {'n': f.name, 'r': f.realName, 'av': f.avatarUrl},
    ],
  }),
  decode: (raw) => _list(
    raw,
    (e) => FriendEntry(
      name: e['n']?.toString() ?? '',
      realName: e['r']?.toString() ?? '',
      avatarUrl: e['av']?.toString() ?? '',
    ),
  ),
  isEmpty: (list) => list.isEmpty,
);

final homeStatsSnapshotCodec = SnapshotCodec<HomeStats>(
  encode: (s) => jsonEncode({
    'v': 1,
    's': s.scrobbles,
    'ar': s.artistCount,
    'al': s.albumCount,
    'tr': s.trackCount,
    'av': s.avatarUrl,
  }),
  decode: (raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['v'] != 1) return null;
      return HomeStats(
        scrobbles: (j['s'] as num?)?.toInt() ?? 0,
        artistCount: (j['ar'] as num?)?.toInt() ?? 0,
        albumCount: (j['al'] as num?)?.toInt() ?? 0,
        trackCount: (j['tr'] as num?)?.toInt() ?? 0,
        avatarUrl: j['av']?.toString() ?? '',
      );
    } catch (_) {
      return null;
    }
  },
  // An all-zero payload is a failed or private profile, not data to keep.
  isEmpty: (s) => s.scrobbles == 0 && s.artistCount == 0 && s.trackCount == 0,
);
