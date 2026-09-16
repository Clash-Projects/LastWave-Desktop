import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/track_actions.dart';
import '../../design_system/components.dart';
import '../../design_system/icons.dart';
import '../../design_system/tokens.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/track_tile.dart';
import '../feed/feed_repository.dart';
import '../innertube/innertube_api.dart';
import '../lastfm/auth_repository.dart';
import '../library/playlists.dart';
import '../player/playback_service.dart';
import '../search/shared_providers.dart';

/// Artist / album detail dialogs as editorial ledgers. Top tracks come
/// from Last.fm, resolved to playable YTM streams on demand.
Future<void> showArtistSheet(
  BuildContext context,
  WidgetRef ref, {
  required String artistName,
  String artworkUrl = '',
}) async {
  final tracks = await _artistTopTracks(ref, artistName);
  if (!context.mounted) return;
  await showLwDialog(
    context: context,
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const EdKicker('Artist'),
        Text(artistName,
            style: LwType.headline
                .copyWith(fontSize: 18)),
        Text(
            '${tracks.length} top tracks · Last.fm + YouTube Music',
            style: LwType.caption.copyWith(
                color: LwColors.textSecondary)),
        const SizedBox(height: LwSpacing.sm),
        SizedBox(
          width: 560,
          height: 480,
          child: _EntityTracks(
            tracks: tracks,
            sourceLabel: artistName,
            artworkUrl: artworkUrl,
            icon: LucideIcons.micVocal,
          ),
        ),
      ],
    ),
  );
}

Future<void> showAlbumSheet(
  BuildContext context,
  WidgetRef ref, {
  required String albumTitle,
  required String artist,
  String browseId = '',
  String artworkUrl = '',
}) async {
  List<GeneratedTrack> tracks = const [];
  try {
    if (browseId.isNotEmpty) {
      final album = await ref
          .read(innerTubeProvider)
          .browseAlbum(browseId, limit: 50);
      final songs = album?.tracks ?? const [];
      tracks = songs
          .map((t) => GeneratedTrack(
                name: t.title,
                artist: t.artist.isNotEmpty &&
                        t.artist != 'Unknown artist'
                    ? t.artist
                    : artist,
                artworkUrl: t.artworkUrl.isNotEmpty
                    ? t.artworkUrl
                    : artworkUrl,
                videoId: t.videoId,
                durationSeconds: t.durationSeconds,
              ))
          .toList();
    }
  } catch (_) {}
  if (tracks.isEmpty) {
    tracks =
        await _searchAlbumTracks(ref, albumTitle, artist);
  }
  if (!context.mounted) return;
  await showLwDialog(
    context: context,
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const EdKicker('Album'),
        Text(albumTitle,
            style: LwType.headline
                .copyWith(fontSize: 18)),
        Text(artist, style: LwType.caption),
        const SizedBox(height: LwSpacing.sm),
        if (tracks.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(
                bottom: LwSpacing.sm),
            child: LwButton(
              onPressed: () {
                Navigator.of(context).pop();
                playGenerated(ref, context, tracks.first,
                    sourceLabel: albumTitle,
                    queueAll: tracks);
              },
              leading: const Icon(LucideIcons.play,
                  size: 14),
              child: const Text('Play'),
            ),
          ),
        SizedBox(
          width: 560,
          height: 440,
          child: _EntityTracks(
            tracks: tracks,
            sourceLabel: albumTitle,
            artworkUrl: artworkUrl,
            icon: LucideIcons.disc3,
          ),
        ),
      ],
    ),
  );
}

