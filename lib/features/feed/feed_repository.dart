import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/artwork/official_artwork_service.dart';
import '../../core/network/lastfm_api.dart';
import '../../core/storage/app_database.dart';
import '../innertube/innertube_api.dart';
import '../innertube/yt_library_providers.dart';
import '../lastfm/auth_repository.dart';
import '../lastfm/home_repository.dart';
import '../search/shared_providers.dart';

/// A generated/recommended track (Last.fm metadata + YTM resolution).
class GeneratedTrack {
  final String name;
  final String artist;
  final String album;
  final String artworkUrl;
  final String videoId;
  final String listeners;
  final String match;
  final int durationSeconds;

  const GeneratedTrack({
    required this.name,
    required this.artist,
    this.album = '',
    this.artworkUrl = '',
    this.videoId = '',
    this.listeners = '',
    this.match = '',
    this.durationSeconds = 0,
  });

  String get key => '${name.toLowerCase()}|${artist.toLowerCase()}';
}

/// Personalised feed sections for the desktop home screen.
/// Mirrors LastWave-native `FeedRepository` section structure.
class FeedData {
  final List<GeneratedTrack> quickPicks;
  final List<GeneratedTrack> heavyRotation;
  final List<GeneratedTrack> freshFinds;
  final List<GeneratedTrack> jumpBackIn;
  final List<GeneratedTrack> becauseYouListened;
  final List<GeneratedTrack> charts;
  final List<String> tasteTags;

  /// Seed artist behind [becauseYouListened] ('' when the fallback
  /// pool was used). Rendered as "Because you listened to {seed}".
  final String becauseSeed;

  /// Normalized artist → raw affinity weight. Powers taste-ranked
  /// surfaces outside the feed (Discover new releases).
  final Map<String, double> tasteAffinities;

  const FeedData({
    this.quickPicks = const [],
    this.heavyRotation = const [],
    this.freshFinds = const [],
    this.jumpBackIn = const [],
    this.becauseYouListened = const [],
    this.charts = const [],
    this.tasteTags = const [],
    this.becauseSeed = '',
    this.tasteAffinities = const {},
  });

  bool get isEmpty =>
      quickPicks.isEmpty &&
      heavyRotation.isEmpty &&
      charts.isEmpty;
}

/// Day-boundary seed for the rotation RNG: same order all day
/// (stable, testable), fresh order tomorrow. See `loadFeed`.
int feedDaySeed(DateTime now) =>
    DateTime(now.year, now.month, now.day)
        .millisecondsSinceEpoch;

/// Canonical artist key for taste math: lowercase, collapsed space,
/// featured-credit suffixes stripped (`feat./ft./featuring/with` +
/// parenthesised variants), junk mapped to ''. Pure — unit tested.
///
/// Without this, "A feat. B", "a" and "A & C" split one artist's
/// weight and junk keys leak into taste tags.
String normalizeArtistKey(String artist) {
  var k = artist.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
  if (k.isEmpty ||
      k == 'unknown artist' ||
      k == 'various artists' ||
      k == 'unknown') {
    return '';
  }
  // Parenthesised credits: "Song (feat. X)" on artist fields, "[ft. X]".
  k = k
      .replaceAll(RegExp(r'\s*[\(\[]\s*(feat\.?|ft\.?|featuring)\b[^\)\]]*[\)\]]'), '')
      .trim();
  // Trailing credits: "A feat. B", "A ft B", "A featuring B", "A with B".
  k = k
      .replaceAll(
          RegExp(r'\s+(feat\.?|ft\.?|featuring|with)\s+.+$'), '')
      .trim();
  return k;
}

/// Drop banned tracks (exact `name|artist` key match). Pure — the
/// caller loads the set once per feed via `AppDatabase.loadExclusionKeys`.
List<GeneratedTrack> applyExclusions(
  List<GeneratedTrack> tracks,
  Set<String> excluded,
) {
  if (excluded.isEmpty) return tracks;
  return tracks.where((t) => !excluded.contains(t.key)).toList();
}

