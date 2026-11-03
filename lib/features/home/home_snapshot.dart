import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/app_database.dart';
import '../feed/feed_repository.dart';
import '../innertube/innertube_api.dart';
import '../search/shared_providers.dart';

/// On-disk snapshots of the Home data, so a cold start paints the last feed
/// immediately instead of a skeleton while Last.fm + YouTube Music answer
/// (several sequential stages, each with its own timeout).
///
/// Stale-while-revalidate: the first load of a key in a session returns the
/// stored snapshot and refreshes behind it; the refresh is handed to the
/// provider, which rebuilds once with the fresh value. Every later load of
/// the same key (refresh button, sign-in) skips the snapshot and fetches.
///
/// Snapshots live in `kv_store` (no schema change) under keys scoped to the
/// account, so a different Last.fm user or YouTube channel never sees
/// someone else's picks.

/// A snapshot older than this is not shown (the taste it encodes is stale
/// enough that the skeleton is the honest state).
const homeSnapshotMaxAge = Duration(days: 7);

const _feedKeyPrefix = 'home_feed_v1|';
const _shelvesKeyPrefix = 'home_yt_v1|';
const _version = 1;

/// kv_store key for a Last.fm user's feed; null when there is no user.
String? homeFeedSnapshotKey(String username) {
  final u = username.trim().toLowerCase();
  return u.isEmpty ? null : '$_feedKeyPrefix$u';
}

/// kv_store key for a YouTube Music identity (login + channel); null when
/// signed out.
String? homeShelvesSnapshotKey({
  required bool connected,
  required String profileEmail,
  required String activePageId,
}) {
  if (!connected) return null;
  return '$_shelvesKeyPrefix${profileEmail.trim().toLowerCase()}|$activePageId';
}

/// How one kind of Home data is stored.
class SnapshotCodec<T> {
  final String Function(T value, DateTime now) encode;

  /// Null when the payload is unreadable or from another version.
  final ({T value, DateTime savedAt})? Function(String raw) decode;

  /// Empty results are never persisted and never replace a good snapshot:
  /// an offline or rate-limited refresh must not blank the page.
  final bool Function(T value) isEmpty;

  const SnapshotCodec({
    required this.encode,
    required this.decode,
    required this.isEmpty,
  });
}

// -- GeneratedTrack / FeedData ---------------------------------------------

Map<String, dynamic> _trackToJson(GeneratedTrack t) => {
      'n': t.name,
      'a': t.artist,
      'al': t.album,
      'art': t.artworkUrl,
      'v': t.videoId,
      'l': t.listeners,
      'm': t.match,
      'd': t.durationSeconds,
      'p': t.playbackUrl,
    };

GeneratedTrack _trackFromJson(Map<String, dynamic> j) => GeneratedTrack(
      name: j['n']?.toString() ?? '',
      artist: j['a']?.toString() ?? '',
      album: j['al']?.toString() ?? '',
      artworkUrl: j['art']?.toString() ?? '',
      videoId: j['v']?.toString() ?? '',
      listeners: j['l']?.toString() ?? '',
      match: j['m']?.toString() ?? '',
      durationSeconds: (j['d'] as num?)?.toInt() ?? 0,
      playbackUrl: j['p']?.toString() ?? '',
    );

List<GeneratedTrack> _tracksFrom(Object? raw) => [
      for (final e in (raw as List? ?? const []))
        if (e is Map) _trackFromJson(e.cast<String, dynamic>()),
    ];

String _encodeFeed(FeedData f, DateTime now) => jsonEncode({
      'v': _version,
      't': now.millisecondsSinceEpoch,
      'quick': f.quickPicks.map(_trackToJson).toList(),
      'heavy': f.heavyRotation.map(_trackToJson).toList(),
      'fresh': f.freshFinds.map(_trackToJson).toList(),
      'jump': f.jumpBackIn.map(_trackToJson).toList(),
      'because': f.becauseYouListened.map(_trackToJson).toList(),
      'charts': f.charts.map(_trackToJson).toList(),
      'tags': f.tasteTags,
      'seed': f.becauseSeed,
      'aff': f.tasteAffinities,
    });

