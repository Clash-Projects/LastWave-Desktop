import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/audio/stream_models.dart';
import '../core/storage/prefs.dart';
import '../features/feed/feed_repository.dart';
import '../features/innertube/album_match.dart';
import '../features/innertube/innertube_api.dart';
import '../features/player/playback_service.dart';

/// Start the queue; the playback service resolves each track on demand.
/// Limusic fast path: videoIds are preserved end-to-end so tracks with
/// a known videoId open instantly (no search, no lyrics/artwork/Last.fm
/// gating before playback).
Future<void> playGenerated(
  WidgetRef ref,
  BuildContext context,
  GeneratedTrack track, {
  String sourceLabel = 'Home',
  List<GeneratedTrack>? queueAll,
  int startIndex = 0,
}) async {
  final player = ref.read(playbackServiceProvider.notifier);
  final list = queueAll ?? [track];
  final index = queueAll == null ? 0 : startIndex;
  await player.playQueue(
    list.map(playableFromGenerated).toList(),
    index,
    sourceLabel: sourceLabel,
    // Autoplay similar once the queue runs out (Settings → Playback).
    // Every list surface funnels through here, so one flag covers
    // Quick Picks, Liked, History, albums and playlists.
    endlessRadio: ref.read(prefsProvider).autoplaySimilar,
  );
}

/// Merge YouTube Music account tracks into a local queue, deduped by
/// videoId then name|artist. Local entries keep their order; YT extras
/// append. Used by Liked Songs surfaces when signed in.
List<GeneratedTrack> mergeYtTracks(
  List<GeneratedTrack> local,
  List<YouTubeMusicTrack> yt,
) {
  if (yt.isEmpty) return local;
  final seen = <String>{
    for (final t in local)
      if (t.videoId.isNotEmpty)
        'v:${t.videoId}'
      else
        'k:${t.key}',
  };
  final out = List<GeneratedTrack>.of(local);
  var added = 0;
  for (final t in yt) {
    final vKey =
        t.videoId.isNotEmpty ? 'v:${t.videoId}' : null;
    final kKey =
        'k:${t.title.toLowerCase()}|${t.artist.toLowerCase()}';
    if ((vKey != null && seen.contains(vKey)) ||
        seen.contains(kKey)) {
      continue;
    }
    if (vKey != null) seen.add(vKey);
    seen.add(kKey);
    added++;
    out.add(GeneratedTrack(
      name: t.title,
      artist: t.artist,
      album: t.album,
      artworkUrl: t.artworkUrl,
      videoId: t.videoId,
      durationSeconds: t.durationSeconds,
    ));
  }
  if (kDebugMode) {
    debugPrint(
        'mergeYtTracks: local=${local.length} yt=${yt.length} added=$added');
  }
  return out;
}

/// Open the specific album behind a track (`/album/:browseId`).
///
/// Resolution: track album text, else a YTM match backfill (search rows
/// carry the MPRE album badge), then album search +
/// [pickBestAlbumMatch] (rejects the commentary/karaoke/tribute
/// entities YTM ranks by popularity). Any miss/empty/timeout falls
/// back to the album/title search page — today's behavior — so the tap
/// always lands somewhere sensible, never dead.
Future<void> goToAlbumOfTrack(
  WidgetRef ref, {
  required String title,
  required String artist,
  String album = '',
}) async {
  final context = ref.context;
  void fallback() {
    if (!context.mounted) return;
    final q = album.isNotEmpty ? album : title;
    context.go('/search?q=${Uri.encodeComponent(q)}');
  }

  try {
    var albumName = album.trim();
    if (albumName.isEmpty) {
      try {
        final match = await ref
            .read(innerTubeProvider)
            .findBestMatchOrNull(title, artist)
            .timeout(const Duration(seconds: 8));
        albumName = match?.album.trim() ?? '';
      } catch (_) {}
    }
    if (albumName.isEmpty) {
      fallback();
      return;
    }
    final results = await ref
        .read(innerTubeProvider)
        .searchAlbums('$artist $albumName', limit: 15)
        .timeout(const Duration(seconds: 8));
    final browseId = pickBestAlbumMatch(
      results,
      title: albumName,
      artist: artist,
    )?.browseId ?? '';
    if (browseId.isEmpty) {
      fallback();
      return;
    }
    if (!context.mounted) return;
    context.go('/album/${Uri.encodeComponent(browseId)}');
  } catch (_) {
    try {
      fallback();
    } catch (_) {}
  }
}

PlayableTrack playableFromGenerated(GeneratedTrack t) =>
    PlayableTrack(
      title: t.name,
      artist: t.artist,
      artworkUrl: t.artworkUrl,
      videoId: t.videoId,
    );

String formatDuration(Duration d) {
  final total = d.inSeconds.clamp(0, 1 << 31);
  final m = total ~/ 60;
  final s = total % 60;
  if (d.inHours > 0) {
    return '${d.inHours}:${(m % 60).toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '$m:${s.toString().padLeft(2, '0')}';
}

String relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}
