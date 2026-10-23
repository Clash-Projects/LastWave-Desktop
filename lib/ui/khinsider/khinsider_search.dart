import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/khinsider/khinsider_client.dart';
import '../../features/khinsider/khinsider_parser.dart';
import '../components/buttons.dart';
import '../components/shelf.dart';
import '../components/skeletons.dart';
import '../components/states.dart';
import '../navigation/wave_nav.dart';
import '../theme/tokens.dart';

final _khSearchProvider = FutureProvider.autoDispose
    .family<List<KhAlbumSummary>, String>(
      (ref, q) => ref.watch(khInsiderClientProvider).search(q),
    );

final _khPlatformsProvider = FutureProvider<List<(String, String)>>(
  (ref) => ref.watch(khInsiderClientProvider).platforms(),
);

/// "Video game soundtracks" search mode: KHInsider album results for
/// [query], or with no query the Popular / Platform / Year lists.
class WaveKhInsiderSearch extends ConsumerWidget {
  final String query;
  const WaveKhInsiderSearch({super.key, required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (query.trim().isEmpty) return const _KhBrowse();
    if (query.trim().length < 3) {
      return const WaveEmpty(
        icon: FluentIcons.search,
        title: 'Type at least 3 characters',
        subtitle: 'KHInsider refuses shorter searches.',
      );
    }
    return ref
        .watch(_khSearchProvider(query.trim()))
        .when(
          loading: () => const SkeletonRow(count: 6),
          error: (e, _) => WaveError(
            title: 'KHInsider search failed',
            message: '$e',
            onRetry: () => ref.invalidate(_khSearchProvider(query.trim())),
          ),
          data: (albums) => albums.isEmpty
              ? WaveEmpty(
                  icon: FluentIcons.search,
                  title: 'No soundtrack found',
                  subtitle: 'Nothing on KHInsider matches "$query".',
                )
              : _KhAlbumGrid(albums: albums),
        );
  }
}

class _KhBrowse extends ConsumerStatefulWidget {
  const _KhBrowse();
  @override
  ConsumerState<_KhBrowse> createState() => _KhBrowseState();
}

class _KhBrowseState extends ConsumerState<_KhBrowse> {
  KhBrowseList _list = KhInsiderParser.popularLists.first;
  final _albums = <KhAlbumSummary>[];
  int _page = 0;
  bool _hasNext = true;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  void _open(KhBrowseList list) {
    setState(() {
      _list = list;
      _albums.clear();
      _page = 0;
      _hasNext = true;
      _error = null;
    });
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasNext) return;
    final list = _list;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(khInsiderClientProvider)
          .albumList(list, page: _page + 1);
      if (!mounted || !identical(list, _list)) return;
      setState(() {
        final seen = {for (final a in _albums) a.id};
        _albums.addAll(page.albums.where((a) => seen.add(a.id)));
        _page = page.page;
        _hasNext = page.hasNext && page.albums.isNotEmpty;
      });
    } catch (e) {
      if (mounted && identical(list, _list)) setState(() => _error = e);
    } finally {
      if (mounted && identical(list, _list)) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final platforms =
        ref.watch(_khPlatformsProvider).valueOrNull ??
        KhInsiderParser.mainPlatforms;
    final thisYear = DateTime.now().year;
    final label = WaveType.meta.copyWith(color: waveTextTertiary(context));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Popular', style: label),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final l in KhInsiderParser.popularLists)
              ToggleButton(
                checked: _list.id == l.id,
                onChanged: (_) => _open(l),
                child: Text(l.title),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Platform', style: label),
            ComboBox<String>(
              placeholder: const Text('Choose'),
              value: _list.id.startsWith('platform:')
                  ? _list.id.substring('platform:'.length)
                  : null,
              items: [
                for (final (slug, name) in platforms)
                  ComboBoxItem(value: slug, child: Text(name)),
              ],
              onChanged: (slug) {
                if (slug == null) return;
                final name = platforms
                    .firstWhere((p) => p.$1 == slug, orElse: () => (slug, slug))
                    .$2;
                _open(KhInsiderParser.platformList(slug, name));
              },
            ),
            Text('Year', style: label),
            ComboBox<int>(
              placeholder: const Text('Choose'),
              value: _list.id.startsWith('year:')
                  ? int.tryParse(_list.id.substring('year:'.length))
                  : null,
              items: [
                for (var y = thisYear; y >= 1975; y--)
                  ComboBoxItem(value: y, child: Text('$y')),
              ],
              onChanged: (y) {
                if (y != null) _open(KhInsiderParser.yearList(y));
              },
            ),
          ],
        ),
        const SizedBox(height: 18),
        Text(_list.title, style: WaveType.sectionTitle),
        const SizedBox(height: 10),
        if (_albums.isNotEmpty) _KhAlbumGrid(albums: _albums),
        if (_error != null)
          WaveError(
            title: 'Could not load KHInsider',
            message: '$_error',
            onRetry: _loadMore,
          )
        else if (_loading)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: SkeletonRow(count: 3),
          )
        else if (_albums.isEmpty)
          const WaveEmpty(
            icon: FluentIcons.album,
            title: 'No albums here',
            subtitle: 'KHInsider lists nothing for this choice.',
          )
        else if (_hasNext)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: WaveButton(
              onPressed: _loadMore,
              child: const Text('Load more'),
            ),
          ),
      ],
    );
  }
}

class _KhAlbumGrid extends StatelessWidget {
  final List<KhAlbumSummary> albums;
  const _KhAlbumGrid({required this.albums});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 18,
      children: [
        for (final a in albums)
          SizedBox(
            width: 160,
            child: WaveMediaCard(
              title: a.name,
              subtitle: [
                a.platform,
                a.year,
              ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
              artworkUrl: a.thumbnailUrl ?? '',
              onTap: () =>
                  waveOpen(context, '/khinsider/${Uri.encodeComponent(a.id)}'),
            ),
          ),
      ],
    );
  }
}
