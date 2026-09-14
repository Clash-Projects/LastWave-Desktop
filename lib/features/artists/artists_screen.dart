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
import '../lastfm/auth_repository.dart';
import '../lastfm/home_repository.dart';
import '../search/shared_providers.dart';

final _artistsProvider = FutureProvider.autoDispose<
    List<({String name, String artwork})>>((ref) async {
  final api = ref.watch(lastFmApiProvider);
  final apiKey = ref.watch(prefsApiKeyProvider);
  final viewing = ref.watch(viewingProfileProvider);
  final user = viewing ??
      ref.watch(prefsProvider).username;
  try {
    final method =
        user.isEmpty ? 'chart.gettopartists' : 'user.gettopartists';
    final json = await api.get({
      'method': method,
      if (user.isNotEmpty) 'user': user,
      'api_key': apiKey,
      'limit': '30',
      'period': '1month',
    });
    final root = user.isEmpty
        ? json['artists']
        : json['topartists'];
    final items = root?['artist'];
    final list = items is List
        ? items.whereType<Map<String, dynamic>>().toList()
        : items is Map<String, dynamic>
            ? [items]
            : <Map<String, dynamic>>[];
    return list
        .map((a) => (
              name: a['name']?.toString() ?? '',
              artwork: _img(a['image']),
            ))
        .where((e) => e.name.isNotEmpty)
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

/// Editorial artists ledger: masthead + ranked circle ledger.
/// Replaces boxed grid + header-cell with flat ranked circles.
class ArtistsScreen extends ConsumerWidget {
  const ArtistsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artists = ref.watch(_artistsProvider);
    return artists.when(
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
        title: 'Could not load artists',
        subtitle: e.toString(),
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(_artistsProvider),
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
                    Text('Artists',
                        style: LwType.display),
                    SizedBox(height: 4),
                    Text(
                      'Your most-played voices this month.',
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
                maxCrossAxisExtent: 170,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                mainAxisExtent: 190,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final a = list[i];
                  return ArtistCard(
                    name: a.name,
                    artworkUrl: a.artwork,
                    rank: i + 1,
                    onTap: () => showArtistSheet(
                        context, ref,
                        artistName: a.name),
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
}
