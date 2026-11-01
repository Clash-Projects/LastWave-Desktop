import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
import 'ytdlp_tools.dart';

/// A resolved official music video: its id and every playable height.
class SyncedVideoBundle {
  final String videoId;
  final List<MusicVideoStream> streams;

  /// The video's own audio-only links, from the same clients that gave the
  /// pictures. Read to measure the video's timing.
  final List<MusicVideoStream> soundtracks;

  /// Intro the community marked as non-music (SponsorBlock), 0 if none.
  final int introOffsetMs;

  /// Whether yt-dlp's links are in [streams] (or it was asked and gave
  /// none), so a bundle made before the tools were installed is redone.
  final bool withYtDlp;

  const SyncedVideoBundle({
    required this.videoId,
    required this.streams,
    this.soundtracks = const [],
    this.introOffsetMs = 0,
    this.withYtDlp = false,
  });

  SyncedVideoBundle merged(List<MusicVideoStream> extra) {
    final seen = {
      for (final s in [...streams, ...soundtracks]) s.url,
    };
    final add = [
      for (final s in extra)
        if (seen.add(s.url)) s,
    ];
    return SyncedVideoBundle(
      videoId: videoId,
      streams: [
        ...streams,
        for (final s in add)
          if (!s.audioOnly) s,
      ],
      soundtracks: [
        ...soundtracks,
        for (final s in add)
          if (s.audioOnly) s,
      ],
      introOffsetMs: introOffsetMs,
      withYtDlp: true,
    );
  }
}

const _bundleTtl = Duration(hours: 3);

/// A search that found no video is retried after this, not never.
const _missTtl = Duration(minutes: 15);
const _songAlignmentSeconds = 70;

/// Longer than the song window so a long video intro still leaves the
/// song in range.
const _videoAlignmentSeconds = 160;

/// Finds the official music video for a track and the offset that keeps
/// it in step with the audio. Port of LastWave-Native's
/// `SyncedVideoRepository`:
///  * Tier 1: YouTube Music's own Song/Video counterpart (official).
///  * Tier 2: verified search, gated by [isSameSongVideo] and scored by
///    [scoreVideoCandidate]; nothing below the bar is ever used.
/// There is deliberately no "use whatever the track id is" fallback: an
/// art track's picture is the cover, and a near-miss is a wrong video.
class SyncedVideoRepository {
  SyncedVideoRepository(this._tube, this._prefs, [this._tools]);

  final InnerTubeMusicApi _tube;
  final Prefs _prefs;
  final YtDlpTools? _tools;
  final Map<String, ({SyncedVideoBundle? bundle, DateTime at})> _cache = {};
  final Map<String, Future<SyncedVideoBundle?>> _inflight = {};
  final Map<String, Future<int?>> _measuring = {};

  /// Unconfirmed offsets for pairs that could not be measured, this
  /// session only: where to place a picture that shows anyway.
  final Map<String, int> _guesses = {};

  int? guessedOffset(String key) => _guesses[key];

  /// Resolves (and caches) the official video for [track]; null when no
  /// trustworthy match exists. [fallbackDurationMs] is the playing audio's
  /// length, used only when the track row never carried one.
  ///
  /// [wantHeight] is the picture height the player will aim for: when the
  /// built-in lookup already reaches it, yt-dlp (if installed) finishes in
  /// the background instead of holding the video back.
  Future<SyncedVideoBundle?> resolve(
    PlayableTrack track, {
    int? fallbackDurationMs,
    int wantHeight = 1080,
  }) {
    final key = track.queueKey;
    final cached = _cache[key];
    final toolsNow = _tools?.installed ?? false;
    if (cached != null &&
        DateTime.now().difference(cached.at) <
            (cached.bundle == null ? _missTtl : _bundleTtl) &&
        !(toolsNow && cached.bundle != null && !cached.bundle!.withYtDlp)) {
      return Future.value(cached.bundle);
    }
    return _inflight[key] ??= _resolve(track, fallbackDurationMs, wantHeight)
        .whenComplete(() {
          _inflight.remove(key);
        });
  }

  void invalidate(PlayableTrack track) => _cache.remove(track.queueKey);