/// Rank global new releases by taste: known artists (normalized
/// affinity) first, everything else in original shelf order (explicit
/// index tiebreak — Dart sort is unstable). Pure — unit tested. Never
/// drops: unfamiliar records still browse below, just not ahead of
/// your artists.
List<YouTubeMusicEntity> rankNewReleases(
  List<YouTubeMusicEntity> albums,
  Map<String, double> affinities,
) {
  String artistOf(YouTubeMusicEntity a) =>
      a.artist.isNotEmpty ? a.artist : a.subtitle;
  final indexed = albums.asMap().entries.toList();
  indexed.sort((x, y) {
    final fa =
        affinities[normalizeArtistKey(artistOf(x.value))] ?? -1.0;
    final fb =
        affinities[normalizeArtistKey(artistOf(y.value))] ?? -1.0;
    final c = fb.compareTo(fa);
    if (c != 0) return c;
    return x.key.compareTo(y.key);
  });
  return indexed.map((e) => e.value).toList();
}

/// Score-ordered pick with per-artist caps and key dedupe. Pure —
/// extracted for unit tests. Pass one [sharedCounts] map across
/// sections (in priority order) to cap artists page-wide.
List<GeneratedTrack> diversifyFeedTracks(
  List<({GeneratedTrack track, double score})> scored, {
  int limit = 18,
  int maxPerArtist = 2,
  Map<String, int>? sharedCounts,
}) {
  scored.sort((a, b) => b.score.compareTo(a.score));
  final counts = sharedCounts ?? <String, int>{};
  final out = <GeneratedTrack>[];
  final seen = <String>{};
    for (final entry in scored) {
      if (out.length >= limit) break;
      if (!seen.add(entry.track.key)) continue;
      final artist = normalizeArtistKey(entry.track.artist);
      if (artist.isEmpty) continue;
      if ((counts[artist] ?? 0) >= maxPerArtist) continue;
      counts[artist] = (counts[artist] ?? 0) + 1;
      out.add(entry.track);
    }
    return out;
  }

/// Drop items headlined by earlier sections, then register this
/// list's heads. Pure — extracted for unit tests.
List<GeneratedTrack> dedupeFeedHeads(
  List<GeneratedTrack> list,
  Set<String> headlined, {
  int headN = 3,
}) {
  final out =
      list.where((t) => !headlined.contains(t.key)).toList();
  headlined.addAll(out.take(headN).map((t) => t.key));
  return out;
}

/// Generation + feed repository.
///
/// Ports the scoring/diversification behaviour of Android
/// `FeedRepository` / `GenerateRepository` / `RecommendationEngine`
/// in compact form:
/// - affinity-weighted blending of Last.fm signals + YTM radio/charts
/// - per-artist caps, jitter, cross-source deduplication
class FeedRepository {
  final LastFmApiService _api;
  final InnerTubeMusicApi _tube;
  final HomeRepository _home;
  final String Function() _apiKey;
  final Random _random = Random();

  /// Local database for recommendation exclusions (nullable in unit
  /// tests — exclusions are simply skipped without it).
  final AppDatabase? _db;

  /// YouTube Music account signals (liked songs, watch history).
  /// Closure-injected so tests stay offline; each resolves to [] when
  /// signed out or on failure.
  final Future<List<YouTubeMusicTrack>> Function()? fetchYtLiked;
  final Future<List<YouTubeMusicTrack>> Function()? fetchYtHistory;

  FeedRepository(this._api, this._tube, this._home, this._apiKey,
      {this._db,
      this.fetchYtLiked,
      this.fetchYtHistory});

  List<Map<String, dynamic>> _asList(Object? v) {
    if (v is List) return v.whereType<Map<String, dynamic>>().toList();
    if (v is Map<String, dynamic>) return [v];
    return const [];
  }

  double _affinity(String artist, Map<String, double> affinities) =>
      affinities[normalizeArtistKey(artist)] ?? 0.0;

