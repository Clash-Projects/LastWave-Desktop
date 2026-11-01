import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/storage/prefs.dart';
import '../innertube/innertube_api.dart';
import 'audio_alignment.dart';
import 'pcm_capture.dart';
import 'video_match.dart';

/// A resolved official music video: its id and every playable height.
class SyncedVideoBundle {
  final String videoId;
  final List<MusicVideoStream> streams;

  /// Intro the community marked as non-music (SponsorBlock), 0 if none.
  final int introOffsetMs;

  const SyncedVideoBundle({
    required this.videoId,
    required this.streams,
    this.introOffsetMs = 0,
  });
}

const _bundleTtl = Duration(hours: 3);
const _songAlignmentSeconds = 50;

/// Longer than the song window so a long video intro still leaves the
/// song in range.
const _videoAlignmentSeconds = 100;

/// Finds the official music video for a track and the offset that keeps
/// it in step with the audio. Port of LastWave-Native's
/// `SyncedVideoRepository`:
///  * Tier 1: YouTube Music's own Song/Video counterpart (official).
///  * Tier 2: verified search, gated by [isSameSongVideo] and scored by
///    [scoreVideoCandidate]; nothing below the bar is ever used.
/// There is deliberately no "use whatever the track id is" fallback: an
/// art track's picture is the cover, and a near-miss is a wrong video.
class SyncedVideoRepository {
  SyncedVideoRepository(this._tube, this._prefs);

  final InnerTubeMusicApi _tube;
  final Prefs _prefs;
  final Map<String, ({SyncedVideoBundle? bundle, DateTime at})> _cache = {};
  final Map<String, Future<SyncedVideoBundle?>> _inflight = {};
  final Map<String, Future<int?>> _measuring = {};

  /// Resolves (and caches) the official video for [track]; null when no
  /// trustworthy match exists.
  Future<SyncedVideoBundle?> resolve(PlayableTrack track) {
    final key = track.queueKey;
    final cached = _cache[key];
    if (cached != null && DateTime.now().difference(cached.at) < _bundleTtl) {
      return Future.value(cached.bundle);
    }
    return _inflight[key] ??= _resolve(track).whenComplete(() {
      _inflight.remove(key);
    });
  }

  void invalidate(PlayableTrack track) => _cache.remove(track.queueKey);