Future<List<GeneratedTrack>> _artistTopTracks(
    WidgetRef ref, String artist) async {
  final api = ref.read(lastFmApiProvider);
  final apiKey = ref.read(prefsApiKeyProvider);
  try {
    final json = await api.get({
      'method': 'artist.gettoptracks',
      'artist': artist,
      'api_key': apiKey,
      'limit': '20',
      'autocorrect': '1',
    });
    final items = json['toptracks']?['track'];
    final list = items is List
        ? items.whereType<Map<String, dynamic>>().toList()
        : items is Map<String, dynamic>
            ? [items]
            : <Map<String, dynamic>>[];
    final tracks = list
        .map((t) => GeneratedTrack(
              name: t['name']?.toString() ?? '',
              artist: (t['artist'] as Map?)?['name']
                      ?.toString() ??
                  artist,
              artworkUrl: _image(t['image']),
            ))
        .where((t) => t.name.isNotEmpty)
        .toList();
    return await ref
        .read(feedRepositoryProvider)
        .resolveVideos(tracks, limit: 20);
  } catch (_) {
    return const [];
  }
}

Future<List<GeneratedTrack>> _searchAlbumTracks(
    WidgetRef ref, String album, String artist) async {
  try {
    final songs = await ref
        .read(innerTubeProvider)
        .searchSongs('$artist $album', limit: 20);
    return songs
        .map((t) => GeneratedTrack(
              name: t.title,
              artist: t.artist,
              artworkUrl: t.artworkUrl,
              videoId: t.videoId,
            ))
        .toList();
  } catch (_) {
    return const [];
  }
}

String _image(Object? images) {
  var fallback = '';
  final list = images is List
      ? images.whereType<Map>().toList()
      : images is Map
          ? [images]
          : const [];
  for (final img in list) {
    final url = img['#text']?.toString() ?? '';
    if (url.isEmpty) continue;
    fallback = url;
    if (img['size'] == 'extralarge') return url;
  }
  return fallback;
}

class _EntityTracks extends ConsumerWidget {
  final List<GeneratedTrack> tracks;
  final String sourceLabel;
  final String artworkUrl;
  final IconData icon;
  const _EntityTracks({
    required this.tracks,
    required this.sourceLabel,
    required this.artworkUrl,
    required this.icon,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (tracks.isEmpty) {
      return const EmptyState(
        icon: LucideIcons.cloudOff,
        title: 'No tracks found',
        subtitle: 'Try again when you are online.',
      );
    }
    final playingKey =
        ref.watch(playbackServiceProvider.select((s) => s.current?.queueKey));
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.only(
              bottom: LwSpacing.sm),
          child: Row(
            children: [
              Artwork(
                url: tracks.first.artworkUrl.isNotEmpty
                    ? tracks.first.artworkUrl
                    : artworkUrl,
                size: 56,
                radius: LwRadius.md,
                fallbackIcon: icon,
              ),
              const SizedBox(width: LwSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${tracks.length} tracks',
                      style: LwType.title
                          .copyWith(fontSize: 14),
                    ),
                    Text(
                      'Tap to play · right-click for more',
                      style: LwType.caption.copyWith(
                          color: dark
                              ? LwColors.textSecondary
                              : LwColors
                                  .lightTextSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const EdLedgerHeader(),
        ...tracks.asMap().entries.map((e) {
          final t = e.value;
          return TrackTile(
            index: e.key + 1,
            title: t.name,
            subtitle: t.artist,
            artworkUrl: t.artworkUrl,
            playing: playingKey == t.key,
            showLike: true,
            isLiked: ref
                .watch(
                    playlistRepositoryProvider.notifier)
                .likedKeys()
                .contains(t.key),
            onToggleLike: () => toggleLike(
              ref,
              context,
              title: t.name,
              artist: t.artist,
              artworkUrl: t.artworkUrl,
              videoId: t.videoId,
            ),
            onTap: () => playGenerated(ref, context, e.value,
                sourceLabel: sourceLabel,
                queueAll: tracks,
                startIndex: e.key),
            menu: trackMenuItems(
              ref: ref,
              title: t.name,
              artist: t.artist,
              artworkUrl: t.artworkUrl,
              videoId: t.videoId,
            ),
          );
        }),
      ],
    );
  }
}