  List<GeneratedTrack> _diversify(
    List<({GeneratedTrack track, double score})> scored, {
    int limit = 18,
    int maxPerArtist = 2,
    // Shared across sections so one artist can't own the whole page:
    // pass the same map to every section in priority order and caps
    // apply page-wide while each section still fills to its limit.
    Map<String, int>? sharedCounts,
  }) =>
      diversifyFeedTracks(
        scored,
        limit: limit,
        maxPerArtist: maxPerArtist,
        sharedCounts: sharedCounts,
      );

  /// Remove items whose key already headlined an earlier section, then
  /// register this list's heads. Applied heavy → quick → fresh →
  /// because so the hero/companions can never echo the grids (and
  /// vice versa). History (jumpBackIn) and global charts are exempt —
  /// they mirror reality, not taste.
  List<GeneratedTrack> _dedupeHeads(
    List<GeneratedTrack> list,
    Set<String> headlined, {
    int headN = 3,
  }) =>
      dedupeFeedHeads(list, headlined, headN: headN);

  void _addAffinity(
    Map<String, double> affinities,
    String artist,
    double weight,
  ) {
    final k = normalizeArtistKey(artist);
    if (k.isEmpty) return;
    affinities[k] = (affinities[k] ?? 0) + weight;
  }

  Future<Map<String, double>> _artistAffinities(
    List<HomeTrack> top,
    List<HomeTrack> recent, {
    List<HomeTrack> longTerm = const [],
    List<YouTubeMusicTrack> ytLiked = const [],
    List<YouTubeMusicTrack> ytHistory = const [],
  }) async {
    final affinities = <String, double>{};
    for (var i = 0; i < top.length; i++) {
      _addAffinity(
          affinities, top[i].artist, 1.45 / (1 + i / 9));
    }
    for (var i = 0; i < recent.length; i++) {
      _addAffinity(
          affinities, recent[i].artist, 0.48 / (1 + i / 12));
    }
    // Long-term anchor: a spike week can't rewrite years of taste.
    for (var i = 0; i < longTerm.length; i++) {
      _addAffinity(
          affinities, longTerm[i].artist, 0.8 / (1 + i / 15));
    }
    // YouTube account signals: liked outweighs recent scrobbles, watch
    // history sits below them. Both trail Last.fm top.
    for (var i = 0; i < ytLiked.length; i++) {
      _addAffinity(
          affinities, ytLiked[i].artist, 1.1 / (1 + i / 15));
    }
    for (var i = 0; i < ytHistory.length; i++) {
      _addAffinity(
          affinities, ytHistory[i].artist, 0.6 / (1 + i / 15));
    }
    return affinities;
  }

  Future<List<GeneratedTrack>> _similarTracks(
    String name,
    String artist, {
    int limit = 12,
  }) async {
    final ytmFuture = () async {
      final ytmOut = <GeneratedTrack>[];
      try {
        final seed = await _tube
            .findBestMatchOrNull(name, artist)
            .timeout(const Duration(seconds: 4));
        if (seed != null) {
          final related = await _tube
              .fetchRelatedSongs(seed.videoId, limit: limit)
              .timeout(const Duration(seconds: 4));
          ytmOut.addAll(related.map((t) => GeneratedTrack(
                name: t.title,
                artist: t.artist,
                artworkUrl: t.artworkUrl,
                videoId: t.videoId,
              )));
        }
      } catch (_) {}
      return ytmOut;
    }();

    final lfmFuture = () async {
      final lfmOut = <GeneratedTrack>[];
      try {
        final json = await _api.get({
          'method': 'track.getsimilar',
          'artist': artist,
          'track': name,
          'api_key': _apiKey(),
          'limit': '20',
          'autocorrect': '1',
        }).timeout(const Duration(seconds: 4));
        final similars = _asList(
            (json['similartracks'] as Map?)?['track']);
        for (final s in similars) {
          final n = s['name']?.toString() ?? '';
          final a = (s['artist'] as Map?)?['name']?.toString() ??
              s['artist']?.toString() ??
              '';
          if (n.isEmpty || a.isEmpty) continue;
          lfmOut.add(GeneratedTrack(
            name: n,
            artist: a,
            match: s['match']?.toString() ?? '',
          ));
        }
      } catch (_) {}
      return lfmOut;
    }();

    final results = await Future.wait([ytmFuture, lfmFuture]);
    return [...results[0], ...results[1]];
  }

