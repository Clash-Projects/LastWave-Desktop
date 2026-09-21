import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/storage/prefs.dart';
import '../../features/lastfm/auth_repository.dart' show lastFmApiProvider;
import '../../features/search/shared_providers.dart';
import '../components/artwork.dart';
import '../components/menus.dart';
import '../components/states.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

final _waveArtistsProvider = FutureProvider<
    List<({String name, String artwork})>>((ref) async {
  final api = ref.watch(lastFmApiProvider);
  final apiKey = ref.watch(prefsApiKeyProvider);
  // Select username only: any other prefs change (theme, quality,
  // scrobble) must not rebuild the whole artists grid.
  final user =
      ref.watch(prefsProvider.select((p) => p.username));
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

/// Artists — 120px circle portraits with rank pill, initials fallback.
/// Tap opens the dedicated artist layout.
class WaveArtistsPage extends ConsumerWidget {
  const WaveArtistsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artists = ref.watch(_waveArtistsProvider);
    return artists.when(
      loading: () =>
          const WaveLoading(label: 'Loading artists…'),
      error: (e, _) => WaveError(
        title: 'Could not load artists',
        message: '$e',
        onRetry: () =>
            ref.invalidate(_waveArtistsProvider),
      ),
      data: (list) {
        if (list.isEmpty) {
          return const WaveEmpty(
            icon: FluentIcons.contact,
            title: 'No artists yet',
            subtitle:
                'Your most-played voices will appear here once you scrobble.',
          );
        }
        return WaveEntranceGroup(
          child: CustomScrollView(
            slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.fromLTRB(28, 22, 28, 12),
                child: WaveEntrance(
                  rise: 10,
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text('Artists',
                          style: WaveType.pageTitle
                              .copyWith(fontSize: 24)),
                      Text('${list.length} voices',
                          style: WaveType.meta.copyWith(
                              color: waveTextSecondary(
                                  context))),
                    ],
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding:
                  const EdgeInsets.fromLTRB(28, 0, 28, 28),
              sliver: SliverGrid(
                gridDelegate:
                    const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 160,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 12,
                  mainAxisExtent: 176,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final a = list[i];
                    return WaveEntrance(
                      index: i,
                      rise: 10,
                      child: _ArtistCell(
                          name: a.artwork.isNotEmpty
                              ? a.name
                              : a.name,
                          artwork: a.artwork,
                          rank: i + 1),
                    );
                  },
                  childCount: list.length,
                ),
              ),
            ),
          ],
          ),
        );
      },
    );
  }
}

class _ArtistCell extends StatefulWidget {
  final String name;
  final String artwork;
  final int rank;
  const _ArtistCell(
      {required this.name,
      required this.artwork,
      required this.rank});
  @override
  State<_ArtistCell> createState() => _ArtistCellState();
}

class _ArtistCellState extends State<_ArtistCell> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return WaveContextMenu(
      items: () => [
        MenuFlyoutItem(
          leading: const Icon(FluentIcons.contact, size: 13),
          text: const Text('Open artist'),
          onPressed: () => context.go(
              '/artist/${Uri.encodeComponent(widget.name)}'),
        ),
        MenuFlyoutItem(
          leading: const Icon(FluentIcons.search, size: 13),
          text: const Text('Search for artist'),
          onPressed: () => context.go(
              '/search?q=${Uri.encodeComponent(widget.name)}'),
        ),
      ],
      child: MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => context.go(
            '/artist/${Uri.encodeComponent(widget.name)}'),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          decoration: BoxDecoration(
            color: _hover
                ? (dark ? Colors.white : Colors.black)
                    .withValues(alpha: 0.05)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedScale(
                    scale: _hover ? 1.04 : 1.0,
                    duration:
                        const Duration(milliseconds: 110),
                    child: WaveArtwork.circle(
                        url: widget.artwork,
                        size: 120,
                        label: widget.name,
                        title: widget.name,
                        artist: widget.name),
                  ),
                  Positioned(
                    left: 8,
                    top: 0,
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: dark
                            ? WaveColors.surfaceRaised
                            : WaveColors.lightSurface,
                        borderRadius:
                            BorderRadius.circular(999),
                        border: Border.all(
                            color: dark
                                ? WaveColors.outline
                                : WaveColors
                                    .lightOutline),
                      ),
                      child: Text('${widget.rank}',
                          style: WaveType.meta.copyWith(
                              fontSize: 10,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(widget.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: WaveType.trackTitle.copyWith(
                      fontSize: 12.5,
                      color: _hover
                          ? waveAccent(context)
                          : null)),
            ],
          ),
        ),
      ),
      ),
    );
  }
}