  Future<SyncedVideoBundle?> _resolve(
    PlayableTrack track,
    int? fallbackDurationMs,
    int wantHeight,
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
    final tools = _tools;
    await tools?.ensureChecked();
    final ytDlp = (tools != null && tools.installed)
        ? tools.formatsFor(id).catchError((_) => <MusicVideoStream>[])
        : null;
    try {
      final results = await Future.wait([
        _tube.resolveMusicVideo(id),
        id == track.videoId ? Future.value(0) : fetchIntroOffsetMs(id),
      ]);
      var all = results[0] as List<MusicVideoStream>;
      int tallestOf(List<MusicVideoStream> list) => list
          .where((s) => !s.audioOnly)
          .fold(0, (m, s) => math.max(m, s.height));
      // Wait for yt-dlp only when the built-in links fall short of what the
      // player wants; otherwise its links join the cached bundle later.
      final waitForYtDlp =
          ytDlp != null && (all.isEmpty || tallestOf(all) < wantHeight);
      if (waitForYtDlp) all = [...all, ...await ytDlp];
      final streams = [
        for (final s in all)
          if (!s.audioOnly) s,
      ];
      final soundtracks = [
        for (final s in all)
          if (s.audioOnly) s,
      ];
      if (streams.isEmpty) {
        // The video exists; its links just did not come back. That is a
        // failure to retry, not a verdict to cache for hours.
        PlayDiag.log('video: $id matched $label but no playable streams');
        return null;
      }
      final queueKey = track.queueKey;
      final top = rankVideoStreams(streams, 0).first;
      final tallest = streams.map((s) => s.height).reduce(math.max);
      PlayDiag.log(
        'video: $id for $label — ${streams.length} streams, tallest '
        '${tallest}p, auto → ${top.label} ${top.codec} via ${top.client}',
      );
      final bundle = SyncedVideoBundle(
        videoId: id,
        streams: streams,
        soundtracks: soundtracks,
        introOffsetMs: results[1] as int,
        withYtDlp: ytDlp != null && waitForYtDlp,
      );
      _cache[queueKey] = (bundle: bundle, at: DateTime.now());
      if (ytDlp != null && !waitForYtDlp) {
        unawaited(
          ytDlp.then((extra) {
            final current = _cache[queueKey]?.bundle;
            if (current == null || current.videoId != id) return;
            _cache[queueKey] = (
              bundle: current.merged(extra),
              at: DateTime.now(),
            );
          }),
        );
      }
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
          if (same && !isNotAMusicVideo(cp.title, cleanTitle)) {
            return cp.videoId;
          }
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
      List<({YouTubeMusicTrack track, String? type})> typed;
      try {
        typed = await _tube.searchVideosTyped(query, limit: 12);
      } catch (_) {
        continue;
      }
      final results = [for (final r in typed) r.track];
      final scored = <({YouTubeMusicTrack track, int score})>[];
      var unofficial = 0;
      for (final r in typed) {
        final c = r.track;
        if (c.videoId.isEmpty) continue;
        // Only what YouTube Music itself lists as an official music video.
        // Re-uploads, fan edits and visualizers are "UGC" there even when
        // their titles say "Official Video".
        if (r.type != officialMusicVideoType) {
          unofficial++;
          continue;
        }
        if (isNotAMusicVideo(c.title, cleanTitle)) continue;
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
        'video: search "$query" → ${results.length} results '
        '($unofficial not official), ${scored.length} plausible'
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
    required String title,
    required String artist,
    int? durationMs,
    String? songVideoId,
    List<MusicVideoStream> videoSources = const [],
  }) {
    return _measuring[key] ??= _measure(
      key: key,
      songUrl: songUrl,
      songHeaders: songHeaders,
      videoId: videoId,
      title: title,
      artist: artist,
      durationMs: durationMs,
      songVideoId: songVideoId,
      videoSources: videoSources,
    ).whenComplete(() => _measuring.remove(key));
  }

  Future<int?> _measure({
    required String key,
    required String songUrl,
    required Map<String, String> songHeaders,
    required String videoId,
    required String title,
    required String artist,
    required int? durationMs,
    String? songVideoId,
    List<MusicVideoStream> videoSources = const [],
  }) async {
    if (hasSavedOffset(key)) return savedOffset(key);
    if (_unmatched.contains(key)) return null;
    // Let the track's own start win the network first.
    await Future<void>.delayed(const Duration(seconds: 1));
    final clock = Stopwatch()..start();
    PlayDiag.log('video: align start $key');
    try {
      final captures = await Future.wait([
        _captureSong(
          songUrl: songUrl,
          songHeaders: songHeaders,
          songVideoId: songVideoId,
          videoId: videoId,
          title: title,
          artist: artist,
          durationMs: durationMs,
        ),
        _captureVideoSide(videoId, videoSources),
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
      final result = await alignPcm16Async(song, video, alignmentSampleRate);
      if (result == null) {
        final guess = await guessOffsetPcm16Async(
          song,
          video,
          alignmentSampleRate,
        );
        PlayDiag.log(
          'video: align $key → no confident match'
          '${guess == null ? '' : ', best guess $guess ms'}',
        );
        _unmatched.add(key);
        if (guess != null) _guesses[key] = guess;
        return null;
      }
      PlayDiag.log(
        'video: align $key → ${result.offsetMs} ms in '
        '${clock.elapsedMilliseconds}ms'
        '${result.relaxed ? ' (loose match)' : ''}',
      );
      await _prefs.saveMusicVideoOffset(_stored(key), result.offsetMs);
      return result.offsetMs;
    } catch (e) {
      PlayDiag.log('video: align failed: $e');
      return null;
    }
  }

  /// The song's own studio audio on YouTube, for when the track row carries
  /// no YouTube id (anything found through the lossless catalog). Null when
  /// no result is clearly the same recording.
  Future<String?> findSongAudioId({
    required String title,
    required String artist,
    required int? durationMs,
    String? excludeId,
  }) async {
    final cleanTitle = cleanTrackTitleForVideo(title);
    final cleanArtist = artist.toLowerCase() == 'unknown artist'
        ? ''
        : artist.trim();
    try {
      final rows = await _tube.searchSongs(
        '$cleanTitle $cleanArtist'.trim(),
        limit: 8,
      );
      return pickSongAudioCandidate(
        [
          for (final r in rows)
            (
              id: r.videoId,
              title: r.title,
              artist: r.artist,
              seconds: r.durationSeconds,
            ),
        ],
        title: cleanTitle,
        artist: cleanArtist,
        durationMs: durationMs,
        excludeId: excludeId,
      );
    } catch (_) {
      return null;
    }
  }

  /// The video's own audio: first the soundtrack links that came with the
  /// pictures (same client, already known to be served), then a muxed
  /// picture file read with its picture switched off, then the audio
  /// resolver used for songs.
  Future<Uint8List?> _captureVideoSide(
    String videoId,
    List<MusicVideoStream> sources,
  ) async {
    int rank(MusicVideoStream s) {
      if (s.audioOnly) return s.client == 'ANDROID_VR' ? 0 : 1;
      return s.muxed ? 2 : 3;
    }

    final ordered =
        [
          for (final s in sources)
            if (s.audioOnly || s.muxed) s,
        ]..sort((a, b) {
          final r = rank(a).compareTo(rank(b));
          // Lighter files decode sooner; timing does not need fidelity.
          return r != 0 ? r : a.bitrate.compareTo(b.bitrate);
        });
    final tried = <String>{};
    for (final s in ordered) {
      // One try per client and kind: a refused client refuses them all.
      if (!tried.add('${s.client}|${s.audioOnly}')) continue;
      if (tried.length > 3) break;
      final pcm = await capturePcm16Mono(
        url: s.url,
        headers: s.requestHeaders,
        seconds: _videoAlignmentSeconds,
        minSeconds: 40,
      );
      if (pcm != null) {
        PlayDiag.log(
          'video: align — video side from ${s.client} '
          '${s.audioOnly ? 'soundtrack' : '${s.label} file'}',
        );
        return pcm;
      }
    }
    try {
      final alt = await _tube
          .resolveAudioStream(videoId)
          .timeout(const Duration(seconds: 20));
      if (alt == null) {
        PlayDiag.log('video: align — no soundtrack stream for $videoId');
        return null;
      }
      final pcm = await capturePcm16Mono(
        url: alt.url,
        headers: alt.requestHeaders,
        seconds: _videoAlignmentSeconds,
        minSeconds: 40,
      );
      if (pcm != null) {
        PlayDiag.log('video: align — video side from the audio resolver');
      }
      return pcm;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _captureYoutubeAudio(String id) async {
    try {
      final alt = await _tube
          .resolveAudioStream(id)
          .timeout(const Duration(seconds: 20));
      if (alt == null) return null;
      return await capturePcm16Mono(
        url: alt.url,
        headers: alt.requestHeaders,
        seconds: _songAlignmentSeconds,
      );
    } catch (_) {
      return null;
    }
  }

  /// The song side of the comparison, from the first source that reads:
  ///  1. the YouTube audio of the track's own id (same recording, plain
  ///     https this player always reads);
  ///  2. the song's studio audio found by search — most lossless-catalog
  ///     tracks have no YouTube id at all;
  ///  3. the playing source itself, which for lossless is the app's own
  ///     loopback server and is the exact audio being heard.
  Future<Uint8List?> _captureSong({
    required String songUrl,
    required Map<String, String> songHeaders,
    required String? songVideoId,
    required String videoId,
    required String title,
    required String artist,
    required int? durationMs,
  }) async {
    if (songVideoId != null &&
        songVideoId.isNotEmpty &&
        songVideoId != videoId) {
      final pcm = await _captureYoutubeAudio(songVideoId);
      if (pcm != null) {
        PlayDiag.log('video: align — song side from track id $songVideoId');
        return pcm;
      }
    }
    final found = await findSongAudioId(
      title: title,
      artist: artist,
      durationMs: durationMs,
      excludeId: videoId,
    );
    if (found != null) {
      final pcm = await _captureYoutubeAudio(found);
      if (pcm != null) {
        PlayDiag.log('video: align — song side from searched audio $found');
        return pcm;
      }
    }
    final pcm = await capturePcm16Mono(
      url: songUrl,
      headers: songHeaders,
      seconds: _songAlignmentSeconds,
    );
    PlayDiag.log(
      'video: align — song side from the playing source: '
      '${pcm == null ? 'unreadable' : 'ok'}',
    );
    return pcm;
  }
}

final syncedVideoRepositoryProvider = Provider<SyncedVideoRepository>((ref) {
  return SyncedVideoRepository(
    ref.watch(innerTubeProvider),
    ref.watch(prefsProvider),
    ref.read(ytDlpToolsProvider),
  );
});