  /// Resolve YTM videoIds for tracks missing them (bounded parallelism
  /// + per-item timeout + overall deadline returning partial results:
  /// an unresolved track keeps playing via search fallback, so stalls
  /// degrade instead of hanging Mix Lab forever).
  Future<List<GeneratedTrack>> resolveVideos(
    List<GeneratedTrack> tracks, {
    int limit = 30,
    Duration itemTimeout = const Duration(seconds: 10),
    Duration totalTimeout = const Duration(seconds: 40),
  }) async {
    final out = <GeneratedTrack>[];
    final queue = tracks.take(limit).toList();
    const batch = 4;
    Future<void> run() async {
      for (var i = 0; i < queue.length; i += batch) {
        final slice = queue.skip(i).take(batch).toList();
        final resolved = await Future.wait(slice.map((t) async {
          if (t.videoId.isNotEmpty) return t;
          try {
            final match = await _tube
                .findBestMatchOrNull(t.name, t.artist)
                .timeout(itemTimeout, onTimeout: () => null);
            if (match == null) return t;
            return GeneratedTrack(
              name: t.name,
              artist: t.artist,
              album: t.album.isNotEmpty ? t.album : match.album,
              artworkUrl: t.artworkUrl.isNotEmpty
                  ? t.artworkUrl
                  : match.artworkUrl,
              videoId: match.videoId,
              listeners: t.listeners,
              match: t.match,
              durationSeconds: t.durationSeconds > 0
                  ? t.durationSeconds
                  : match.durationSeconds,
            );
          } catch (_) {
            return t;
          }
        }));
        out.addAll(resolved);
      }
    }

    try {
      await run().timeout(totalTimeout);
    } catch (_) {}
    return out;
  }

  /// Fill album/duration from a YouTube Music search when Last.fm omitted them.
  /// Never copies a videoId — a weak search hit here was playing the wrong song.
  Future<GeneratedTrack> fillMissingMetadata(GeneratedTrack t) async {
    if (t.durationSeconds > 0 && t.album.isNotEmpty) return t;
    try {
      final songs = await _tube.searchSongs(
        '${t.name} ${t.artist}',
        limit: 8,
      );
      YouTubeMusicTrack? hit;
      var best = -1;
      for (final s in songs) {
        final titleSim = InnerTubeMusicApi.similarity(
                InnerTubeMusicApi.baseTitle(s.title),
                InnerTubeMusicApi.baseTitle(t.name));
        if (titleSim < 85) continue;
        if (t.artist.isNotEmpty &&
            InnerTubeMusicApi.similarity(s.artist, t.artist) < 50) {
          continue;
        }
        if (titleSim > best) {
          best = titleSim;
          hit = s;
        }
      }
      if (hit == null) return t;
      return GeneratedTrack(
        name: t.name,
        artist: t.artist,
        album: t.album.isNotEmpty ? t.album : hit.album,
        artworkUrl:
            t.artworkUrl.isNotEmpty ? t.artworkUrl : hit.artworkUrl,
        videoId: t.videoId,
        listeners: t.listeners,
        match: t.match,
        durationSeconds: t.durationSeconds > 0
            ? t.durationSeconds
            : hit.durationSeconds,
      );
    } catch (_) {
      return t;
    }
  }

  /// New-release records (real albums/singles, no video items).
  Future<List<YouTubeMusicEntity>> fetchNewReleaseAlbums(
      {int limit = 15}) async {
    try {
      return await _tube.browseAlbums(
        'FEmusic_new_releases',
        limit: limit,
      );
    } catch (_) {
      return const [];
    }
  }