({FeedData value, DateTime savedAt})? _decodeFeed(String raw) {
  try {
    final j = jsonDecode(raw);
    if (j is! Map || j['v'] != _version) return null;
    final savedAt = DateTime.fromMillisecondsSinceEpoch(
      (j['t'] as num?)?.toInt() ?? 0,
    );
    final data = FeedData(
      quickPicks: _tracksFrom(j['quick']),
      heavyRotation: _tracksFrom(j['heavy']),
      freshFinds: _tracksFrom(j['fresh']),
      jumpBackIn: _tracksFrom(j['jump']),
      becauseYouListened: _tracksFrom(j['because']),
      charts: _tracksFrom(j['charts']),
      tasteTags: [
        for (final t in (j['tags'] as List? ?? const [])) t.toString(),
      ],
      becauseSeed: j['seed']?.toString() ?? '',
      tasteAffinities: {
        for (final e in ((j['aff'] as Map?) ?? const {}).entries)
          e.key.toString(): (e.value as num).toDouble(),
      },
    );
    return (value: data, savedAt: savedAt);
  } catch (_) {
    return null;
  }
}

final feedSnapshotCodec = SnapshotCodec<FeedData>(
  encode: _encodeFeed,
  decode: _decodeFeed,
  isEmpty: (f) => f.isEmpty,
);

// -- YtHomeShelf -------------------------------------------------------------

Map<String, dynamic> _ytTrackToJson(YouTubeMusicTrack t) => {
      'v': t.videoId,
      'n': t.title,
      'a': t.artist,
      'al': t.album,
      'art': t.artworkUrl,
      'd': t.durationSeconds,
      'ab': t.albumBrowseId,
    };

YouTubeMusicTrack _ytTrackFromJson(Map<String, dynamic> j) =>
    YouTubeMusicTrack(
      videoId: j['v']?.toString() ?? '',
      title: j['n']?.toString() ?? '',
      artist: j['a']?.toString() ?? '',
      album: j['al']?.toString() ?? '',
      artworkUrl: j['art']?.toString() ?? '',
      durationSeconds: (j['d'] as num?)?.toInt() ?? 0,
      albumBrowseId: j['ab']?.toString() ?? '',
    );

Map<String, dynamic> _entityToJson(YouTubeMusicEntity e) => {
      'k': e.kind.name,
      'n': e.name,
      'a': e.artist,
      's': e.subtitle,
      'b': e.browseId,
      'p': e.playlistId,
      'art': e.artworkUrl,
    };

YouTubeMusicEntity _entityFromJson(Map<String, dynamic> j) =>
    YouTubeMusicEntity(
      kind: YouTubeEntityKind.values.firstWhere(
        (k) => k.name == j['k'],
        orElse: () => YouTubeEntityKind.album,
      ),
      name: j['n']?.toString() ?? '',
      artist: j['a']?.toString() ?? '',
      subtitle: j['s']?.toString() ?? '',
      browseId: j['b']?.toString() ?? '',
      playlistId: j['p']?.toString() ?? '',
      artworkUrl: j['art']?.toString() ?? '',
    );

List<T> _listOf<T>(Object? raw, T Function(Map<String, dynamic>) read) => [
      for (final e in (raw as List? ?? const []))
        if (e is Map) read(e.cast<String, dynamic>()),
    ];

String _encodeShelves(List<YtHomeShelf> shelves, DateTime now) => jsonEncode({
      'v': _version,
      't': now.millisecondsSinceEpoch,
      'shelves': [
        for (final s in shelves)
          {
            'title': s.title,
            'sub': s.subtitle,
            'tracks': s.tracks.map(_ytTrackToJson).toList(),
            'cards': s.trackCards.map(_ytTrackToJson).toList(),
            'ents': s.entities.map(_entityToJson).toList(),
          },
      ],
    });

