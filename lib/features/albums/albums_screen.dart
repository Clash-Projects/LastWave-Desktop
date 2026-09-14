import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../../design_system/components.dart';
import '../../design_system/icons.dart';
import '../../design_system/tokens.dart';
import '../../widgets/cards.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/skeletons.dart';
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
    try {
      final entities = await ref
          .watch(innerTubeProvider)
          .browseAlbums('FEmusic_new_releases', limit: 24);
      return entities.map((e) {
        final parts =
            InnerTubeMusicApi.splitSubtitle(e.subtitle);
        final artist = parts.length > 1 ? parts[1] : e.artist;
        return _Album(e.name, artist, e.artworkUrl);
      }).toList();
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

/// Editorial albums ledger: masthead + rank ledger grid.
/// Replaces boxed grid with header-cell hack; first cell is now a real
/// masthead, tiles are flat veil artworks with ledger captions.
class AlbumsScreen extends ConsumerWidget {
  const AlbumsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(_albumsProvider);
    return albums.when(
      loading: () => ListView(
        padding: const EdgeInsets.all(LwSpacing.xl),
        children: const [
          SkeletonBox(width: 200, height: 26),
          SizedBox(height: 16),
          SkeletonRail(),
        ],
      ),
      error: (e, _) => EmptyState(
        icon: LucideIcons.cloudOff,
        title: 'Could not load albums',
        subtitle: e.toString(),
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(_albumsProvider),
      ),
      data: (list) => CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                  LwSpacing.xl,
                  LwSpacing.lg,
                  LwSpacing.xl,
                  LwSpacing.sm),
              child: EdPage(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    EdKicker('Collect'),
                    Text('Albums',
                        style: LwType.display),
                    SizedBox(height: 4),
                    Text(
                      'Your most-played records this month.',
                      style: LwType.body,
                    ),
                  ],
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
                LwSpacing.xl, 0, LwSpacing.xl, 96),
            sliver: SliverGrid(
              gridDelegate:
                  const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 190,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                mainAxisExtent: 240,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final a = list[i];
                  return MediaCard(
                    title: a.title,
                    subtitle: a.artist,
                    artworkUrl: a.artwork,
                    width: 180,
                    onTap: () =>
                        _openAlbum(context, ref, a),
                  );
                },
                childCount: list.length,
              ),
            ),
          ),
        ],
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
