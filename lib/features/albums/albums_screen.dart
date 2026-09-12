import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../design_system/icons.dart';

import '../../core/storage/prefs.dart';
import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
import '../common/entity_sheets.dart';
import '../innertube/innertube_api.dart';
import '../lastfm/auth_repository.dart';
import '../lastfm/home_repository.dart';
import '../search/shared_providers.dart';

class _Album {
  final String title;
  final String artist;
  final String artwork;
  const _Album(this.title, this.artist, this.artwork);
}

final _albumsProvider =
    FutureProvider.autoDispose<List<_Album>>((ref) async {
  final api = ref.watch(lastFmApiProvider);
  final apiKey = ref.watch(prefsApiKeyProvider);
  final viewing = ref.watch(viewingProfileProvider);
  final user = viewing ??
      ref.watch(prefsProvider).username;
  if (user.isEmpty) {
    // Guest fallback: YTM new-release albums.
    try {
      final songs = await ref
          .watch(innerTubeProvider)
          .browseSongs('FEmusic_new_releases', limit: 24);
      return songs
          .map((s) => _Album(
              s.album.isNotEmpty ? s.album : s.title,
              s.artist,
              s.artworkUrl))
          .toList();
    } catch (_) {
      return const [];
    }
  }
  try {
    final json = await api.get({
      'method': 'user.gettopalbums',
      'user': user,
      'api_key': apiKey,
      'limit': '30',
      'period': '1month',
    });
    final items = json['topalbums']?['album'];
    final list = items is List
        ? items.whereType<Map<String, dynamic>>().toList()
        : items is Map<String, dynamic>
            ? [items]
            : <Map<String, dynamic>>[];
    return list
        .map((a) => _Album(
              a['name']?.toString() ?? '',
              (a['artist'] as Map?)?['name']?.toString() ?? '',
              _img(a['image']),
            ))
        .where((e) => e.title.isNotEmpty)
        .toList();
  } catch (_) {
    return const [];
  }
});

String _img(Object? images) {
  var fallback = '';
  final list = images is List
      ? images.whereType<Map>().toList()
      : const [];
  for (final img in list) {
    final url = img['#text']?.toString() ?? '';
    if (url.isEmpty) continue;
    fallback = url;
    if (img['size'] == 'extralarge') return url;
  }
  return fallback;
}

/// Top albums grid (personal when signed in, new releases for guests).
class AlbumsScreen extends ConsumerWidget {
  const AlbumsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(_albumsProvider);
    return albums.when(
      loading: () => ListView(
        padding: const EdgeInsets.all(LwSpacing.lg),
        children: const [
          SkeletonBox(width: 200, height: 26),
          SizedBox(height: 16),
          SkeletonRow(count: 8),
        ],
      ),
      error: (e, _) => EmptyState(
        icon: LwIcons.cloudOff,
        title: 'Could not load albums',
        subtitle: e.toString(),
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(_albumsProvider),
      ),
      data: (list) => GridView.builder(
        padding: const EdgeInsets.fromLTRB(
            LwSpacing.lg, LwSpacing.lg, LwSpacing.lg, 96),
        gridDelegate:
            const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 190,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          mainAxisExtent: 236,
        ),
        itemCount: list.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text('Albums',
                      style: LwType.display),
                  SizedBox(height: 4),
                  Text(
                      'Your most-played records this month.',
                      style: LwType.body),
                ],
              ),
            );
          }
          final a = list[i - 1];
          return MediaCard(
            title: a.title,
            subtitle: a.artist,
            artworkUrl: a.artwork,
            width: 180,
            onTap: () => _openAlbum(context, ref, a),
          );
        },
      ),
    );
  }

  Future<void> _openAlbum(
      BuildContext context, WidgetRef ref, _Album a) async {
    String browseId = '';
    try {
      final results = await ref
          .read(innerTubeProvider)
          .searchAlbums('${a.artist} ${a.title}', limit: 3);
      for (final r in results) {
        if (r.name.toLowerCase() ==
            a.title.toLowerCase()) {
          browseId = r.browseId;
          break;
        }
      }
      browseId = browseId.isEmpty && results.isNotEmpty
          ? results.first.browseId
          : browseId;
    } catch (_) {}
    if (!context.mounted) return;
    await showAlbumSheet(
      context,
      ref,
      albumTitle: a.title,
      artist: a.artist,
      browseId: browseId,
      artworkUrl: a.artwork,
    );
  }
}
