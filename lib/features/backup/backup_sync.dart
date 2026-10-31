import 'dart:convert';

/// Three-way merge of two LastWave backup libraries, so the phone and the
/// desktop can both edit and then sync through one shared file without a
/// server. Kept in step with LastWave-Native's `BackupMerge.kt`.
///
/// [base] is the file as this device last synced it (null on the first
/// sync), [local] this device's library, [remote] the file now. Comparing
/// each side with the base tells who added, edited or deleted what:
/// - playlists match by id, except Liked Songs which match by mode;
/// - tracks match by "name|artist" (lowercased), exclusions by trackKey;
/// - an edit beats a delete; without a base everything is kept (union);
/// - track order follows the file, local additions go at the end.
///
/// [holds] tells which tracks the local device can keep: one it cannot
/// (the phone's local songs, on the desktop) is never read as deleted;
/// a playlist it cannot keep ([holdsPlaylist] false) is left as the file has it.
/// Everything is in the phone's backup shape (`tracksJson` as a string).
class MergedLibrary {
  final List<Map<String, dynamic>> playlists;
  final List<Map<String, dynamic>> exclusions;
  const MergedLibrary(this.playlists, this.exclusions);
}

String trackKey(Map<String, dynamic> track) =>
    '${(track['name'] ?? '').toString().trim().toLowerCase()}'
    '|${(track['artist'] ?? '').toString().trim().toLowerCase()}';

String playlistKey(Map<String, dynamic> playlist) =>
    playlist['mode'] == 'liked' ? 'liked' : '${playlist['id']}';

/// Decoded `tracksJson` of a validated backup playlist.
List<Map<String, dynamic>> tracksOf(Map<String, dynamic> playlist) => [
  for (final t in jsonDecode(playlist['tracksJson'] as String) as List)
    Map<String, dynamic>.from(t as Map),
];

const _metaFields = [
  'title',
  'subtitle',
  'isPinned',
  'customCoverUri',
  'discoverSignature',
];

MergedLibrary mergeLibraries({
  required List<Map<String, dynamic>>? basePlaylists,
  required List<Map<String, dynamic>>? baseExclusions,
  required List<Map<String, dynamic>> localPlaylists,
  required List<Map<String, dynamic>> localExclusions,
  required List<Map<String, dynamic>> remotePlaylists,
  required List<Map<String, dynamic>> remoteExclusions,
  bool Function(Map<String, dynamic> track)? holds,
  bool Function(Map<String, dynamic> playlist)? holdsPlaylist,
}) {
  final keep = holds ?? (_) => true;
  Map<String, Map<String, dynamic>> index(List<Map<String, dynamic>>? list) => {
    for (final p in list ?? const <Map<String, dynamic>>[]) playlistKey(p): p,
  };
  final b = index(basePlaylists);
  final l = index(localPlaylists);
  final r = index(remotePlaylists);

  bool same(Map<String, dynamic> x, Map<String, dynamic> base) =>
      _metaFields.every((f) => x[f] == base[f]) &&
      _visibleKeys(x, keep).join('\n') == _visibleKeys(base, keep).join('\n');

  final playlists = <Map<String, dynamic>>[];
  for (final key in {...r.keys, ...l.keys}) {
    final base = basePlaylists == null ? null : b[key];
    final mine = l[key];
    final theirs = r[key];
    if (mine != null && theirs != null) {
      playlists.add(_mergePlaylist(base, mine, theirs, keep));
    } else if (mine != null) {
      // Only here: new locally, or deleted in the file (kept if edited since).
      if (base == null || !same(mine, base)) playlists.add(mine);
    } else if (theirs != null) {
      if (base == null ||
          !same(theirs, base) ||
          !(holdsPlaylist?.call(theirs) ?? true)) {
        playlists.add(theirs);
      }
    }
  }

  return MergedLibrary(
    playlists,
    _mergeByKey(
      baseExclusions,
      localExclusions,
      remoteExclusions,
      (e) => '${e['trackKey']}',
    ),
  );
}

Map<String, dynamic> _mergePlaylist(
  Map<String, dynamic>? base,
  Map<String, dynamic> mine,
  Map<String, dynamic> theirs,
  bool Function(Map<String, dynamic>) keep,
) {
  final merged = Map<String, dynamic>.from(theirs);
  if (base != null) {
    for (final f in _metaFields) {
      if (mine[f] != base[f]) merged[f] = mine[f];
    }
  }
  final remoteTracks = tracksOf(theirs);
  final localTracks = tracksOf(mine);
  final baseTracks = base == null
      ? const <Map<String, dynamic>>[]
      : tracksOf(base);
  final baseKeys = baseTracks.map(trackKey).toSet();
  final localKeys = localTracks.map(trackKey).toSet();
  final removed = {
    for (final t in baseTracks)
      if (keep(t) && !localKeys.contains(trackKey(t))) trackKey(t),
  };
  final result = [
    for (final t in remoteTracks)
      if (!removed.contains(trackKey(t))) t,
  ];
  final present = result.map(trackKey).toSet();
  for (final t in localTracks) {
    final k = trackKey(t);
    if (!baseKeys.contains(k) && present.add(k)) result.add(t);
  }
  merged['tracksJson'] = jsonEncode(result);
  return merged;
}

List<String> _visibleKeys(
  Map<String, dynamic> playlist,
  bool Function(Map<String, dynamic>) keep,
) => [
  for (final t in tracksOf(playlist))
    if (keep(t)) trackKey(t),
];

List<Map<String, dynamic>> _mergeByKey(
  List<Map<String, dynamic>>? base,
  List<Map<String, dynamic>> local,
  List<Map<String, dynamic>> remote,
  String Function(Map<String, dynamic>) keyOf,
) {
  final baseKeys = base?.map(keyOf).toSet();
  final localKeys = local.map(keyOf).toSet();
  final result = [
    for (final e in remote)
      // Deleted here since the last sync: drop it from the file too.
      if (baseKeys == null ||
          !baseKeys.contains(keyOf(e)) ||
          localKeys.contains(keyOf(e)))
        e,
  ];
  final present = result.map(keyOf).toSet();
  for (final e in local) {
    final k = keyOf(e);
    if ((baseKeys == null || !baseKeys.contains(k)) && present.add(k)) {
      result.add(e);
    }
  }
  return result;
}
