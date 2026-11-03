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
/// Snapshots live in the capped `snapshot_cache` table (see
/// [AppDatabase.cachePut]) under keys scoped to the account, so a different
/// Last.fm user or YouTube channel never sees someone else's picks.

/// Cache group (and cap) for Home snapshots.
const homeCacheGroup = 'home';

/// A snapshot older than this is not shown (the taste it encodes is stale
/// enough that the skeleton is the honest state).
const homeSnapshotMaxAge = Duration(days: 7);

const _feedKeyPrefix = 'home_feed_v1|';
const _shelvesKeyPrefix = 'home_yt_v1|';
const _version = 1;

/// Cache key for a Last.fm user's feed; null when there is no user.
String? homeFeedSnapshotKey(String username) {
  final u = username.trim().toLowerCase();
  return u.isEmpty ? null : '$_feedKeyPrefix$u';
}

/// Cache key for a YouTube Music identity (login + channel); null when
/// signed out.
String? homeShelvesSnapshotKey({
  required bool connected,
  required String profileEmail,
  required String activePageId,
}) {
  if (!connected) return null;
  return '$_shelvesKeyPrefix${profileEmail.trim().toLowerCase()}|$activePageId';
}

/// How one kind of cached data is stored.
class SnapshotCodec<T> {
  final String Function(T value) encode;