  Future<SyncedVideoBundle?> _resolve(PlayableTrack track) async {
    SyncedVideoBundle? bundle;
    try {
      final id = await findOfficialVideoId(
        title: track.title,
        artist: track.artist,
        audioVideoId: track.videoId,
        durationMs: track.duration.inMilliseconds > 0
            ? track.duration.inMilliseconds
            : null,
      );
      if (id != null) {
        final results = await Future.wait([
          _tube.resolveMusicVideo(id),
          id == track.videoId ? Future.value(0) : fetchIntroOffsetMs(id),
        ]);
        final streams = results[0] as List<MusicVideoStream>;
        if (streams.isNotEmpty) {
          bundle = SyncedVideoBundle(
            videoId: id,
            streams: streams,
            introOffsetMs: results[1] as int,
          );
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[video-sync] resolve failed: $e');
      // Transient failure: do not remember "no video" for three hours.
      return null;
    }
    _cache[track.queueKey] = (bundle: bundle, at: DateTime.now());
    return bundle;
  }

  Future<String?> findOfficialVideoId({
    required String title,
    required String artist,
    String? audioVideoId,
    int? durationMs,
  }) async {
    // Tier 1: YouTube Music's own official counterpart.
    if (audioVideoId != null && audioVideoId.isNotEmpty) {
      try {
        final counterpart = await _tube.findCounterpartVideoId(audioVideoId);
        if (counterpart != null && counterpart.isNotEmpty) return counterpart;
      } catch (_) {}
    }

    // Tier 2: verified search.
    final cleanTitle = cleanTrackTitleForVideo(title);
    final cleanArtist = artist.toLowerCase() == 'unknown artist'
        ? ''
        : artist.trim();
    final queries = <String>{
      '$cleanArtist - $cleanTitle Official Music Video'.trim(),
      '$cleanTitle $cleanArtist official video'.trim(),
      '$cleanTitle $cleanArtist'.trim(),
    }.where((q) => q.isNotEmpty);

    for (final query in queries) {
      List<YouTubeMusicTrack> results;
      try {
        results = await _tube.searchVideos(query, limit: 8);
      } catch (_) {
        continue;
      }
      final scored = <({YouTubeMusicTrack track, int score})>[];
      for (final c in results) {
        if (c.videoId.isEmpty) continue;
        final seconds = c.durationSeconds > 0 ? c.durationSeconds : null;
        if (!isSameSongVideo(
          candidateTitle: c.title,
          candidateChannel: c.artist,
          candidateSeconds: seconds,
          songTitle: cleanTitle,
          songArtist: cleanArtist,
          songDurationMs: durationMs,
        )) {
          continue;
        }
        final score = scoreVideoCandidate(
          candidateTitle: c.title,
          candidateArtist: c.artist,
          candidateDurationSec: seconds,
          wantedTitle: cleanTitle,
          wantedArtist: cleanArtist,
          expectedDurationMs: durationMs,
        );
        if (score == null) continue;
        scored.add((
          track: c,
          score: c.videoId == audioVideoId ? score + 10 : score,
        ));
      }
      scored.sort((a, b) => b.score.compareTo(a.score));
      if (scored.isNotEmpty && scored.first.score >= minVideoCandidateScore) {
        return scored.first.track.videoId;
      }
    }
    return null;
  }

  /// SponsorBlock "music_offtopic" segment at the very start: the intro
  /// skit before the song begins (e.g. 42.5 s on some official videos).
  Future<int> fetchIntroOffsetMs(String videoId) async {
    if (videoId.isEmpty) return 0;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client
          .getUrl(
            Uri.parse(
              'https://sponsor.ajay.app/api/skipSegments'
              '?videoID=$videoId&category=music_offtopic',
            ),
          )
          .timeout(const Duration(seconds: 6));
      req.headers.set(HttpHeaders.userAgentHeader, 'LastWave-Desktop/1.0');
      final res = await req.close().timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return 0;
      final body = await res.transform(utf8.decoder).join();
      final list = jsonDecode(body);
      if (list is! List) return 0;
      for (final seg in list.whereType<Map>()) {
        final segment = seg['segment'];
        if (segment is! List || segment.length < 2) continue;
        final start = (segment[0] as num?)?.toDouble() ?? 0;
        final end = (segment[1] as num?)?.toDouble() ?? 0;
        if (start <= 2.5 && end > start) {
          return ((end - start) * 1000).round();
        }
      }
      return 0;
    } catch (_) {
      return 0;
    } finally {
      client.close(force: true);
    }
  }

  /// Whether an offset was already measured for [key] (possibly "none").
  bool hasSavedOffset(String key) => _prefs.musicVideoOffsets.containsKey(key);

  int? savedOffset(String key) => _prefs.musicVideoOffsets[key];

  /// Compares the playing audio with the video's own soundtrack and
  /// returns what to add to the audio position to get the video position.
  /// Null when the two do not clearly match. Saved forever per pair: an
  /// edit's timing never changes, so each song is measured once.
  Future<int?> measureOffsetMs({
    required String key,
    required String songUrl,
    required Map<String, String> songHeaders,
    required String videoId,
  }) {
    return _measuring[key] ??= _measure(
      key: key,
      songUrl: songUrl,
      songHeaders: songHeaders,
      videoId: videoId,
    ).whenComplete(() => _measuring.remove(key));
  }

  Future<int?> _measure({
    required String key,
    required String songUrl,
    required Map<String, String> songHeaders,
    required String videoId,
  }) async {
    if (hasSavedOffset(key)) return savedOffset(key);
    // Let the track's own start win the network first.
    await Future<void>.delayed(const Duration(seconds: 2));
    try {
      final videoAudio = await _tube
          .resolveAudioStream(videoId)
          .timeout(const Duration(seconds: 20));
      if (videoAudio == null) return null;
      final captures = await Future.wait([
        capturePcm16Mono(
          url: songUrl,
          headers: songHeaders,
          seconds: _songAlignmentSeconds,
        ),
        capturePcm16Mono(
          url: videoAudio.url,
          headers: videoAudio.requestHeaders,
          seconds: _videoAlignmentSeconds,
        ),
      ]);
      final song = captures[0];
      final video = captures[1];
      // Capture failure is not a measurement: leave it unsaved so the
      // next play tries again.
      if (song == null || video == null) return null;
      final offset = await Isolate.run(
        () => alignPcm16((
          song: song,
          video: video,
          sampleRate: alignmentSampleRate,
        )),
      );
      if (kDebugMode) {
        debugPrint('[video-sync] measured $key → ${offset ?? 'no match'} ms');
      }
      await _prefs.saveMusicVideoOffset(key, offset);
      return offset;
    } catch (e) {
      if (kDebugMode) debugPrint('[video-sync] measure failed: $e');
      return null;
    }
  }
}

final syncedVideoRepositoryProvider = Provider<SyncedVideoRepository>((ref) {
  return SyncedVideoRepository(
    ref.watch(innerTubeProvider),
    ref.watch(prefsProvider),
  );
});
