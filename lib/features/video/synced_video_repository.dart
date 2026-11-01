import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/stream_models.dart';
import '../../core/storage/prefs.dart';
import '../innertube/innertube_api.dart';
import '../player/play_diag.dart';
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

/// A search that found no video is retried after this, not never.
const _missTtl = Duration(minutes: 15);
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
  /// trustworthy match exists. [fallbackDurationMs] is the playing audio's
  /// length, used only when the track row never carried one.
  Future<SyncedVideoBundle?> resolve(
    PlayableTrack track, {
    int? fallbackDurationMs,
  }) {
    final key = track.queueKey;
    final cached = _cache[key];
    if (cached != null &&
        DateTime.now().difference(cached.at) <
            (cached.bundle == null ? _missTtl : _bundleTtl)) {
      return Future.value(cached.bundle);
    }
    return _inflight[key] ??= _resolve(track, fallbackDurationMs).whenComplete(
      () {
        _inflight.remove(key);
      },
    );
  }

  void invalidate(PlayableTrack track) => _cache.remove(track.queueKey);

  Future<SyncedVideoBundle?> _resolve(
    PlayableTrack track,
    int? fallbackDurationMs,
  ) async {
    final label = '"${track.title}" — ${track.artist}';
    final durationMs = track.duration.inMilliseconds > 0
        ? track.duration.inMilliseconds
        : fallbackDurationMs;
    String? id;
    try {
      id = await findOfficialVideoId(
        title: track.title,
        artist: track.artist,
        audioVideoId: track.videoId,
        durationMs: durationMs,
      );
    } catch (e) {
      PlayDiag.log('video: lookup failed for $label: $e');
      return null; // transient: do not remember "no video"
    }
    if (id == null) {
      PlayDiag.log('video: no matching official video for $label');
      // A true miss is remembered, but only for a short while.
      _cache[track.queueKey] = (bundle: null, at: DateTime.now());
      return null;
    }
    try {
      final results = await Future.wait([
        _tube.resolveMusicVideo(id),
        id == track.videoId ? Future.value(0) : fetchIntroOffsetMs(id),
      ]);
      final streams = results[0] as List<MusicVideoStream>;
      if (streams.isEmpty) {
        // The video exists; its links just did not come back. That is a
        // failure to retry, not a verdict to cache for hours.
        PlayDiag.log('video: $id matched $label but no playable streams');
        return null;
      }
      final top = rankVideoStreams(streams, 0).first;
      final tallest = streams.map((s) => s.height).reduce(math.max);
      PlayDiag.log(
        'video: $id for $label — ${streams.length} streams, tallest '
        '${tallest}p, auto → ${top.label} ${top.codec} via ${top.client}',
      );
      final bundle = SyncedVideoBundle(
        videoId: id,
        streams: streams,
        introOffsetMs: results[1] as int,
      );
      _cache[track.queueKey] = (bundle: bundle, at: DateTime.now());
      return bundle;
    } catch (e) {
      PlayDiag.log('video: stream resolve failed for $id: $e');
      return null;
    }
  }

  Future<String?> findOfficialVideoId({
    required String title,
    required String artist,
    String? audioVideoId,
    int? durationMs,
  }) async {
    final cleanTitle = cleanTrackTitleForVideo(title);
    final cleanArtist = artist.toLowerCase() == 'unknown artist'
        ? ''
        : artist.trim();

    // Tier 1: YouTube Music's own official counterpart — but only when what
    // it lists really is this song. The id on the track can be a different
    // upload that was matched loosely, and its counterpart then belongs to
    // some other song.
    if (audioVideoId != null && audioVideoId.isNotEmpty) {
      try {
        final cp = await _tube.findOfficialVideoCandidate(audioVideoId);
        if (cp != null && cp.videoId.isNotEmpty) {
          final listed = cp.title.isNotEmpty;
          final same =
              !listed ||
              isSameSongVideo(
                candidateTitle: cp.title,
                candidateChannel: cp.artist,
                candidateSeconds: cp.durationSeconds > 0
                    ? cp.durationSeconds
                    : null,
                songTitle: cleanTitle,
                songArtist: cleanArtist,
                songDurationMs: durationMs,
              );
          PlayDiag.log(
            'video: tier1 ${cp.videoId}'
            '${listed ? ' "${cp.title}" — ${cp.artist}' : ''} → '
            '${same ? 'accepted' : 'rejected (not this song)'}',
          );
          if (same) return cp.videoId;
        }
      } catch (_) {}
    }

    // Tier 2: verified search.
    final queries = <String>{
      '$cleanArtist - $cleanTitle Official Music Video'.trim(),
      '$cleanTitle $cleanArtist official video'.trim(),
      '$cleanTitle $cleanArtist'.trim(),
      '$cleanTitle official music video'.trim(),
    }.where((q) => q.isNotEmpty);

    for (final query in queries) {
      List<YouTubeMusicTrack> results;
      try {
        results = await _tube.searchVideos(query, limit: 12);
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
      PlayDiag.log(
        'video: search "$query" → ${results.length} results, '
        '${scored.length} plausible'
        '${scored.isEmpty ? '' : ', best "${scored.first.track.title}" '
                  '(${scored.first.track.artist}) score ${scored.first.score}'}',
      );
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

  /// Whether [stream] really serves bytes right now. Some links come back
  /// from the player request but refuse the actual download (expired,
  /// needs a token the client did not get); finding that out before
  /// opening beats a long black wait followed by a failure.
  Future<bool> probeVideoStream(MusicVideoStream stream) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client
          .getUrl(Uri.parse(stream.url))
          .timeout(const Duration(seconds: 6));
      stream.requestHeaders.forEach(req.headers.set);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final res = await req.close().timeout(const Duration(seconds: 8));
      final ok = res.statusCode == 206 || res.statusCode == 200;
      // A server that ignores Range would stream the whole file: one chunk
      // is proof enough, and closing the client cuts the rest.
      if (ok) await res.first.timeout(const Duration(seconds: 8));
      return ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Whether an offset was already measured for [key] (possibly "none").
  /// Saved offsets are versioned: results from before the matcher was
  /// reworked (many of them "no match") must not hide videos forever.
  static String _stored(String key) => 'v2|$key';

  /// Measured offsets live in the prefs; "measured, nothing matched" lives
  /// only for this session so it gets another chance next time.
  final Set<String> _unmatched = {};

  bool hasSavedOffset(String key) =>
      _prefs.musicVideoOffsets[_stored(key)] != null;

  /// True when this session already measured [key] and found no match.
  bool wasUnmatched(String key) => _unmatched.contains(key);

  int? savedOffset(String key) => _prefs.musicVideoOffsets[_stored(key)];

  /// Compares the playing audio with the video's own soundtrack and
  /// returns what to add to the audio position to get the video position.
  /// Null when the two do not clearly match. Saved forever per pair: an
  /// edit's timing never changes, so each song is measured once.
  Future<int?> measureOffsetMs({
    required String key,
    required String songUrl,
    required Map<String, String> songHeaders,
    required String videoId,
    String? songVideoId,
  }) {
    return _measuring[key] ??= _measure(
      key: key,
      songUrl: songUrl,
      songHeaders: songHeaders,
      videoId: videoId,
      songVideoId: songVideoId,
    ).whenComplete(() => _measuring.remove(key));
  }

  Future<int?> _measure({
    required String key,
    required String songUrl,
    required Map<String, String> songHeaders,
    required String videoId,
    String? songVideoId,
  }) async {
    if (hasSavedOffset(key)) return savedOffset(key);
    if (_unmatched.contains(key)) return null;
    // Let the track's own start win the network first.
    await Future<void>.delayed(const Duration(seconds: 1));
    try {
      final videoAudio = await _tube
          .resolveAudioStream(videoId)
          .timeout(const Duration(seconds: 20));
      if (videoAudio == null) {
        PlayDiag.log('video: align — no soundtrack stream for $videoId');
        return null;
      }
      final captures = await Future.wait([
        _captureSong(
          songUrl: songUrl,
          songHeaders: songHeaders,
          songVideoId: songVideoId,
          videoId: videoId,
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
      if (song == null || video == null) {
        PlayDiag.log(
          'video: align — capture failed '
          '(song ${song == null ? 'no' : 'ok'}, '
          'video ${video == null ? 'no' : 'ok'})',
        );
        return null;
      }
      final result = await Isolate.run(
        () => alignPcm16((
          song: song,
          video: video,
          sampleRate: alignmentSampleRate,
        )),
      );
      if (result == null) {
        PlayDiag.log('video: align $key → no confident match');
        _unmatched.add(key);
        return null;
      }
      PlayDiag.log(
        'video: align $key → ${result.offsetMs} ms'
        '${result.relaxed ? ' (loose match)' : ''}',
      );
      await _prefs.saveMusicVideoOffset(_stored(key), result.offsetMs);
      return result.offsetMs;
    } catch (e) {
      PlayDiag.log('video: align failed: $e');
      return null;
    }
  }

  /// The song side of the comparison. The same recording's YouTube audio is
  /// preferred over whatever is playing: it is plain https that this player
  /// can always read, and it leaves a lossless proxy or local file the user
  /// is listening to alone (a second connection to it could disturb
  /// playback). The playing source is used only when it is itself plain
  /// remote audio and no YouTube id is known.
  Future<Uint8List?> _captureSong({
    required String songUrl,
    required Map<String, String> songHeaders,
    required String? songVideoId,
    required String videoId,
  }) async {
    if (songVideoId != null &&
        songVideoId.isNotEmpty &&
        songVideoId != videoId) {
      try {
        final alt = await _tube
            .resolveAudioStream(songVideoId)
            .timeout(const Duration(seconds: 20));
        if (alt != null) {
          final pcm = await capturePcm16Mono(
            url: alt.url,
            headers: alt.requestHeaders,
            seconds: _songAlignmentSeconds,
          );
          if (pcm != null) return pcm;
        }
      } catch (_) {}
    }
    final uri = Uri.tryParse(songUrl);
    final remote =
        uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host != '127.0.0.1' &&
        uri.host != 'localhost' &&
        uri.host != '::1' &&
        uri.host.isNotEmpty;
    if (!remote) return null;
    return capturePcm16Mono(
      url: songUrl,
      headers: songHeaders,
      seconds: _songAlignmentSeconds,
    );
  }
}

final syncedVideoRepositoryProvider = Provider<SyncedVideoRepository>((ref) {
  return SyncedVideoRepository(
    ref.watch(innerTubeProvider),
    ref.watch(prefsProvider),
  );
});