  /// Null when the payload is unreadable or from another version.
  final T? Function(String raw) decode;

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

String _encodeFeed(FeedData f) => jsonEncode({
      'v': _version,
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

FeedData? _decodeFeed(String raw) {
  try {
    final j = jsonDecode(raw);
    if (j is! Map || j['v'] != _version) return null;
    return FeedData(
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

String _encodeShelves(List<YtHomeShelf> shelves) => jsonEncode({
      'v': _version,
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

List<YtHomeShelf>? _decodeShelves(String raw) {
  try {
    final j = jsonDecode(raw);
    if (j is! Map || j['v'] != _version) return null;
    return [
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

/// The body of a `FutureProvider`, with a persisted snapshot behind it.
///
/// - `key == null` (no account): plain [fetch].
/// - A value handed over by a finished background refresh: returned as is.
/// - First load of [key] this session with a usable snapshot: the snapshot
///   is returned now; [fetch] runs behind it, is persisted, and rebuilds the
///   provider once (via `invalidateSelf`) with the fresh value. A refresh
///   that comes back empty or throws leaves the snapshot on screen.
/// - Otherwise: [fetch], persisted when non-empty.
///
/// [group] picks the cap in `snapshot_cache`; [maxAge] bounds how old a
/// snapshot may be and still be shown. [everyBuild] is for `autoDispose`
/// per-item pages (an album, a playlist): they forget everything on leave,
/// so every visit paints the saved copy, not only the first of the session.
/// Values whose encoding exceeds [maxChars] are not persisted, so one huge
/// playlist cannot crowd out the rest of its group.
Future<T> swrLoad<T extends Object>(
  Ref ref, {
  required String? key,
  required SnapshotCodec<T> codec,
  required Future<T> Function() fetch,
  String group = homeCacheGroup,
  Duration maxAge = homeSnapshotMaxAge,
  bool everyBuild = false,
  int maxChars = 1500000,
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
      final encoded = codec.encode(value);
      if (encoded.length > maxChars) return;
      db.cachePut(key, group, encoded, now: now());
    } catch (_) {}
  }

  if (state.served.add(key) || everyBuild) {
    final cached = readSnapshot(db, key, codec, now(), maxAge);
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

/// The stored value for [key], or null when absent, unreadable, empty or
/// older than [maxAge].
T? readSnapshot<T>(
  AppDatabase db,
  String key,
  SnapshotCodec<T> codec,
  DateTime now,
  Duration maxAge,
) {
  ({String value, DateTime savedAt})? row;
  try {
    row = db.cacheGet(key, now: now);
  } catch (_) {}
  if (row == null) return null;
  if (now.difference(row.savedAt) > maxAge) return null;
  final value = codec.decode(row.value);
  if (value == null || codec.isEmpty(value)) return null;
  return value;
}

// -- New releases, personal mix ------------------------------------------------

/// Cache key for the new-releases shelf. It is the authenticated browse
/// ("server-personalized" when signed in), so it is scoped to the YouTube
/// identity; signed out it is the public shelf.
String homeNewAlbumsSnapshotKey({
  required bool connected,
  required String profileEmail,
  required String activePageId,
}) =>
    connected
        ? 'home_albums_v1|${profileEmail.trim().toLowerCase()}|$activePageId'
        : 'home_albums_v1|public';

/// Cache key for the personal mix; null when signed out (no mix exists).
String? homePersonalMixSnapshotKey({
  required bool connected,
  required String profileEmail,
  required String activePageId,
}) =>
    connected
        ? 'home_mix_v1|${profileEmail.trim().toLowerCase()}|$activePageId'
        : null;

/// Cache key for the friends strip; null without a Last.fm user.
String? homeFriendsSnapshotKey(String username) {
  final u = username.trim().toLowerCase();
  return u.isEmpty ? null : 'home_friends_v1|$u';
}

final entitiesSnapshotCodec = SnapshotCodec<List<YouTubeMusicEntity>>(
  encode: (list) => jsonEncode({
    'v': _version,
    'items': list.map(_entityToJson).toList(),
  }),
  decode: (raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['v'] != _version) return null;
      return _listOf(j['items'], _entityFromJson);
    } catch (_) {
      return null;
    }
  },
  isEmpty: (list) => list.isEmpty,
);

typedef PersonalMixData = ({GeneratedTrack seed, List<GeneratedTrack> tracks});

/// Stand-in for "no mix": [swrLoad] needs a non-null value, the provider
/// maps this back to null.
const PersonalMixData noPersonalMix = (
  seed: GeneratedTrack(name: '', artist: ''),
  tracks: <GeneratedTrack>[],
);

final personalMixSnapshotCodec = SnapshotCodec<PersonalMixData>(
  encode: (m) => jsonEncode({
    'v': _version,
    'seed': _trackToJson(m.seed),
    'tracks': m.tracks.map(_trackToJson).toList(),
  }),
  decode: (raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['v'] != _version) return null;
      final seed = j['seed'];
      if (seed is! Map) return null;
      return (
        seed: _trackFromJson(seed.cast<String, dynamic>()),
        tracks: _tracksFrom(j['tracks']),
      );
    } catch (_) {
      return null;
    }
  },
  isEmpty: (m) => m.tracks.isEmpty,
);

// -- Library: track lists, playlists, albums -----------------------------------

Map<String, dynamic> generatedTrackToJson(GeneratedTrack t) => _trackToJson(t);
GeneratedTrack generatedTrackFromJson(Map<String, dynamic> j) =>
    _trackFromJson(j);

/// The part of a cache key that scopes data to a YouTube login + channel.
String ytIdentityKey(YtConnection c) =>
    '${c.profileEmail.trim().toLowerCase()}|${c.activePageId}';

/// Cache key for an account-scoped library list (`liked`, `history`,
/// `playlists`); null when signed out.
String? libraryCacheKey(String what, YtConnection c) =>
    c.connected ? 'lib_${what}_v1|${ytIdentityKey(c)}' : null;

/// One playlist's tracks. Scoped to the identity: private playlists differ
/// per account, and a shared key would show one account's list to another.
String? playlistCacheKey(String id, YtConnection c) =>
    id.isEmpty ? null : 'playlist_v1|${ytIdentityKey(c)}|$id';

/// Albums are public pages: one copy for everybody.
String? albumCacheKey(String browseId) =>
    browseId.isEmpty ? null : 'album_v1|$browseId';

const cacheGroupLibrary = 'library';
const cacheGroupPlaylist = 'playlist';
const cacheGroupAlbum = 'album';

/// Library lists change when you like or sync; a week-old copy is still the
/// right thing to paint while the real one loads.
const libraryCacheMaxAge = Duration(days: 30);

final ytTracksSnapshotCodec = SnapshotCodec<List<YouTubeMusicTrack>>(
  encode: (list) => jsonEncode({
    'v': _version,
    'items': list.map(_ytTrackToJson).toList(),
  }),
  decode: (raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['v'] != _version) return null;
      return _listOf(j['items'], _ytTrackFromJson);
    } catch (_) {
      return null;
    }
  },
  isEmpty: (list) => list.isEmpty,
);

final ytPlaylistSummariesSnapshotCodec =
    SnapshotCodec<List<YouTubePlaylistSummary>>(
  encode: (list) => jsonEncode({
    'v': _version,
    'items': [
      for (final p in list)
        {
          'id': p.id,
          't': p.title,
          'a': p.author,
          'c': p.trackCountText,
          'art': p.artworkUrl,
        },
    ],
  }),
  decode: (raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['v'] != _version) return null;
      return _listOf(
        j['items'],
        (m) => YouTubePlaylistSummary(
          id: m['id']?.toString() ?? '',
          title: m['t']?.toString() ?? '',
          author: m['a']?.toString() ?? '',
          trackCountText: m['c']?.toString() ?? '',
          artworkUrl: m['art']?.toString() ?? '',
        ),
      );
    } catch (_) {
      return null;
    }
  },
  isEmpty: (list) => list.isEmpty,
);

/// Stand-in for "playlist unavailable" ([swrLoad] needs a non-null value;
/// the provider maps it back to null).
const noPlaylistResult = YouTubePlaylistResult(id: '', title: '');

final ytPlaylistResultSnapshotCodec = SnapshotCodec<YouTubePlaylistResult>(
  encode: (p) => jsonEncode({
    'v': _version,
    'id': p.id,
    't': p.title,
    'a': p.author,
    'art': p.artworkUrl,
    'n': p.trackCount,
    'tracks': p.tracks.map(_ytTrackToJson).toList(),
  }),
  decode: (raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['v'] != _version) return null;
      return YouTubePlaylistResult(
        id: j['id']?.toString() ?? '',
        title: j['t']?.toString() ?? '',
        author: j['a']?.toString() ?? '',
        artworkUrl: j['art']?.toString() ?? '',
        trackCount: (j['n'] as num?)?.toInt() ?? 0,
        tracks: _listOf(j['tracks'], _ytTrackFromJson),
      );
    } catch (_) {
      return null;
    }
  },
  isEmpty: (p) => p.tracks.isEmpty,
);
