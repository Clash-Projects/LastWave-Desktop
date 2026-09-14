import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/lastfm_api.dart';
import '../innertube/innertube_api.dart';
import '../lastfm/auth_repository.dart';
import '../lastfm/home_repository.dart';
import '../search/shared_providers.dart';

/// A generated/recommended track (Last.fm metadata + YTM resolution).
class GeneratedTrack {
  final String name;
  final String artist;
  final String artworkUrl;
  final String videoId;
  final String listeners;
  final String match;

  const GeneratedTrack({
    required this.name,
    required this.artist,
    this.artworkUrl = '',
    this.videoId = '',
    this.listeners = '',
    this.match = '',
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

  const FeedData({
    this.quickPicks = const [],
    this.heavyRotation = const [],
    this.freshFinds = const [],
    this.jumpBackIn = const [],
    this.becauseYouListened = const [],
    this.charts = const [],
    this.tasteTags = const [],
  });

  bool get isEmpty =>
      quickPicks.isEmpty &&
      heavyRotation.isEmpty &&
      charts.isEmpty;
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

  FeedRepository(this._api, this._tube, this._home, this._apiKey);

  List<Map<String, dynamic>> _asList(Object? v) {
    if (v is List) return v.whereType<Map<String, dynamic>>().toList();
    if (v is Map<String, dynamic>) return [v];
    return const [];
  }

  double _affinity(String artist, Map<String, double> affinities) =>
      affinities[artist.toLowerCase()] ?? 0.0;

  List<GeneratedTrack> _diversify(
    List<({GeneratedTrack track, double score})> scored, {
    int limit = 18,
    int maxPerArtist = 2,
  }) {
    scored.sort((a, b) => b.score.compareTo(a.score));
    final counts = <String, int>{};
    final out = <GeneratedTrack>[];
    final seen = <String>{};
    for (final entry in scored) {
      if (out.length >= limit) break;
      if (!seen.add(entry.track.key)) continue;
      final artist = entry.track.artist.toLowerCase();
      if ((counts[artist] ?? 0) >= maxPerArtist) continue;
      counts[artist] = (counts[artist] ?? 0) + 1;
      out.add(entry.track);
    }
    return out;
  }

  Future<Map<String, double>> _artistAffinities(
      List<HomeTrack> top, List<HomeTrack> recent) async {
    final affinities = <String, double>{};
    for (var i = 0; i < top.length; i++) {
      final k = top[i].artist.toLowerCase();
      affinities[k] = (affinities[k] ?? 0) + 1.45 / (1 + i / 9);
    }
    for (var i = 0; i < recent.length; i++) {
      final k = recent[i].artist.toLowerCase();
      affinities[k] = (affinities[k] ?? 0) + 0.48 / (1 + i / 12);
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

  /// Resolve YTM videoIds for tracks missing them (bounded parallelism).
  Future<List<GeneratedTrack>> resolveVideos(
    List<GeneratedTrack> tracks, {
    int limit = 30,
  }) async {
    final out = <GeneratedTrack>[];
    final queue = tracks.take(limit).toList();
    const batch = 4;
    for (var i = 0; i < queue.length; i += batch) {
      final slice = queue.skip(i).take(batch);
      final resolved = await Future.wait(slice.map((t) async {
        if (t.videoId.isNotEmpty) return t;
        try {
          final match =
              await _tube.findBestMatchOrNull(t.name, t.artist);
          if (match == null) return t;
          return GeneratedTrack(
            name: t.name,
            artist: t.artist,
            artworkUrl: t.artworkUrl.isNotEmpty
                ? t.artworkUrl
                : match.artworkUrl,
            videoId: match.videoId,
            listeners: t.listeners,
            match: t.match,
          );
        } catch (_) {
          return t;
        }
      }));
      out.addAll(resolved);
    }
    return out;
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
              ))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<FeedData> loadFeed({bool chartsOnly = false}) async {
    try {
      final results = await Future.wait([
        _home.fetchRecentTracks(limit: 30),
        _home.fetchTopTracks(period: '7day', limit: 30),
        _tube.browseSongs('FEmusic_charts', limit: 30).catchError((_) => <YouTubeMusicTrack>[]),
      ]);
      final recent = results[0] as List<HomeTrack>;
      final top = results[1] as List<HomeTrack>;
      final charts = results[2] as List<YouTubeMusicTrack>;
      final affinities = await _artistAffinities(top, recent);

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

      List<({GeneratedTrack track, double score})> score(
        List<GeneratedTrack> tracks,
        double boost,
      ) {
        return [
          for (var i = 0; i < tracks.length; i++)
            (
              track: tracks[i],
              score: _affinity(tracks[i].artist, affinities) * 60 +
                  boost * 14 / (1 + i / 9) +
                  (tracks[i].videoId.isNotEmpty ? 10 : -6) +
                  _random.nextDouble() * 8,
            ),
        ];
      }

      final quick = _diversify(
        [
          ...score(top.take(15).map(fromHome).toList(), 2.6),
          ...score(recent.take(15).map(fromHome).toList(), 1.6),
          ...score(charts.take(15).map(fromYt).toList(), 1.2),
        ],
        limit: 18,
      );
      final heavy = _diversify(
        score(top.take(25).map(fromHome).toList(), 3.0),
        limit: 15,
        maxPerArtist: 3,
      );

      // Discovery: expand 3 distinct seed artists via similar tracks.
      final seeds = <HomeTrack>[];
      final seenArtists = <String>{};
      for (final t in [...top, ...recent]) {
        if (seenArtists.add(t.artist.toLowerCase())) seeds.add(t);
        if (seeds.length >= 3) break;
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
        score(discovery, 2.0),
        limit: 12,
        maxPerArtist: 1,
      );

      final jumpBack = _diversify(
        score(recent.take(20).map(fromHome).toList(), 2.0),
        limit: 12,
      );

      final because = _diversify(
        score(discovery.reversed.take(20).toList(), 2.2),
        limit: 12,
      );

      return FeedData(
        quickPicks: chartsOnly ? const [] : quick,
        heavyRotation: chartsOnly ? const [] : heavy,
        freshFinds: chartsOnly ? const [] : fresh,
        jumpBackIn: chartsOnly ? const [] : jumpBack,
        becauseYouListened: chartsOnly ? const [] : because,
        charts: charts.take(15).map(fromYt).toList(),
        tasteTags: affinities.keys.take(8).toList(),
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

  /// Generate a 30–35 track mood mix from taste signals.
  /// Mirrors `GenerateRepository.fetchMix` bucket weighting.
  Future<List<GeneratedTrack>> fetchMix({int total = 32}) async {
    final recent = await _home
        .fetchRecentTracks(limit: 20)
        .catchError((_) => <HomeTrack>[]);
    final top = await _home
        .fetchTopTracks(limit: 20)
        .catchError((_) => <HomeTrack>[]);
    final poolSeeds = [...recent.take(3), ...top.take(3)];
    final pooledBatches = await Future.wait(
      poolSeeds.map(
        (t) => _similarTracks(t.name, t.artist)
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
    final affinities = await _artistAffinities(top, recent);
    final scored = pooled
        .map((t) => (
              track: t,
              score: _affinity(t.artist, affinities) * 30 +
                  _random.nextDouble() * 10,
            ))
        .toList();
    final picked = _diversify(scored, limit: total, maxPerArtist: 2);
    return resolveVideos(picked, limit: total);
  }
}

final feedRepositoryProvider = Provider<FeedRepository>((ref) {
  return FeedRepository(
    ref.watch(lastFmApiProvider),
    ref.watch(innerTubeProvider),
    ref.watch(homeRepositoryProvider),
    () => ref.watch(prefsApiKeyProvider),
  );
});
