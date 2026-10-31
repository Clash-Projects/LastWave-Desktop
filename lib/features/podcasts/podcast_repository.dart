import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/app_database.dart';
import '../../core/storage/prefs.dart';
import '../feed/feed_repository.dart';
import '../innertube/innertube_api.dart';
import '../player/playback_service.dart';
import '../search/shared_providers.dart';
import 'podcast_models.dart';

class PodcastRepository {
  final InnerTubeMusicApi _tube;
  final AppDatabase _db;
  final bool Function() _enabled;

  List<PodcastShelf>? _home;
  DateTime? _homeAt;
  final Map<String, PodcastShowPage> _shows = {};

  PodcastRepository(this._tube, this._db, this._enabled);

  bool get enabled => _enabled();

  Future<List<PodcastShelf>> home({bool force = false}) async {
    if (!enabled) return const [];
    final cached = _home;
    if (!force &&
        cached != null &&
        _homeAt != null &&
        DateTime.now().difference(_homeAt!) < const Duration(minutes: 10)) {
      return cached;
    }
    final shelves = await _tube.fetchPodcastHome();
    if (shelves.isNotEmpty) {
      _home = shelves;
      _homeAt = DateTime.now();
    }
    return shelves;
  }

  Future<PodcastShowPage?> show(String showId, {bool force = false}) async {
    if (!enabled || showId.trim().isEmpty) return null;
    if (!force && _shows.containsKey(showId)) return _shows[showId];
    final page = await _tube.fetchPodcastShow(showId);
    if (page != null) _shows[showId] = page;
    return page;
  }

  Future<PodcastEpisodePage> more(String showId, String? continuation) async {
    if (!enabled || continuation == null || continuation.isEmpty) {
      return const PodcastEpisodePage();
    }
    final page = await _tube.fetchPodcastShowContinuation(
      showId,
      continuation,
      showTitle: _shows[showId]?.show.title,
    );
    final current = _shows[showId];
    if (current != null && page.episodes.isNotEmpty) {
      final seen = current.episodes.map((e) => e.videoId).toSet();
      _shows[showId] = PodcastShowPage(
        show: current.show,
        episodes: [
          ...current.episodes,
          for (final episode in page.episodes)
            if (seen.add(episode.videoId)) episode,
        ],
        continuation: page.continuation,
      );
    }
    return page;
  }

  Future<List<PodcastEpisode>> search(String query) async {
    if (!enabled || query.trim().isEmpty) return const [];
    return _tube.searchPodcastEpisodes(query);
  }

  void remember(PodcastEpisode episode) {
    _db.upsertPodcastProgress(
      videoId: episode.videoId,
      showId: episode.showId,
      showTitle: episode.showTitle,
      title: episode.title,
      durationMs: episode.durationMs,
    );
  }

  int resumeMs(String videoId) => _db.podcastResumeMs(videoId);

  Map<String, PodcastProgressRow> progressFor(Iterable<String> videoIds) =>
      _db.podcastProgressFor(videoIds);
}

final podcastRepositoryProvider = Provider<PodcastRepository>((ref) {
  return PodcastRepository(
    ref.watch(innerTubeProvider),
    ref.watch(databaseProvider),
    () => ref.watch(prefsProvider).podcastsEnabled,
  );
});

final podcastHomeProvider =
    FutureProvider.autoDispose<List<PodcastShelf>>((ref) async {
  if (!ref.watch(prefsProvider).podcastsEnabled) return const [];
  return ref.watch(podcastRepositoryProvider).home();
});

final podcastSearchProvider = FutureProvider.autoDispose
    .family<List<PodcastEpisode>, String>((ref, query) async {
  if (!ref.watch(prefsProvider).podcastsEnabled) return const [];
  if (query.trim().isEmpty) return const [];
  return ref.watch(podcastRepositoryProvider).search(query);
});

final podcastShowProvider =
    FutureProvider.autoDispose.family<PodcastShowPage?, String>((ref, showId) {
  if (!ref.watch(prefsProvider).podcastsEnabled) return Future.value(null);
  return ref.watch(podcastRepositoryProvider).show(showId);
});

GeneratedTrack trackFromEpisode(PodcastEpisode episode) {
  final show = episode.showTitle.trim();
  return GeneratedTrack(
    name: episode.title,
    artist: show.isNotEmpty ? show : 'Podcast',
    artworkUrl: episode.artworkUrl,
    videoId: episode.videoId,
    durationSeconds: episode.durationMs <= 0
        ? 0
        : (episode.durationMs / 1000).round(),
  );
}

/// Remembers podcast episodes and writes the playhead while one is current.
///
/// Resume seeks once per video id when playback starts near zero and a
/// saved position exists. Ordinary songs are ignored because they have no
/// podcast_progress row.
final podcastProgressCoordinatorProvider = Provider<void>((ref) {
  var seekedFor = '';
  var lastWrite = 0;
  var lastVideo = '';
  ref.listen(playbackServiceProvider, (prev, next) {
    final track = next.current;
    if (track == null) return;
    final id = track.videoId;
    if (id.isEmpty) return;
    final db = ref.read(databaseProvider);
    final row = db.podcastProgress(id);
    if (row == null) return;
    final resume = db.podcastResumeMs(id);
    if (seekedFor != id &&
        next.isPlaying &&
        next.position < const Duration(seconds: 2) &&
        resume > 8000) {
      seekedFor = id;
      ref
          .read(playbackServiceProvider.notifier)
          .seek(Duration(milliseconds: resume));
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final paused = prev?.isPlaying == true && !next.isPlaying;
    if (!paused && now - lastWrite < 5000 && lastVideo == id) return;
    lastWrite = now;
    lastVideo = id;
    final durationMs = next.duration.inMilliseconds > 0
        ? next.duration.inMilliseconds
        : row.durationMs;
    db.savePodcastPosition(
      videoId: id,
      positionMs: next.position.inMilliseconds,
      durationMs: durationMs,
    );
  });
});
