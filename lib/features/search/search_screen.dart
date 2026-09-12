import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../design_system/icons.dart';

import '../../design_system/components.dart';
import '../../design_system/tokens.dart';
import '../innertube/innertube_api.dart';
import '../lastfm/home_repository.dart';
import '../home/home_screen.dart' show playGenerated;
import 'search_repository.dart';
import '../feed/feed_repository.dart';

final _suggestionsProvider = FutureProvider.autoDispose
    .family<List<String>, String>((ref, query) async {
  if (query.trim().length < 2) return const [];
  return ref
      .watch(searchRepositoryProvider)
      .getSuggestions(query.trim());
});

final _resultsProvider = FutureProvider.autoDispose
    .family<List<SearchResultItem>, ({SearchTab tab, String query})>(
        (ref, args) {
  return ref
      .watch(searchRepositoryProvider)
      .search(args.tab, args.query);
});

/// Desktop search: field + suggestions + history + tabbed results.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});
  @override
  ConsumerState<SearchScreen> createState() =>
      _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  String _query = '';
  String _submitted = '';
  SearchTab _tab = SearchTab.tracks;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => setState(() => _query = v),
    );
  }

  void _submit(String v) {
    final q = v.trim();
    if (q.isEmpty) return;
    ref.read(searchRepositoryProvider).pushHistory(q);
    setState(() {
      _submitted = q;
      _query = q;
    });
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final history =
        ref.watch(searchRepositoryProvider).history();
    final suggestions =
        ref.watch(_suggestionsProvider(_query)).valueOrNull ?? const [];
    final showSuggestions =
        _focus.hasFocus && _query.isNotEmpty && _submitted != _query;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          LwSpacing.lg, LwSpacing.lg, LwSpacing.lg, 96),
      children: [
        const Text('Search', style: LwType.display),
        const SizedBox(height: LwSpacing.md),
        Focus(
          onFocusChange: (_) => setState(() {}),
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            onChanged: _onChanged,
            onSubmitted: _submit,
            style: LwType.body,
            decoration: InputDecoration(
              hintText: 'Songs, artists, albums, playlists, users…',
              prefixIcon: const Icon(LwIcons.search,
                  size: 16),
              suffixIcon: _controller.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(LwIcons.x,
                          size: 15),
                      onPressed: () {
                        _controller.clear();
                        setState(() {
                          _query = '';
                          _submitted = '';
                        });
                      },
                    )
                  : null,
              filled: true,
              fillColor: LwColors.surfaceRaised,
              border: OutlineInputBorder(
                borderRadius:
                    BorderRadius.circular(LwRadius.md),
                borderSide: const BorderSide(
                    color: LwColors.outline),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius:
                    BorderRadius.circular(LwRadius.md),
                borderSide: const BorderSide(
                    color: LwColors.outline),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius:
                    BorderRadius.circular(LwRadius.md),
                borderSide: BorderSide(
                    color: Theme.of(context)
                        .colorScheme
                        .primary),
              ),
            ),
          ),
        ),
        if (showSuggestions && suggestions.isNotEmpty) ...[
          const SizedBox(height: LwSpacing.xs),
          Container(
            decoration: BoxDecoration(
              color: LwColors.surfaceRaised,
              borderRadius:
                  BorderRadius.circular(LwRadius.md),
              border:
                  Border.all(color: LwColors.outlineSoft),
            ),
            child: Column(
              children: suggestions
                  .take(7)
                  .map((s) => InkWell(
                        onTap: () {
                          _controller.text = s;
                          _submit(s);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: LwSpacing.md,
                              vertical: 9),
                          child: Row(
                            children: [
                              const Icon(
                                  LwIcons.trendingUp,
                                  size: 13,
                                  color:
                                      LwColors.textTertiary),
                              const SizedBox(
                                  width: LwSpacing.sm),
                              Expanded(
                                  child: Text(s,
                                      style: LwType.body)),
                            ],
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
        ],
        if (_submitted.isEmpty) ...[
          const SizedBox(height: LwSpacing.lg),
          if (history.isNotEmpty) ...[
            Row(
              children: [
                const Text('Recent searches',
                    style: LwType.title),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    ref
                        .read(searchRepositoryProvider)
                        .clearHistory();
                    setState(() {});
                  },
                  child: const Text('Clear'),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: history
                  .map((h) => ActionChip(
                        label: Text(h),
                        onPressed: () {
                          _controller.text = h;
                          _submit(h);
                        },
                      ))
                  .toList(),
            ),
            const SizedBox(height: LwSpacing.lg),
          ],
          const EmptyState(
            icon: LwIcons.search,
            title: 'Find your next obsession',
            subtitle:
                'YouTube Music catalogue for tracks, Last.fm for people.',
          ),
        ] else ...[
          const SizedBox(height: LwSpacing.md),
          _TabBar(
            tab: _tab,
            onChanged: (t) => setState(() => _tab = t),
          ),
          const SizedBox(height: LwSpacing.sm),
          _Results(
              tab: _tab,
              query: _submitted,
              key: ValueKey('$_tab:$_submitted')),
        ],
      ],
    );
  }
}

class _TabBar extends StatelessWidget {
  final SearchTab tab;
  final ValueChanged<SearchTab> onChanged;
  const _TabBar({required this.tab, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<SearchTab>(
      segments: const [
        ButtonSegment(
            value: SearchTab.tracks,
            label: Text('Songs'),
            icon: Icon(LwIcons.music, size: 14)),
        ButtonSegment(
            value: SearchTab.artists,
            label: Text('Artists'),
            icon: Icon(LwIcons.mic, size: 14)),
        ButtonSegment(
            value: SearchTab.albums,
            label: Text('Albums'),
            icon: Icon(LwIcons.disc3, size: 14)),
        ButtonSegment(
            value: SearchTab.playlists,
            label: Text('Playlists'),
            icon:
                Icon(LwIcons.listMusic, size: 14)),
        ButtonSegment(
            value: SearchTab.users,
            label: Text('People'),
            icon: Icon(LwIcons.users, size: 14)),
      ],
      selected: {tab},
      onSelectionChanged: (s) => onChanged(s.first),
      style: SegmentedButton.styleFrom(
        textStyle: LwType.label,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _Results extends ConsumerWidget {
  final SearchTab tab;
  final String query;
  const _Results(
      {super.key, required this.tab, required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async =
        ref.watch(_resultsProvider((tab: tab, query: query)));
    return async.when(
      loading: () => const SkeletonRow(count: 8),
      error: (e, _) => EmptyState(
        icon: LwIcons.cloudOff,
        title: 'Search failed',
        subtitle: e.toString(),
      ),
      data: (items) {
        if (items.isEmpty) {
          return const EmptyState(
            icon: LwIcons.searchX,
            title: 'No results',
            subtitle: 'Try a different spelling or query.',
          );
        }
        return Column(
          children: items.map((item) {
            switch (tab) {
              case SearchTab.tracks:
                return TrackTile(
                  title: item.name,
                  subtitle: item.artist,
                  artworkUrl: item.artworkUrl,
                  onTap: () => playGenerated(
                    ref,
                    context,
                    GeneratedTrack(
                      name: item.name,
                      artist: item.artist,
                      artworkUrl: item.artworkUrl,
                      videoId: item.videoId,
                    ),
                    sourceLabel: 'Search',
                    queueAll: items
                        .map((e) => GeneratedTrack(
                              name: e.name,
                              artist: e.artist,
                              artworkUrl: e.artworkUrl,
                              videoId: e.videoId,
                            ))
                        .toList(),
                    startIndex: items.indexOf(item),
                  ),
                );
              case SearchTab.users:
                return ListTile(
                  leading: const Icon(LwIcons.user,
                      color: LwColors.textSecondary),
                  title: Text(item.name),
                  subtitle: Text(item.subtitle),
                  trailing: const Icon(
                      LwIcons.chevronRight,
                      size: 16),
                  onTap: () {
                    ref
                        .read(viewingProfileProvider
                            .notifier)
                        .view(item.entityId);
                    context.go('/profile');
                  },
                );
              default:
                return ListTile(
                  leading: Artwork(url: item.artworkUrl),
                  title: Text(item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      item.subtitle.isNotEmpty
                          ? item.subtitle
                          : item.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  trailing: const Icon(
                      LwIcons.play,
                      size: 16),
                  onTap: () => _openCollection(
                      context, ref, item),
                );
            }
          }).toList(),
        );
      },
    );
  }

  Future<void> _openCollection(BuildContext context,
      WidgetRef ref, SearchResultItem item) async {
    final tube = ref.read(innerTubeProvider);
    List<YouTubeMusicTrack> tracks = const [];
    try {
      if (item.tab == SearchTab.playlists) {
        final pl =
            await tube.fetchPlaylist(item.entityId);
        tracks = pl.tracks;
      } else {
        tracks = await tube.browseSongs(item.entityId,
            limit: 50);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed: $e')));
      }
      return;
    }
    if (tracks.isEmpty || !context.mounted) return;
    final repo = ref.read(feedRepositoryProvider);
    final generated = tracks
        .map((t) => GeneratedTrack(
              name: t.title,
              artist: t.artist,
              artworkUrl: t.artworkUrl,
              videoId: t.videoId,
            ))
        .toList();
    await playGenerated(ref, context, generated.first,
        sourceLabel: item.name,
        queueAll: generated,
        startIndex: 0);
    await repo.resolveVideos(generated);
  }
}
