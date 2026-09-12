import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../design_system/icons.dart';

import '../../core/storage/prefs.dart';
import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
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

/// Top artists grid (personal when signed in, charts for guests).
class ArtistsScreen extends ConsumerWidget {
  const ArtistsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artists = ref.watch(_artistsProvider);
    return artists.when(
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
        title: 'Could not load artists',
        subtitle: e.toString(),
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(_artistsProvider),
      ),
      data: (list) => GridView.builder(
        padding: const EdgeInsets.fromLTRB(
            LwSpacing.lg, LwSpacing.lg, LwSpacing.lg, 96),
        gridDelegate:
            const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 190,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          mainAxisExtent: 218,
        ),
        itemCount: list.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return const _GridHeader(
                title: 'Artists',
                subtitle:
                    'Your most-played voices this month.');
          }
          final a = list[i - 1];
          return _ArtistCard(name: a.name, artwork: a.artwork);
        },
      ),
    );
  }
}

class _GridHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  const _GridHeader(
      {required this.title, required this.subtitle});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: LwType.display),
          const SizedBox(height: 4),
          Text(subtitle,
              style: LwType.body.copyWith(
                  color: LwColors.textSecondary)),
        ],
      ),
    );
  }
}

class _ArtistCard extends ConsumerWidget {
  final String name;
  final String artwork;
  const _ArtistCard({required this.name, required this.artwork});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onTap: () =>
          showArtistSheet(context, ref, artistName: name),
      borderRadius: BorderRadius.circular(LwRadius.md),
      child: Padding(
        padding: const EdgeInsets.all(LwSpacing.xs),
        child: Column(
          children: [
            _RoundArt(name: name, url: artwork),
            const SizedBox(height: 8),
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: LwType.title
                    .copyWith(fontSize: 12.5)),
          ],
        ),
      ),
    );
  }
}

class _RoundArt extends StatelessWidget {
  final String name;
  final String url;
  const _RoundArt({required this.name, required this.url});
  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return CircleAvatar(
        radius: 56,
        backgroundColor: LwColors.surfaceOverlay,
        child: Text(name.isNotEmpty ? name[0] : '?',
            style: LwType.display
                .copyWith(color: LwColors.textTertiary)),
      );
    }
    return CircleAvatar(
        radius: 56, backgroundImage: NetworkImage(url));
  }
}