({List<YtHomeShelf> value, DateTime savedAt})? _decodeShelves(String raw) {
  try {
    final j = jsonDecode(raw);
    if (j is! Map || j['v'] != _version) return null;
    final savedAt = DateTime.fromMillisecondsSinceEpoch(
      (j['t'] as num?)?.toInt() ?? 0,
    );
    final shelves = <YtHomeShelf>[
      for (final s in (j['shelves'] as List? ?? const []))
        if (s is Map)
          YtHomeShelf(
            title: s['title']?.toString() ?? '',
            subtitle: s['sub']?.toString() ?? '',
            tracks: _listOf(s['tracks'], _ytTrackFromJson),
            trackCards: _listOf(s['cards'], _ytTrackFromJson),
            entities: _listOf(s['ents'], _entityFromJson),
          ),
    ];
    return (value: shelves, savedAt: savedAt);
  } catch (_) {
    return null;
  }
}

final shelvesSnapshotCodec = SnapshotCodec<List<YtHomeShelf>>(
  encode: _encodeShelves,
  decode: _decodeShelves,
  isEmpty: (s) => s.isEmpty,
);

// -- stale-while-revalidate --------------------------------------------------

/// Per-container bookkeeping for [swrLoad].
class SwrState {
  /// Keys that already went through their first load this session.
  final Set<String> served = {};

  /// Fresh values waiting for the provider's next rebuild.
  final Map<String, Object> handoff = {};
}

final swrStateProvider = Provider<SwrState>((ref) => SwrState());

/// The body of a Home `FutureProvider`, with a persisted snapshot behind it.
///
/// - `key == null` (no account): plain [fetch].
/// - A value handed over by a finished background refresh: returned as is.
/// - First load of [key] this session with a usable snapshot: the snapshot
///   is returned now; [fetch] runs behind it, is persisted, and rebuilds the
///   provider once (via `invalidateSelf`) with the fresh value. A refresh
///   that comes back empty or throws leaves the snapshot on screen.
/// - Otherwise: [fetch], persisted when non-empty.
Future<T> swrLoad<T extends Object>(
  Ref ref, {
  required String? key,
  required SnapshotCodec<T> codec,
  required Future<T> Function() fetch,
  DateTime Function()? clock,
}) async {
  if (key == null) return fetch();
  final now = clock ?? DateTime.now;
  final state = ref.read(swrStateProvider);

  final handed = state.handoff.remove(key);
  if (handed is T) return handed;

  final db = ref.read(databaseProvider);

  void persist(T value) {
    if (codec.isEmpty(value)) return;
    try {
      db.kvSet(key, codec.encode(value, now()));
    } catch (_) {}
  }

  if (state.served.add(key)) {
    final cached = _readSnapshot(db, key, codec, now());
    if (cached != null) {
      var disposed = false;
      ref.onDispose(() => disposed = true);
      unawaited(() async {
        try {
          final fresh = await fetch();
          if (codec.isEmpty(fresh)) return;
          persist(fresh);
          if (disposed) return;
          state.handoff[key] = fresh;
          ref.invalidateSelf();
        } catch (_) {}
      }());
      return cached;
    }
  }

  final fresh = await fetch();
  persist(fresh);
  return fresh;
}

T? _readSnapshot<T>(
  AppDatabase db,
  String key,
  SnapshotCodec<T> codec,
  DateTime now,
) {
  String? raw;
  try {
    raw = db.kvGet(key);
  } catch (_) {}
  if (raw == null) return null;
  final decoded = codec.decode(raw);
  if (decoded == null) return null;
  if (codec.isEmpty(decoded.value)) return null;
  if (now.difference(decoded.savedAt) > homeSnapshotMaxAge) return null;
  return decoded.value;
}