  /// Resolve an album entity to playable tracks.
  Future<List<GeneratedTrack>> albumTracks(
      YouTubeMusicEntity album) async {
    if (album.browseId.isEmpty) return const [];
    try {
      final songs = await _tube.browseSongs(
        album.browseId,
        limit: 50,
      );
      final parts =
          InnerTubeMusicApi.splitSubtitle(album.subtitle);
      final artist =
          parts.length > 1 ? parts[1] : album.artist;
      return songs
          .map((t) => GeneratedTrack(
                name: t.title,
                artist: t.artist.isNotEmpty
                    ? t.artist
                    : artist,
                artworkUrl: t.artworkUrl.isNotEmpty
                    ? t.artworkUrl
                    : album.artworkUrl,
                videoId: t.videoId,
                album: t.album.isNotEmpty ? t.album : album.name,
                durationSeconds: t.durationSeconds,
              ))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<FeedData> loadFeed({bool chartsOnly = false}) async {
    try {
      Future<List<YouTubeMusicTrack>> cappedYt(
        Future<List<YouTubeMusicTrack>> Function()? fetch,
        int take,
      ) async {
        if (fetch == null) return const [];
        try {
          final list = await fetch()
              .timeout(const Duration(seconds: 12));
          return list.take(take).toList();
        } catch (_) {
          return const [];
        }
      }

      final results = await Future.wait([
        _home.fetchRecentTracks(limit: 30),
        _home.fetchTopTracks(period: '7day', limit: 30),
        _tube.browseSongs('FEmusic_charts', limit: 30).catchError((_) => <YouTubeMusicTrack>[]),
        _home
            .fetchTopTracks(period: '12month', limit: 30)
            .catchError((_) => <HomeTrack>[]),
        cappedYt(fetchYtLiked, 60),
        cappedYt(fetchYtHistory, 60),
      ]);
      final recent = results[0] as List<HomeTrack>;
      final top = results[1] as List<HomeTrack>;
      final charts = results[2] as List<YouTubeMusicTrack>;
      final longTerm = results[3] as List<HomeTrack>;
      final ytLiked = results[4] as List<YouTubeMusicTrack>;
      final ytHistory = results[5] as List<YouTubeMusicTrack>;
      final affinities = await _artistAffinities(
        top,
        recent,
        longTerm: longTerm,
        ytLiked: ytLiked,
        ytHistory: ytHistory,
      );
      // Banned tracks never surface, in any section.
      final excluded = _db?.loadExclusionKeys() ?? const <String>{};

      // Daily rotation salt: same order all day (stable, testable),
      // fresh order tomorrow. The old unseeded ±8 jitter could never
      // cross affinity gaps, so every boot rendered the same heads
      // until new scrobbles arrived.
      final rotation = Random(feedDaySeed(DateTime.now()));
      // Normalized affinity keeps every term comparable: affinity
      // 0–50, position 0–60 by boost, playback bonus ±, jitter 0–12.
      // Previously affinity×60 (0–300pts) buried the boost terms.
      final maxAffinity = affinities.values.fold<double>(
          0, (m, v) => v > m ? v : m);
      double normAffinity(String artist) =>
          maxAffinity <= 0 ? 0 : _affinity(artist, affinities) / maxAffinity;

      GeneratedTrack fromHome(HomeTrack t) => GeneratedTrack(
            name: t.name,
            artist: t.artist,
            artworkUrl: t.artworkUrl,
          );
      GeneratedTrack fromYt(YouTubeMusicTrack t) => GeneratedTrack(
            name: t.title,
            artist: t.artist,
            artworkUrl: t.artworkUrl,
            videoId: t.videoId,
          );

      List<GeneratedTrack> clean(List<GeneratedTrack> tracks) =>
          applyExclusions(tracks, excluded);

      List<({GeneratedTrack track, double score})> score(
        List<GeneratedTrack> tracks,
        double boost,
      ) {
        return [
          for (var i = 0; i < tracks.length; i++)
            (
              track: tracks[i],
              score: normAffinity(tracks[i].artist) * 50 +
                  boost * 20 / (1 + i / 9) +
                  (tracks[i].videoId.isNotEmpty ? 4 : -2) +
                  rotation.nextDouble() * 12,
            ),
        ];
      }

      // One shared cap map in priority order: an artist topping the
      // charts can't also own every grid below.
      final pageCounts = <String, int>{};
      final heavy = _diversify(
        score(clean(top.take(25).map(fromHome).toList()), 3.0),
        limit: 15,
        maxPerArtist: 2,
        sharedCounts: pageCounts,
      );
      final quick = _diversify(
        [
          ...score(clean(top.take(15).map(fromHome).toList()), 2.6),
          ...score(
              clean(recent.take(15).map(fromHome).toList()), 1.6),
          ...score(clean(charts.take(15).map(fromYt).toList()), 1.2),
        ],
        limit: 18,
        sharedCounts: pageCounts,
      );

      // Discovery: expand distinct seed artists via similar tracks.
      // Seeds skip banned tracks — a ban means "not this", so its
      // neighborhood shouldn't seed either.
      bool banned(HomeTrack t) =>
          excluded.contains(AppDatabase.exclusionKey(t.name, t.artist));
      final seeds = <HomeTrack>[];
      final seenArtists = <String>{};
      for (final t in [...top, ...recent]) {
        if (banned(t)) continue;
        final k = normalizeArtistKey(t.artist);
        if (k.isEmpty || !seenArtists.add(k)) continue;
        seeds.add(t);
        if (seeds.length >= 4) break;
      }
      final discovery = <GeneratedTrack>[];
      final discoveryBatches = await Future.wait(
        seeds.map(
          (seed) => _similarTracks(seed.name, seed.artist, limit: 8)
              .timeout(const Duration(seconds: 4), onTimeout: () => []),
        ),
      );
      for (final batch in discoveryBatches) {
        discovery.addAll(batch);
      }
      final fresh = _diversify(
        score(applyExclusions(discovery, excluded), 2.0),
        limit: 12,
        maxPerArtist: 1,
        sharedCounts: pageCounts,
      );

      final jumpBack = _diversify(
        score(
            recent
                .where((t) => !banned(t))
                .take(20)
                .map(fromHome)
                .toList(),
            2.0),
        limit: 12,
      );

      // Because You Listened, honestly: the batch whose seed carries
      // the strongest affinity wins, and its artist names the section.
      // Falls back to the old reversed-pool mix when seeds starve.
      String becauseSeed = '';
      List<GeneratedTrack> becausePool = const [];
      var seeded = false;
      if (seeds.isNotEmpty) {
        var best = -1.0;
        var bestBatch = -1;
        for (var b = 0; b < seeds.length && b < discoveryBatches.length; b++) {
          final aff = normAffinity(seeds[b].artist);
          if (aff > best) {
            best = aff;
            bestBatch = b;
          }
        }
        if (bestBatch >= 0 &&
            discoveryBatches[bestBatch].isNotEmpty) {
          becausePool = discoveryBatches[bestBatch];
          becauseSeed = seeds[bestBatch].artist;
          seeded = true;
        }
      }
      if (!seeded) {
        becausePool = discovery.reversed.take(20).toList();
        becauseSeed = '';
      }
      final because = _diversify(
        score(applyExclusions(becausePool, excluded), 2.2),
        limit: 12,
        maxPerArtist: 1,
        sharedCounts: pageCounts,
      );

      // Cross-section heads: the hero, companions and every grid head
      // must be distinct tracks — previously heavy[0] == quick[0]
      // rendered the same song 3–4 times per page (hero + up-next +
      // grid). History and global charts are exempt (mirrors, not picks).
      final headlined = <String>{};
      final dedupedHeavy = _dedupeHeads(heavy, headlined);
      final dedupedQuick = _dedupeHeads(quick, headlined);
      final dedupedFresh = _dedupeHeads(fresh, headlined);
      final dedupedBecause = _dedupeHeads(because, headlined);

      // Parallel per-track hydration: the sequential loop paid up to
      // 1.5s per missing cover (8 × 1.5s worst case inside a 3s cap,
      // so slow items starved the rest). OfficialArtworkService
      // throttles internally (concurrency 3), so fan-out is safe and
      // order is preserved by Future.wait.
      Future<GeneratedTrack> hydrateOne(
          int i, GeneratedTrack t, int limit) async {
        if (i < limit && t.artworkUrl.isEmpty && t.name.isNotEmpty) {
          try {
            final art = await OfficialArtworkService.instance
                .resolveOfficialArtwork(title: t.name, artist: t.artist)
                .timeout(const Duration(milliseconds: 1500));
            if (art != null && art.artworkUrl.isNotEmpty) {
              return GeneratedTrack(
                name: t.name,
                artist: t.artist,
                artworkUrl: art.artworkUrl,
                videoId: t.videoId,
                listeners: t.listeners,
                match: t.match,
              );
            }
          } catch (_) {}
        }
        return t;
      }

      Future<List<GeneratedTrack>> hydrateArtwork(
          List<GeneratedTrack> list, {int limit = 6}) async {
        return Future.wait([
          for (var i = 0; i < list.length; i++)
            hydrateOne(i, list[i], limit),
        ]);
      }

      var finalQuick = dedupedQuick;
      var finalJump = jumpBack;
      if (!chartsOnly) {
        try {
          final hydrated = await Future.wait([
            hydrateArtwork(dedupedQuick, limit: 8),
            hydrateArtwork(jumpBack, limit: 4),
          ]).timeout(const Duration(seconds: 3));
          finalQuick = hydrated[0];
          finalJump = hydrated[1];
        } catch (_) {}
      }

      return FeedData(
        quickPicks: chartsOnly ? const [] : finalQuick,
        heavyRotation: chartsOnly ? const [] : dedupedHeavy,
        freshFinds: chartsOnly ? const [] : dedupedFresh,
        jumpBackIn: chartsOnly ? const [] : finalJump,
        becauseYouListened: chartsOnly ? const [] : dedupedBecause,
        becauseSeed: becauseSeed,
        charts: applyExclusions(
            charts.take(15).map(fromYt).toList(), excluded),
        tasteTags: affinities.keys.take(8).toList(),
        tasteAffinities: affinities,
      );
    } catch (_) {
      // Guest/offline fallback: charts only.
      try {
        final charts =
            await _tube.browseSongs('FEmusic_charts', limit: 15);
        return FeedData(
          charts: charts
              .map((t) => GeneratedTrack(
                    name: t.title,
                    artist: t.artist,
                    artworkUrl: t.artworkUrl,
                    videoId: t.videoId,
                  ))
              .toList(),
        );
      } catch (_) {
        return const FeedData();
      }
    }
  }

  /// Personal mix from YouTube Music taste: seed from YT history
  /// (current taste first) then YT liked, picked with the daily
  /// rotation salt, expanded via YTM radio. Returns the seed plus the
  /// radio list, or null when signed out / empty / stalled — callers
  /// fall back to the Last.fm hero. All network legs are capped.
  Future<({GeneratedTrack seed, List<GeneratedTrack> tracks})?>
      fetchPersonalMix({int limit = 20}) async {
    try {
      Future<List<YouTubeMusicTrack>> cappedYt(
        Future<List<YouTubeMusicTrack>> Function()? fetch,
        int take,
      ) async {
        if (fetch == null) return const [];
        try {
          final list = await fetch()
              .timeout(const Duration(seconds: 12));
          return list.take(take).toList();
        } catch (_) {
          return const [];
        }
      }

      final liked = await cappedYt(fetchYtLiked, 40);
      final history = await cappedYt(fetchYtHistory, 40);
      final pool = <YouTubeMusicTrack>[];
      final seen = <String>{};
      for (final t in [...history, ...liked]) {
        final key =
            '${t.title.toLowerCase()}|${t.artist.toLowerCase()}';
        if (t.title.isEmpty || !seen.add(key)) continue;
        pool.add(t);
      }
      if (pool.isEmpty) return null;
      final rotation = Random(feedDaySeed(DateTime.now()));
      final seed = pool[rotation.nextInt(pool.length)];
      var seedId = seed.videoId;
      if (seedId.isEmpty) {
        final match = await _tube
            .findBestMatchOrNull(seed.title, seed.artist)
            .timeout(const Duration(seconds: 8),
                onTimeout: () => null);
        seedId = match?.videoId ?? '';
      }
      if (seedId.isEmpty) return null;
      final radio = await _tube
          .fetchRelatedSongs(seedId, limit: limit + 5)
          .timeout(const Duration(seconds: 8));
      final tracks = <GeneratedTrack>[];
      final trackSeen = {
        '${seed.title.toLowerCase()}|${seed.artist.toLowerCase()}'
      };
      for (final t in radio) {
        final key =
            '${t.title.toLowerCase()}|${t.artist.toLowerCase()}';
        if (t.title.isEmpty || !trackSeen.add(key)) continue;
        tracks.add(GeneratedTrack(
          name: t.title,
          artist: t.artist,
          artworkUrl: t.artworkUrl,
          videoId: t.videoId,
        ));
        if (tracks.length >= limit) break;
      }
      if (tracks.isEmpty) return null;
      return (
        seed: GeneratedTrack(
          name: seed.title,
          artist: seed.artist,
          artworkUrl: seed.artworkUrl,
          videoId: seedId,
        ),
        tracks: tracks,
      );
    } catch (_) {
      return null;
    }
  }

  /// Generate a 30–35 track mood mix from taste signals.
  /// Mirrors `GenerateRepository.fetchMix` bucket weighting.
  Future<List<GeneratedTrack>> fetchMix({int total = 32}) async {
    final recent = await _home
        .fetchRecentTracks(limit: 20)
        .catchError((_) => <HomeTrack>[]);
    final top = await _home
        .fetchTopTracks(limit: 20)
        .catchError((_) => <HomeTrack>[]);
    final excluded = _db?.loadExclusionKeys() ?? const <String>{};
    bool banned(HomeTrack t) =>
        excluded.contains(AppDatabase.exclusionKey(t.name, t.artist));
    final poolSeeds = [
      ...recent.where((t) => !banned(t)).take(3),
      ...top.where((t) => !banned(t)).take(3),
    ];
    final pooledBatches = await Future.wait(
      poolSeeds.map(
        (t) => _similarTracks(t.name, t.artist)
            .timeout(const Duration(seconds: 8),
                onTimeout: () => <GeneratedTrack>[])
            .catchError((_) => <GeneratedTrack>[]),
      ),
    );
    final pooled = <GeneratedTrack>[
      for (final batch in pooledBatches) ...batch,
    ];
    if (pooled.isEmpty) {
      final charts =
          await _tube.browseSongs('FEmusic_charts', limit: total);
      return charts
          .map((t) => GeneratedTrack(
                name: t.title,
                artist: t.artist,
                artworkUrl: t.artworkUrl,
                videoId: t.videoId,
              ))
          .toList();
    }
    final longTerm = await _home
        .fetchTopTracks(period: '12month', limit: 20)
        .catchError((_) => <HomeTrack>[]);
    final affinities = await _artistAffinities(top, recent,
        longTerm: longTerm);
    final scored = pooled
        .map((t) => (
              track: t,
              score: _affinity(t.artist, affinities) * 30 +
                  _random.nextDouble() * 10,
            ))
        .toList();
    final picked =
        applyExclusions(_diversify(scored, limit: total, maxPerArtist: 2), excluded);
    return resolveVideos(picked, limit: total);
  }
}

final feedRepositoryProvider = Provider<FeedRepository>((ref) {
  return FeedRepository(
    ref.watch(lastFmApiProvider),
    ref.watch(innerTubeProvider),
    ref.watch(homeRepositoryProvider),
    () => ref.watch(prefsApiKeyProvider),
    db: ref.watch(databaseProvider),
    fetchYtLiked: () =>
        ref.watch(ytLikedSongsProvider.future).catchError(
              (_) => const <YouTubeMusicTrack>[],
            ),
    fetchYtHistory: () =>
        ref.watch(ytHistoryProvider.future).catchError(
              (_) => const <YouTubeMusicTrack>[],
            ),
  );
});
