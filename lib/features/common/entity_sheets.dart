import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../design_system/icons.dart';

import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
import '../feed/feed_repository.dart';
import '../home/home_screen.dart' show playGenerated;
import '../innertube/innertube_api.dart';
import '../lastfm/auth_repository.dart';
import '../search/shared_providers.dart';

/// Artist / album detail sheets shared by search, artists and albums
/// screens. Top tracks come from Last.fm, resolved to playable YTM
/// streams on demand.
Future<void> showArtistSheet(
  BuildContext context,
  WidgetRef ref, {
  required String artistName,
  String artworkUrl = '',
}) async {
  final tracks = await _artistTopTracks(ref, artistName);
  if (!context.mounted) return;
  await showDialog(
    context: context,
    builder: (context) => _EntityDialog(
      title: artistName,
      subtitle:
          '${tracks.length} top tracks · Last.fm + YouTube Music',
      artworkUrl: artworkUrl,
      icon: LwIcons.mic,
      tracks: tracks,
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
      final songs = await ref
          .read(innerTubeProvider)
          .browseSongs(browseId, limit: 50);
      tracks = songs
          .map((t) => GeneratedTrack(
                name: t.title,
                artist: t.artist.isNotEmpty
                    ? t.artist
                    : artist,
                artworkUrl: t.artworkUrl.isNotEmpty
                    ? t.artworkUrl
                    : artworkUrl,
                videoId: t.videoId,
              ))
          .toList();
    }
  } catch (_) {}
  if (tracks.isEmpty) {
    tracks =
        await _searchAlbumTracks(ref, albumTitle, artist);
  }
  if (!context.mounted) return;
  await showDialog(
    context: context,
    builder: (context) => _EntityDialog(
      title: albumTitle,
      subtitle: artist,
      artworkUrl: artworkUrl,
      icon: LwIcons.disc3,
      tracks: tracks,
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

class _EntityDialog extends ConsumerWidget {
  final String title;
  final String subtitle;
  final String artworkUrl;
  final IconData icon;
  final List<GeneratedTrack> tracks;
  const _EntityDialog({
    required this.title,
    required this.subtitle,
    required this.artworkUrl,
    required this.icon,
    required this.tracks,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dialog(
      backgroundColor: LwColors.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LwRadius.lg),
      ),
      child: SizedBox(
        width: 560,
        height: 560,
        child: Column(
          children: [
            Padding(
              padding:
                  const EdgeInsets.all(LwSpacing.md),
              child: Row(
                children: [
                  Artwork(
                      url: tracks.isNotEmpty &&
                              tracks.first.artworkUrl
                                  .isNotEmpty
                          ? tracks.first.artworkUrl
                          : artworkUrl,
                      size: 64,
                      radius: LwRadius.sm,
                      fallbackIcon: icon),
                  const SizedBox(width: LwSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: LwType.headline,
                            maxLines: 2,
                            overflow:
                                TextOverflow.ellipsis),
                        Text(subtitle,
                            style: LwType.caption.copyWith(
                                color: LwColors
                                    .textSecondary)),
                      ],
                    ),
                  ),
                  if (tracks.isNotEmpty)
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        playGenerated(ref, context,
                            tracks.first,
                            sourceLabel: title,
                            queueAll: tracks);
                      },
                      icon: const Icon(LwIcons.play,
                          size: 14),
                      label: const Text('Play'),
                    ),
                ],
              ),
            ),
            const Divider(
                height: 1, color: LwColors.outlineSoft),
            Expanded(
              child: tracks.isEmpty
                  ? const EmptyState(
                      icon: LwIcons.cloudOff,
                      title: 'No tracks found',
                      subtitle:
                          'Try again when you are online.',
                    )
                  : ListView(
                      children: tracks
                          .asMap()
                          .entries
                          .map((e) => TrackTile(
                                title: e.value.name,
                                subtitle:
                                    e.value.artist,
                                artworkUrl: e
                                    .value.artworkUrl,
                                onTap: () {
                                  Navigator.of(context)
                                      .pop();
                                  playGenerated(
                                      ref,
                                      context,
                                      e.value,
                                      sourceLabel: title,
                                      queueAll: tracks,
                                      startIndex: e.key);
                                },
                              ))
                          .toList(),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
