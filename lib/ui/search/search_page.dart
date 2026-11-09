import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../components/buttons.dart' show LWTooltip, WaveLink;
import '../components/inputs.dart';
import '../theme/wave_icons.dart';

import '../../app/track_actions.dart'
    show formatDuration;
import '../../core/audio/stream_models.dart';
import '../../core/storage/prefs.dart';
import '../../features/lastfm/home_repository.dart';
import '../../features/home/home_providers.dart';
import '../../features/player/playback_service.dart';
import '../../features/podcasts/podcast_models.dart';
import '../../features/podcasts/podcast_repository.dart';
import '../../features/feed/genre_browse.dart';
import '../../features/search/search_repository.dart';
import '../components/artwork.dart';
import '../components/desktop_table.dart';
import '../components/states.dart';
import '../podcasts/podcasts_page.dart';
import '../navigation/wave_nav.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

/// Live search providers, shared with the Ctrl+K palette.
///
/// Plain [FutureProvider.family] (keepAlive by default): repeat visits to
/// the same query resolve instantly and a new query never blanks the page —
/// [_CombinedResults] keeps the previous lists on screen with skeleton rows
/// for sections still pending.
final waveSearchSongsProvider = FutureProvider.autoDispose.family<
    List<SearchResultItem>, ({String query, String catalogProvider})>(
  (ref, args) {
    if (args.query.trim().isEmpty) {
      return Future.value(const <SearchResultItem>[]);
    }
    return ref.watch(searchRepositoryProvider).search(
      SearchTab.tracks,
      args.query,
      catalogProvider: args.catalogProvider,
    );
  },
);
// NOTE: ALL query-keyed families must be autoDispose — every distinct
// keystroke prefix otherwise lives in the container forever with its
// results (songs already was; albums/artists/playlists/suggestions
// were not — unbounded retention per search session).
final waveSearchAlbumsProvider = FutureProvider.autoDispose.family<
    List<SearchResultItem>, String>((ref, q) {
  if (q.trim().isEmpty) return Future.value(const <SearchResultItem>[]);
  return ref.watch(searchRepositoryProvider).search(SearchTab.albums, q);
});
final waveSearchArtistsProvider = FutureProvider.autoDispose.family<
    List<SearchResultItem>, String>((ref, q) {
  if (q.trim().isEmpty) return Future.value(const <SearchResultItem>[]);
  return ref.watch(searchRepositoryProvider).search(SearchTab.artists, q);
});
final waveSearchPlaylistsProvider = FutureProvider.autoDispose.family<
    List<SearchResultItem>, String>((ref, q) {
  if (q.trim().isEmpty) return Future.value(const <SearchResultItem>[]);
  return ref.watch(searchRepositoryProvider).search(SearchTab.playlists, q);
});

/// Last.fm people. [enabled] stays false for ordinary song queries so a
/// music search does not spend a user.getinfo / user.search call.
final waveSearchUsersProvider = FutureProvider.autoDispose.family<
    List<SearchResultItem>, ({String q, bool enabled})>((ref, arg) {
  if (!arg.enabled || arg.q.trim().length < 2) {
    return Future.value(const <SearchResultItem>[]);
  }
  return ref.watch(searchRepositoryProvider).search(SearchTab.users, arg.q);
});
final waveSuggestionsProvider = FutureProvider.autoDispose
    .family<List<SearchSuggestion>, String>((ref, q) async {
  if (q.trim().length < 2) return const <SearchSuggestion>[];
  return ref.watch(searchRepositoryProvider).getSuggestions(q.trim());
});

final waveSearchPreviewProvider = FutureProvider.autoDispose
    .family<SearchResultItem?, String>((ref, q) {
  if (q.trim().isEmpty) return Future.value(null);
  return ref.watch(searchRepositoryProvider).previewForQuery(q.trim());
});

const _browseCategories = <({String name, Color tint, String query})>[
  (name: 'Hip-Hop/Rap', tint: Color(0xFFC45C1A), query: 'hip hop'),
  (name: 'Pop', tint: Color(0xFFC45A88), query: 'pop'),
  (name: 'R&B', tint: Color(0xFF7A4FC4), query: 'r&b soul'),
  (name: 'Electronic', tint: Color(0xFF1A8A8A), query: 'electronic'),
  (name: 'Rock', tint: Color(0xFFB03A4A), query: 'rock'),
  (name: 'Jazz', tint: Color(0xFF2E6B8A), query: 'jazz'),
  (name: 'Indie', tint: Color(0xFF3D8A62), query: 'indie'),
  (name: 'K-Pop', tint: Color(0xFFC44A7A), query: 'k-pop'),
  (name: 'Latin', tint: Color(0xFFC46A2A), query: 'latin'),
  (name: 'Classical', tint: Color(0xFF5A6A7A), query: 'classical'),
  (name: 'Country', tint: Color(0xFF8A6A2E), query: 'country'),
  (name: 'Afrobeats', tint: Color(0xFFC48A1A), query: 'afrobeats'),
  (name: 'Charts', tint: Color(0xFF4A6AC4), query: 'top hits'),
  (name: 'Chill', tint: Color(0xFF3A7A8A), query: 'chill'),
  (name: 'Workout', tint: Color(0xFFC43A3A), query: 'workout'),
];

/// Search result → playable (queue key = title|artist, matching playback).
PlayableTrack playableFromSearch(SearchResultItem e) => PlayableTrack(
      title: e.name,
      artist: e.artist,
      album: e.subtitle,
      artworkUrl: e.artworkUrl,
      videoId: e.videoId,
      duration: Duration(seconds: e.durationSeconds),
      catalogProvider: e.catalogProvider,
      isrc: e.isrc,
      externalUrl: e.externalUrl,
    );

/// Search — live results when a query is submitted; empty state is
/// Recently Searched cards + a browse-category mosaic. The search field
/// stays left-pinned so clearing recents cannot re-center the page.
class WaveSearchPage extends ConsumerStatefulWidget {
  final String initialQuery;
  const WaveSearchPage({super.key, this.initialQuery = ''});
  @override
  ConsumerState<WaveSearchPage> createState() => _WaveSearchPageState();
}

class _WaveSearchPageState extends ConsumerState<WaveSearchPage> {
  late final TextEditingController _controller;
  final FocusNode _focus = FocusNode();
  Timer? _typeDebounce;
  Timer? _suggestDebounce;
  String _query = '';
  String _suggestQuery = '';
  String _submitted = '';
  SearchTab? _filter;
  int _suggestIndex = -1;
  bool _suggestDismissed = false;
  String _catalogProvider = searchCatalogYoutubeMusic;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
    _query = widget.initialQuery;
    _suggestQuery = widget.initialQuery;
    _submitted = widget.initialQuery;
    _catalogProvider = ref.read(prefsProvider).searchCatalogProvider;
  }

  Future<void> _selectCatalogProvider(String provider) async {
    if (provider == searchCatalogTidal || provider == _catalogProvider) return;
    await ref.read(prefsProvider).setSearchCatalogProvider(provider);
    if (mounted) setState(() => _catalogProvider = provider);
  }

  @override
  void didUpdateWidget(WaveSearchPage old) {
    super.didUpdateWidget(old);
    if (old.initialQuery != widget.initialQuery) {
      _controller.text = widget.initialQuery;
      _query = widget.initialQuery;
      _suggestQuery = widget.initialQuery;
      _submitted = widget.initialQuery;
      _suggestIndex = -1;
      _suggestDismissed = false;
    }
  }

  @override
  void dispose() {
    _typeDebounce?.cancel();
    _suggestDebounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _suggestDismissed = false;
    _typeDebounce?.cancel();
    _typeDebounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) {
        setState(() {
          _query = v;
          _suggestIndex = -1;
        });
      }
    });
    _suggestDebounce?.cancel();
    _suggestDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _suggestQuery = v);
    });
  }

  void _submit(String v) {
    final q = v.trim();
    if (q.isEmpty) return;
    ref.read(searchRepositoryProvider).pushHistory(q);
    setState(() {
      _submitted = q;
      _query = q;
      _suggestQuery = q;
      _suggestIndex = -1;
      _suggestDismissed = true;
    });
    _focus.unfocus();
    context.go('/search?q=${Uri.encodeComponent(q)}');
  }

  /// Rows the dropdown actually shows. Arrow keys and Enter must stay
  /// inside it: clamping to the full list let ↓ walk onto hidden rows (no
  /// highlight visible) and Enter then searched for one of them.
  static const int _maxVisibleSuggestions = 6;
  static int _visibleSuggestionCount(List<SearchSuggestion> s) =>
      math.min(s.length, _maxVisibleSuggestions);

  KeyEventResult _onPageKey(
      KeyEvent event, List<SearchSuggestion> suggestions) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final showSuggestions = _query.isNotEmpty &&
        _submitted != _query &&
        !_suggestDismissed &&
        suggestions.isNotEmpty;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (showSuggestions) {
        setState(() {
          _suggestDismissed = true;
          _suggestIndex = -1;
        });
        return KeyEventResult.handled;
      }
      _focus.unfocus();
      return KeyEventResult.ignored;
    }
    if (!showSuggestions) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _suggestIndex = (_suggestIndex + 1)
          .clamp(0, _visibleSuggestionCount(suggestions) - 1));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _suggestIndex = (_suggestIndex - 1)
          .clamp(0, _visibleSuggestionCount(suggestions) - 1));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final suggestions =
        ref.watch(waveSuggestionsProvider(_suggestQuery)).valueOrNull ??
            const <SearchSuggestion>[];
    final showSuggestions = _query.isNotEmpty &&
        _submitted != _query &&
        !_suggestDismissed &&
        suggestions.isNotEmpty;
    final history = ref.watch(searchRepositoryProvider).history();

    final viewport = MediaQuery.sizeOf(context).width;
    final pad = viewport < 900 ? 16.0 : viewport < 1300 ? 24.0 : 28.0;
    final side =
        ((viewport - WaveDensity.contentMax) / 2).clamp(0, double.infinity) +
            pad;
    final fieldWidth = math.min(420.0, math.max(0.0, viewport - side * 2));

    return Focus(
      onKeyEvent: (_, e) => _onPageKey(e, suggestions),
      child: ListView(
        physics: const ClampingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(side, 22, side, 32),
        children: [
          WaveEntrance(
            rise: 10,
            child: Text('Search',
                style: WaveType.pageTitle.copyWith(fontSize: 22)),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: fieldWidth,
              child: TextBox(
                decoration: waveInputDecoration(),
                controller: _controller,
                focusNode: _focus,
                autofocus: true,
                placeholder: 'Songs, artists, albums, users…',
                prefix: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(WaveIcons.search,
                      size: 15,
                      color: dark
                          ? WaveColors.textTertiary
                          : WaveColors.lightTextTertiary),
                ),
                onChanged: _onChanged,
                onSubmitted: (v) {
                  if (showSuggestions && _suggestIndex >= 0) {
                    final pick = suggestions[_suggestIndex.clamp(
                        0, _visibleSuggestionCount(suggestions) - 1)];
                    _controller.text = pick.text;
                    _submit(pick.text);
                  } else {
                    _submit(v);
                  }
                },
              ),
            ),
          ),
          if (showSuggestions) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: fieldWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0;
                        i < _visibleSuggestionCount(suggestions);
                        i++)
                      _SuggestionRow(
                        suggestion: suggestions[i],
                        highlighted: i == _suggestIndex,
                        onTap: () {
                          _controller.text = suggestions[i].text;
                          _submit(suggestions[i].text);
                        },
                        onHover: () => setState(() => _suggestIndex = i),
                      ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          _CatalogProviderSelector(
            selected: _catalogProvider,
            onSelected: _selectCatalogProvider,
          ),
          if (_submitted.isEmpty) ...[
            if (history.isNotEmpty) ...[
              const SizedBox(height: 28),
              _RecentlySearched(
                queries: history.take(8).toList(),
                onOpen: (q) {
                  _controller.text = q;
                  _submit(q);
                },
                onClear: () {
                  ref.read(searchRepositoryProvider).clearHistory();
                  setState(() {});
                },
                onRemove: (q) {
                  ref.read(searchRepositoryProvider).removeHistory(q);
                  setState(() {});
                },
              ),
            ],
            const SizedBox(height: 28),
            _BrowseCategories(onOpen: (q) {
              _controller.text = q;
              _submit(q);
            }),
          ] else ...[
            const SizedBox(height: 16),
            _ResultFilters(
              selected: _filter,
              onSelected: (tab) => setState(() => _filter = tab),
            ),
            const SizedBox(height: 16),
            _CombinedResults(
              key: ValueKey('$_submitted|$_catalogProvider|${_filter?.name}'),
              query: _submitted,
              filter: _filter,
              catalogProvider: _catalogProvider,
            ),
          ],
        ],
      ),
    );
  }
}

/// Suggestion row — catalog artist/song hits, not YouTube video complete.
class _SuggestionRow extends StatefulWidget {
  final SearchSuggestion suggestion;
  final bool highlighted;
  final VoidCallback onTap;
  final VoidCallback onHover;
  const _SuggestionRow({
    required this.suggestion,
    required this.highlighted,
    required this.onTap,
    required this.onHover,
  });
  @override
  State<_SuggestionRow> createState() => _SuggestionRowState();
}

class _SuggestionRowState extends State<_SuggestionRow> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final active = widget.highlighted || _hover;
    final s = widget.suggestion;
    final isArtist = s.tab == SearchTab.artists;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hover = true);
        widget.onHover();
      },
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active
                ? waveHoverWash(context)
                : Colors.transparent,
            borderRadius:
                BorderRadius.circular(WaveRadius.controls),
          ),
          child: Row(
            children: [
              WaveArtwork(
                url: s.artworkUrl,
                size: 32,
                radius: isArtist ? 999 : WaveRadius.artwork,
                isCircle: isArtist,
                label: s.text,
                title: s.text,
                artist: s.artist,
                kind: isArtist ? ArtworkKind.artist : ArtworkKind.track,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      s.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.body,
                    ),
                    if (s.subtitle.isNotEmpty)
                      Text(
                        s.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.meta.copyWith(
                            color: waveTextTertiary(context)),
                      ),
                  ],
                ),
              ),
              Icon(
                  isArtist ? WaveIcons.artists : WaveIcons.mixes,
                  size: 15,
                  color: waveTextTertiary(context)),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentlySearched extends StatelessWidget {
  final List<String> queries;
  final ValueChanged<String> onOpen;
  final VoidCallback onClear;
  final ValueChanged<String> onRemove;
  const _RecentlySearched({
    required this.queries,
    required this.onOpen,
    required this.onClear,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Recently Searched', style: WaveType.sectionTitle),
            const Spacer(),
            WaveLink(
              onPressed: onClear,
              child: Text('Clear',
                  style: WaveType.label.copyWith(color: waveAccent(context))),
            ),
          ],
        ),
        const SizedBox(height: 12),
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth < 560
              ? 1
              : c.maxWidth < 860
                  ? 2
                  : c.maxWidth < 1140
                      ? 3
                      : 4;
          const gap = 10.0;
          final width = (c.maxWidth - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final q in queries)
                SizedBox(
                  width: width,
                  child: _RecentSearchCard(
                    query: q,
                    onOpen: () => onOpen(q),
                    onRemove: () => onRemove(q),
                  ),
                ),
            ],
          );
        }),
      ],
    );
  }
}

class _RecentSearchCard extends ConsumerStatefulWidget {
  final String query;
  final VoidCallback onOpen;
  final VoidCallback onRemove;
  const _RecentSearchCard({
    required this.query,
    required this.onOpen,
    required this.onRemove,
  });
  @override
  ConsumerState<_RecentSearchCard> createState() =>
      _RecentSearchCardState();
}

class _RecentSearchCardState extends ConsumerState<_RecentSearchCard> {
  bool _hover = false;
  bool _pressed = false;

  String _kindLine(SearchResultItem? hit) {
    if (hit == null) return 'Search';
    switch (hit.tab) {
      case SearchTab.artists:
        return 'Artist';
      case SearchTab.tracks:
        return hit.artist.isEmpty ? 'Song' : 'Song · ${hit.artist}';
      case SearchTab.albums:
        return hit.artist.isEmpty ? 'Album' : 'Album · ${hit.artist}';
      case SearchTab.playlists:
        return 'Playlist';
      case SearchTab.users:
        return 'Listener';
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final hit =
        ref.watch(waveSearchPreviewProvider(widget.query)).valueOrNull;
    final title = hit?.name.isNotEmpty == true ? hit!.name : widget.query;
    final isArtist = hit?.tab == SearchTab.artists;
    void play() => widget.onOpen();
    return Focus(
      canRequestFocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          play();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _pressed = false;
        }),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: play,
          child: AnimatedScale(
            scale: _pressed ? 0.97 : (_hover ? 1.03 : 1.0),
            duration: waveMotion(context, WaveMotion.fast),
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: waveMotion(context, WaveMotion.normal),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _hover
                    ? waveSurfaceOverlay(context)
                    : waveSurface(context),
                borderRadius: BorderRadius.circular(WaveRadius.controls),
                boxShadow: [
                  if (_hover)
                    BoxShadow(
                      color: Colors.black.withValues(
                          alpha: dark ? 0.45 : 0.18),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                ],
              ),
              child: Row(
                children: [
                  WaveArtwork(
                    url: hit?.artworkUrl ?? '',
                    size: 48,
                    radius: isArtist ? 999 : WaveRadius.artwork,
                    isCircle: isArtist,
                    label: title,
                    title: title,
                    artist: hit?.artist ?? '',
                    kind: isArtist ? ArtworkKind.artist : ArtworkKind.track,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.trackTitle),
                        Text(_kindLine(hit),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.meta.copyWith(
                              color: waveTextTertiary(context))),
                    ],
                  ),
                ),
                if (_hover)
                  LWTooltip(
                    message: 'Remove',
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: IconButton(
                      icon: Icon(WaveIcons.close,
                          size: 12, color: waveTextTertiary(context)),
                      onPressed: widget.onRemove,
                    )),
                  ),
              ],
            ),
          ),
        ),
      ),
    )
    );
  }
}

class _BrowseCategories extends ConsumerWidget {
  final ValueChanged<String> onOpen;
  const _BrowseCategories({required this.onOpen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Browse Categories', style: WaveType.sectionTitle),
        const SizedBox(height: 12),
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth < 560
              ? 2
              : c.maxWidth < 860
                  ? 3
                  : c.maxWidth < 1140
                      ? 4
                      : 5;
          const gap = 10.0;
          final width = (c.maxWidth - gap * (cols - 1)) / cols;
          final height = (width / 1.72).clamp(96.0, 128.0);
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (var i = 0; i < _browseCategories.length; i++)
                SizedBox(
                  width: width,
                  height: height,
                  child: _BrowseTile(
                    name: _browseCategories[i].name,
                    tint: _browseCategories[i].tint,
                    query: _browseCategories[i].query,
                    startIndex: i * 3,
                    onTap: () => context.go(
                      '/genre/${Uri.encodeComponent(_browseCategories[i].query)}'
                      '?name=${Uri.encodeComponent(_browseCategories[i].name)}',
                    ),
                  ),
                ),
            ],
          );
        }),
      ],
    );
  }
}

class _BrowseTile extends ConsumerStatefulWidget {
  final String name;
  final Color tint;
  final String query;
  final int startIndex;
  final VoidCallback onTap;
  const _BrowseTile({
    required this.name,
    required this.tint,
    required this.query,
    required this.startIndex,
    required this.onTap,
  });
  @override
  ConsumerState<_BrowseTile> createState() => _BrowseTileState();
}

class _BrowseTileState extends ConsumerState<_BrowseTile> {
  // Covers come from THIS genre's own songs, requested a little after the
  // page opens (staggered) so 15 searches do not fire at once.
  bool _load = false;
  List<String> _pool = const [];
  bool _hover = false;
  int _step = 0;
  Timer? _timer;
  Timer? _start;

  @override
  void initState() {
    super.initState();
    Timer(Duration(milliseconds: 200 + (widget.startIndex ~/ 3) * 250), () {
      if (mounted) setState(() => _load = true);
    });
    // Staggered start so tiles change one after another, not together.
    _start = Timer(Duration(milliseconds: 4000 + (widget.startIndex % 15) * 700),
        () {
      if (!mounted) return;
      _timer = Timer.periodic(const Duration(seconds: 10), (_) {
        if (mounted && _pool.length > 1) setState(() => _step++);
      });
      if (_pool.length > 1) setState(() => _step++);
    });
  }

  @override
  void dispose() {
    _start?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  String get _url =>
      _pool.isEmpty ? '' : _pool[(_step * 3) % _pool.length];

  @override
  Widget build(BuildContext context) {
    if (_load) {
      final tracks =
          ref.watch(genreTracksProvider(widget.query)).valueOrNull ?? const [];
      _pool = {
        for (final t in tracks)
          if (t.artworkUrl.isNotEmpty) t.artworkUrl,
      }.toList(growable: false);
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 1.05 : 1,
          duration: waveMotion(context, WaveMotion.fast),
          curve: Curves.easeOutCubic,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(WaveRadius.menu),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: widget.tint),
                // Cover as a translucent background, crossfading to the
                // next one every few seconds.
                if (_url.isNotEmpty)
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 1400),
                    child: Opacity(
                      key: ValueKey(_url),
                      opacity: 0.5,
                      child: SizedBox.expand(
                        child: CachedNetworkImage(
                          imageUrl: _url,
                          fit: BoxFit.cover,
                          memCacheWidth: 400,
                          fadeInDuration: Duration.zero,
                          errorWidget: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                // Tint merges the image into the tile; deepens toward
                // the label so the name stays readable.
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        widget.tint.withValues(alpha: 0.45),
                        Color.lerp(widget.tint, Colors.black, 0.55)!
                            .withValues(alpha: 0.80),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Text(
                    widget.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.trackTitle.copyWith(
                      fontSize: 16,
                      color: Colors.white,
                      height: 1.15,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CatalogProviderSelector extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onSelected;
  const _CatalogProviderSelector({
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('TRACK CATALOG', style: WaveType.overline),
        ToggleButton(
          checked: selected == searchCatalogYoutubeMusic,
          onChanged: (_) => onSelected(searchCatalogYoutubeMusic),
          child: const Text('YouTube Music'),
        ),
        ToggleButton(
          checked: selected == searchCatalogAppleMusic,
          onChanged: (_) => onSelected(searchCatalogAppleMusic),
          child: const Text('Apple Music'),
        ),
        const Tooltip(
          message: 'TIDAL API use is pending authorization for this app.',
          child: ToggleButton(
            checked: false,
            onChanged: null,
            child: Text('TIDAL · approval needed'),
          ),
        ),
      ],
    );
  }
}

class _ResultFilters extends StatelessWidget {
  final SearchTab? selected;
  final ValueChanged<SearchTab?> onSelected;
  const _ResultFilters({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    const items = <(SearchTab?, String)>[
      (null, 'All'),
      (SearchTab.tracks, 'Songs'),
      (SearchTab.albums, 'Albums'),
      (SearchTab.artists, 'Artists'),
      (SearchTab.playlists, 'Playlists'),
      (SearchTab.users, 'Users'),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in items)
          ToggleButton(
            checked: selected == item.$1,
            onChanged: (_) => onSelected(item.$1),
            child: Text(item.$2),
          ),
      ],
    );
  }
}

class _CombinedResults extends ConsumerStatefulWidget {
  final String query;
  final SearchTab? filter;
  final String catalogProvider;
  const _CombinedResults({
    super.key,
    required this.query,
    required this.catalogProvider,
    this.filter,
  });
  @override
  ConsumerState<_CombinedResults> createState() =>
      _CombinedResultsState();
}

class _CombinedResultsState extends ConsumerState<_CombinedResults> {
  // Previous lists stay on screen while a new query loads — the page is
  // never blanked. Assigned during build when fresh data arrives.
  List<SearchResultItem> _songs = const [];
  List<SearchResultItem> _albums = const [];
  List<SearchResultItem> _artists = const [];
  List<SearchResultItem> _playlists = const [];
  List<SearchResultItem> _users = const [];

  bool _show(SearchTab tab) =>
      widget.filter == null || widget.filter == tab;

  Future<void> _playSongs(WidgetRef ref, int start) async {
    if (_songs.isEmpty) return;
    // Search rankings are not a listening queue: play ONLY the tapped
    // track and let endless radio (Settings → Playback) pick what
    // follows, instead of the next-best search match.
    final e = _songs[start.clamp(0, _songs.length - 1)];
    await ref.read(playbackServiceProvider.notifier).playQueue(
      [playableFromSearch(e)],
      0,
      sourceLabel: 'Search',
      endlessRadio: ref.read(prefsProvider).autoplaySimilar,
    );
  }

  Future<void> _playSingle(WidgetRef ref, SearchResultItem hero) async {
    await ref.read(playbackServiceProvider.notifier).playQueue(
      [playableFromSearch(hero)],
      0,
      sourceLabel: 'Top result',
      endlessRadio: ref.read(prefsProvider).autoplaySimilar,
    );
  }

  /// Primary action keeps hierarchy: artist → artist page, album →
  /// album page, song → play. (Previous build re-searched on artist tap
  /// and dwarfed the hero at 92px.)
  void _primary(SearchResultItem hero) {
    switch (hero.tab) {
      case SearchTab.artists:
        if (hero.name.isNotEmpty) {
          waveOpen(context, '/artist/${Uri.encodeComponent(hero.name)}');
        }
      case SearchTab.albums:
        if (hero.entityId.isNotEmpty) {
          waveOpen(
              context,
              waveAlbumLocation(
                browseId: hero.entityId,
                title: hero.name,
                artist: hero.artist,
                artworkUrl: hero.artworkUrl,
              ));
        }
      case SearchTab.playlists:
        _openPlaylist(hero);
      case SearchTab.tracks:
        _playSingle(ref, hero);
      case SearchTab.users:
        _openUser(hero);
    }
  }

  void _openUser(SearchResultItem user) {
    final name = user.entityId.isNotEmpty ? user.entityId : user.name;
    if (name.isEmpty) return;
    ref.read(viewingProfileProvider.notifier).view(name);
    context.go('/profile');
  }

  void _openPlaylist(SearchResultItem item) {
    // Local playlists live at /playlists/:id (int). YouTube Music
    // playlists open the read-only YT detail page — never auto-play
    // on tap; playback starts from inside the detail page.
    final id = int.tryParse(item.entityId);
    if (id != null) {
      context.go('/playlists/$id');
      return;
    }
    waveOpen(context, '/ytplaylist/${item.entityId}'
        '?title=${Uri.encodeComponent(item.name)}'
        '&art=${Uri.encodeComponent(item.artworkUrl)}');
  }

  @override
  Widget build(BuildContext context) {
    final songsAsync = ref.watch(waveSearchSongsProvider((
      query: widget.query,
      catalogProvider: widget.catalogProvider,
    )));
    final albumsAsync =
        ref.watch(waveSearchAlbumsProvider(widget.query));
    final artistsAsync =
        ref.watch(waveSearchArtistsProvider(widget.query));
    final playlistsAsync =
        ref.watch(waveSearchPlaylistsProvider(widget.query));
    final showSongs = _show(SearchTab.tracks);
    final showAlbums = _show(SearchTab.albums);
    final showArtists = _show(SearchTab.artists);
    final showPlaylists = _show(SearchTab.playlists);
    final showUsers = widget.filter == SearchTab.users ||
        (widget.filter == null &&
            ref
                .read(searchRepositoryProvider)
                .looksLikeLastFmUser(widget.query));
    final usersAsync = ref.watch(waveSearchUsersProvider((
      q: widget.query,
      enabled: showUsers,
    )));
    final lastFmReady = ref.watch(prefsProvider).lastFmApiKey.isNotEmpty;
    final podcastsOn = ref.watch(prefsProvider).podcastsEnabled &&
        widget.query.trim().isNotEmpty &&
        widget.filter == null;
    final podcastAsync = ref.watch(podcastSearchProvider(widget.query));
    final episodes = podcastsOn
        ? (podcastAsync.valueOrNull ?? const <PodcastEpisode>[])
        : const <PodcastEpisode>[];

    if (songsAsync.hasValue) {
      _songs = songsAsync.value ?? _songs;
    }
    if (albumsAsync.hasValue) {
      _albums = albumsAsync.value ?? _albums;
    }
    if (artistsAsync.hasValue) {
      _artists = artistsAsync.value ?? _artists;
    }
    if (playlistsAsync.hasValue) {
      _playlists = playlistsAsync.value ?? _playlists;
    }
    if (usersAsync.hasValue) {
      _users = usersAsync.value ?? _users;
    }

    final anyLoading = (showSongs && songsAsync.isLoading) ||
        (showAlbums && albumsAsync.isLoading) ||
        (showArtists && artistsAsync.isLoading) ||
        (showPlaylists && playlistsAsync.isLoading) ||
        (showUsers && usersAsync.isLoading) ||
        (podcastsOn && podcastAsync.isLoading);
    final allEmpty = (!showSongs || _songs.isEmpty) &&
        (!showAlbums || _albums.isEmpty) &&
        (!showArtists || _artists.isEmpty) &&
        (!showPlaylists || _playlists.isEmpty) &&
        (!showUsers || _users.isEmpty) &&
        episodes.isEmpty;

    if (widget.filter == SearchTab.users && !lastFmReady && _users.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 20),
        child: WaveEmpty(
          icon: WaveIcons.friends,
          title: 'Connect Last.fm to search people',
          subtitle: 'User search uses the Last.fm API key from Settings.',
          actionLabel: 'Open Settings',
          onAction: () => context.go('/settings?section=lastfm'),
        ),
      );
    }

    if (allEmpty && !anyLoading) {
      final anyError = (showSongs && songsAsync.hasError) ||
          (showAlbums && albumsAsync.hasError) ||
          (showArtists && artistsAsync.hasError) ||
          (showPlaylists && playlistsAsync.hasError) ||
          (showUsers && usersAsync.hasError);
      final usersOnly = widget.filter == SearchTab.users;
      return Padding(
        padding: const EdgeInsets.only(top: 20),
        child: WaveEmpty(
          icon: anyError ? FluentIcons.error : WaveIcons.search,
          title: anyError
              ? 'Search failed'
              : (usersOnly ? 'No users' : 'No results'),
          subtitle: anyError
              ? (songsAsync.error?.toString() ??
                  'Check your connection and try again.')
              : (usersOnly
                  ? 'No Last.fm users match that name.'
                  : 'Try a different artist, album or track.'),
        ),
      );
    }

    // Taste ranking: the YTM lists arrive in anonymous global
    // relevance order, so re-sort albums/playlists by affinity when
    // the feed has loaded. Empty affinities (signed out / loading)
    // fall back to shelf order — never blank, never wait.
    final affinities =
        ref.watch(feedProvider).valueOrNull?.tasteAffinities ??
            const <String, double>{};
    final rankedAlbums = rankSearchAlbumsByTaste(_albums, affinities);
    final rankedPlaylists =
        rankSearchPlaylistsByTaste(_playlists, affinities);

    // Stagger slots for the results cascade (one per section).
    var e = 0;
    int slot() => e++;
    return WaveEntranceGroup(
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showUsers) ...[
          WaveEntrance(
            index: slot(),
            rise: 8,
            child: _SectionHead(
              label: 'Users',
              loading: lastFmReady && usersAsync.isLoading && _users.isEmpty,
            ),
          ),
          const SizedBox(height: 8),
          if (!lastFmReady)
            Text(
              'Connect Last.fm in Settings to search people.',
              style: WaveType.meta.copyWith(
                color: waveTextSecondary(context),
              ),
            )
          else if (_users.isEmpty && usersAsync.isLoading)
            const _SkeletonRows(count: 3)
          else if (_users.isEmpty)
            Text(
              'No matching Last.fm users.',
              style: WaveType.meta.copyWith(
                color: waveTextSecondary(context),
              ),
            )
          else
            for (final user in _users.take(8))
              ListTile(
                leading: WaveArtwork.circle(
                  url: user.artworkUrl,
                  size: 36,
                  label: user.name,
                  title: user.name,
                  artist: user.name,
                ),
                title: Text(user.name),
                subtitle: Text(
                  user.subtitle.isEmpty ? 'Last.fm' : user.subtitle,
                ),
                onPressed: () => _openUser(user),
              ),
          const SizedBox(height: 16),
        ],
        if (widget.filter == null &&
            (_songs.isNotEmpty ||
            _artists.isNotEmpty ||
            _albums.isNotEmpty)) ...[
          WaveEntrance(
            index: slot(),
            rise: 8,
            child:
                Text('Top Result', style: WaveType.sectionTitle),
          ),
          const SizedBox(height: 10),
          if (_songs.isEmpty &&
              _artists.isEmpty &&
              _albums.isEmpty &&
              anyLoading)
            const _SkeletonRows(count: 1, rowHeight: 64)
          else
            WaveEntrance(
              index: slot(),
              child: _TopResult(
              song: _songs.isNotEmpty ? _songs.first : null,
              artist:
                  _artists.isNotEmpty ? _artists.first : null,
              album:
                  rankedAlbums.isNotEmpty ? rankedAlbums.first : null,
              onPrimary: _primary,
              onPlay: (h) => _playSingle(ref, h),
            ),
            ),
          const SizedBox(height: 24),
        ],
        // Songs — canonical desktop table (5 rows, shrink-wrapped).
        if (showSongs && (_songs.isNotEmpty || songsAsync.isLoading)) ...[
          WaveEntrance(
            index: slot(),
            rise: 8,
            child: _SectionHead(
                label: 'Songs', loading: songsAsync.isLoading),
          ),
          const SizedBox(height: 4),
          if (_songs.isEmpty)
            const _SkeletonRows(count: 5)
          else
            _SongsTable(
              songs: _songs,
              // "All" shows the best five; picking Songs shows everything.
              limit: widget.filter == null ? 5 : null,
              onPlay: (i) => _playSongs(ref, i),
            ),
          const SizedBox(height: 24),
        ],
        if (showSongs && songsAsync.hasError) ...[
          WaveEntrance(
            index: slot(),
            rise: 8,
            child: WaveEmpty(
              icon: FluentIcons.error,
              title: widget.catalogProvider == searchCatalogAppleMusic
                  ? 'Apple Music catalog unavailable'
                  : 'Track catalog unavailable',
              subtitle: songsAsync.error?.toString() ??
                  'Could not retrieve track results.',
              actionLabel: widget.catalogProvider == searchCatalogAppleMusic
                  ? 'Open Integrations'
                  : null,
              onAction: widget.catalogProvider == searchCatalogAppleMusic
                  ? () => context.go('/settings?section=integrations')
                  : null,
            ),
          ),
          const SizedBox(height: 20),
        ],
        if (showAlbums && (_albums.isNotEmpty || albumsAsync.isLoading)) ...[
          WaveEntrance(
            index: slot(),
            rise: 8,
            child: _SectionHead(
                label: 'Albums',
                loading: albumsAsync.isLoading),
          ),
          const SizedBox(height: 10),
          if (_albums.isEmpty)
            const _SkeletonCards(count: 5, size: 124)
          else
            SizedBox(
              height: 178,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: rankedAlbums
                    .take(widget.filter == null ? 8 : 1000)
                    .length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: 12),
                itemBuilder: (context, i) {
                  final a = rankedAlbums[i];
                  return WaveEntrance(
                    index: i,
                    rise: 10,
                    child: _CoverCard(
                    title: a.name,
                    subtitle: a.artist.isNotEmpty
                        ? a.artist
                        : a.subtitle,
                    art: a.artworkUrl,
                    size: 124,
                    onTap: () {
                      if (a.entityId.isNotEmpty) {
                        waveOpen(
                            context,
                            waveAlbumLocation(
                              browseId: a.entityId,
                              title: a.name,
                              artist: a.artist.isNotEmpty
                                  ? a.artist
                                  : a.subtitle,
                              artworkUrl: a.artworkUrl,
                            ));
                      }
                    },
                  ),
                  );
                },
              ),
            ),
          const SizedBox(height: 24),
        ],
        if (showArtists && (_artists.isNotEmpty || artistsAsync.isLoading)) ...[
          WaveEntrance(
            index: slot(),
            rise: 8,
            child: _SectionHead(
                label: 'Artists',
                loading: artistsAsync.isLoading),
          ),
          const SizedBox(height: 10),
          if (_artists.isEmpty)
            const _SkeletonCards(
                count: 5, size: 96, circle: true)
          else
            SizedBox(
              height: 158,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _artists
                    .take(widget.filter == null ? 8 : 1000)
                    .length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: 16),
                itemBuilder: (context, i) {
                  final a = _artists[i];
                  return WaveEntrance(
                    index: i,
                    rise: 10,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                    onTap: () => waveOpen(
                        context, '/artist/${Uri.encodeComponent(a.name)}'),
                    child: SizedBox(
                      width: 96,
                      child: Column(
                        children: [
                          WaveArtwork.circle(
                            url: a.artworkUrl,
                            size: 96,
                            label: a.name,
                            title: a.name,
                            artist: a.name,
                          ),
                          const SizedBox(height: 6),
                          Text(a.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: WaveType.trackTitle
                                  .copyWith(fontSize: 12)),
                        ],
                      ),
                    ),
                  )),
                  );
                },
              ),
            ),
          const SizedBox(height: 24),
        ],
        if (showPlaylists &&
            (_playlists.isNotEmpty || playlistsAsync.isLoading)) ...[
          WaveEntrance(
            index: slot(),
            rise: 8,
            child: _SectionHead(
                label: 'Playlists',
                loading: playlistsAsync.isLoading),
          ),
          const SizedBox(height: 10),
          if (_playlists.isEmpty)
            const _SkeletonCards(count: 5, size: 124)
          else
            SizedBox(
              height: 178,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: rankedPlaylists
                    .take(widget.filter == null ? 8 : 1000)
                    .length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: 12),
                itemBuilder: (context, i) {
                  final p = rankedPlaylists[i];
                  return WaveEntrance(
                    index: i,
                    rise: 10,
                    child: _CoverCard(
                    title: p.name,
                    subtitle: p.subtitle,
                    art: p.artworkUrl,
                    size: 124,
                    onTap: () => _openPlaylist(p),
                  ),
                  );
                },
              ),
            ),
        ],
        if (podcastsOn &&
            (episodes.isNotEmpty || podcastAsync.isLoading)) ...[
          const SizedBox(height: 24),
          WaveEntrance(
            index: slot(),
            rise: 8,
            child: _SectionHead(
              label: 'Episodes',
              loading: podcastAsync.isLoading && episodes.isEmpty,
            ),
          ),
          const SizedBox(height: 4),
          if (episodes.isEmpty)
            const _SkeletonRows(count: 3)
          else
            for (var i = 0; i < episodes.length && i < 8; i++)
              PodcastEpisodeRow(
                episode: episodes[i],
                index: i,
                onPlay: () => playPodcastEpisodes(
                  ref,
                  context,
                  episodes[i],
                  queue: episodes,
                ),
              ),
        ],
      ],
      ),
    );
  }
}

class _SectionHead extends StatelessWidget {
  final String label;
  final bool loading;
  const _SectionHead({required this.label, this.loading = false});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label, style: WaveType.sectionTitle),
        if (loading) ...[
          const SizedBox(width: 8),
          const SizedBox(
            width: 12,
            height: 12,
            child: ProgressRing(strokeWidth: 2),
          ),
        ],
      ],
    );
  }
}

/// Pending-section skeleton — bounded rows, never a full-page blank.
class _SkeletonRows extends StatelessWidget {
  final int count;
  final double rowHeight;
  const _SkeletonRows({required this.count, this.rowHeight = 54});
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final wash =
        (dark ? Colors.white : Colors.black).withValues(alpha: 0.06);
    return Column(
      children: [
        for (var i = 0; i < count; i++)
          Container(
            height: rowHeight,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                const SizedBox(width: 30),
                Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                        color: wash,
                        borderRadius: BorderRadius.circular(
                            WaveRadius.artwork))),
                const SizedBox(width: 12),
                Expanded(
                  flex: 5,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Container(
                          height: 11,
                          width: 180,
                          decoration: BoxDecoration(
                              color: wash,
                              borderRadius:
                                  WaveRadius.tinyRadius)),
                      const SizedBox(height: 6),
                      Container(
                          height: 9,
                          width: 120,
                          decoration: BoxDecoration(
                              color: wash,
                              borderRadius:
                                  WaveRadius.tinyRadius)),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SkeletonCards extends StatelessWidget {
  final int count;
  final double size;
  final bool circle;
  const _SkeletonCards(
      {required this.count, required this.size, this.circle = false});
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final wash =
        (dark ? Colors.white : Colors.black).withValues(alpha: 0.06);
    return SizedBox(
      height: size + 54,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: count,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: wash,
                shape:
                    circle ? BoxShape.circle : BoxShape.rectangle,
                borderRadius: circle
                    ? null
                    : BorderRadius.circular(WaveRadius.artwork),
              ),
            ),
            const SizedBox(height: 5),
            Container(
                height: 10,
                width: size * 0.8,
                decoration: BoxDecoration(
                    color: wash,
                    borderRadius:
                        WaveRadius.tinyRadius)),
          ],
        ),
      ),
    );
  }
}

/// Top Result — compact 64px so it never dwarfs the 124px album cards
/// or the 96px artist circles below it.
class _TopResult extends StatelessWidget {
  final SearchResultItem? song;
  final SearchResultItem? artist;
  final SearchResultItem? album;
  final void Function(SearchResultItem hero) onPrimary;
  final void Function(SearchResultItem hero) onPlay;
  const _TopResult({
    this.song,
    this.artist,
    this.album,
    required this.onPrimary,
    required this.onPlay,
  });
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    // Prefer artist > album > song as the hero.
    final hero = artist ?? album ?? song;
    if (hero == null) return const SizedBox.shrink();
    final isArtist = hero == artist;
    final playable = hero.videoId.isNotEmpty;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
      onTap: () => onPrimary(hero),
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        color: Colors.transparent,
        child: Row(
          children: [
            isArtist
                ? WaveArtwork.circle(
                    url: hero.artworkUrl,
                    size: 48,
                    label: hero.name,
                    title: hero.name,
                    artist: hero.name)
                : WaveArtwork(
                    url: hero.artworkUrl,
                    size: 48,
                    radius: WaveRadius.artwork,
                    label: hero.name,
                    title: hero.name,
                    artist: hero.artist,
                  ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: (dark ? Colors.white : Colors.black)
                          .withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      hero.tab.name.toUpperCase(),
                      style: WaveType.overline.copyWith(fontSize: 9),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(hero.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.trackTitle
                          .copyWith(fontSize: 15)),
                  Text(
                      hero.artist.isNotEmpty
                          ? hero.artist
                          : hero.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.meta.copyWith(
                          color: waveTextSecondary(context))),
                ],
              ),
            ),
            if (playable)
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                onTap: () => onPlay(hero),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dark ? Colors.white : Colors.black,
                  ),
                  child: Icon(WaveIcons.play,
                      size: 15,
                      color: dark ? Colors.black : Colors.white),
                ),
              ))
            else
              Icon(WaveIcons.chevronRight,
                  size: 16, color: waveTextTertiary(context)),
          ],
        ),
      ),
    ));
  }
}

class _SongsTable extends ConsumerWidget {
  final List<SearchResultItem> songs;
  final int? limit;
  final void Function(int index) onPlay;
  const _SongsTable({
    required this.songs,
    required this.onPlay,
    this.limit,
  });
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playingKey = ref.watch(
      playbackServiceProvider.select((s) => s.current?.queueKey),
    );
    final isPlaying = ref.watch(
      playbackServiceProvider.select((s) => s.isPlaying),
    );
    final shown = limit == null ? songs : songs.take(limit!).toList();
    String keyOf(SearchResultItem e) => playableFromSearch(e).queueKey;
    return WaveDesktopTable<SearchResultItem>(
      shrinkWrap: true,
      playOnSingleTap: true,
      showArtistColumn: false,
      items: shown,
      keyOf: keyOf,
      titleOf: (e) => e.name,
      subtitleOf: (e) => e.catalogProvider == searchCatalogAppleMusic
          ? '${e.artist} · Apple Music'
          : e.artist,
      albumOf: (e) => e.subtitle,
      artworkOf: (e) => e.artworkUrl,
      playableOf: (e) => playableFromSearch(e),
      durationOf: (e) => e.durationSeconds > 0
          ? formatDuration(Duration(seconds: e.durationSeconds))
          : '',
      durationSortOf: (e) => e.durationSeconds,
      titleSortOf: (e) => e.name.toLowerCase(),
      isCurrent: (e) => playingKey == keyOf(e),
      isPlaying: (e) => playingKey == keyOf(e) && isPlaying,
      onPlay: onPlay,
    );
  }
}

class _CoverCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String art;
  final double size;
  final VoidCallback onTap;
  const _CoverCard(
      {required this.title,
      required this.subtitle,
      required this.art,
      required this.size,
      required this.onTap});
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: size,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            WaveArtwork(
                url: art,
                size: size,
                radius: WaveRadius.artwork,
                label: title),
            const SizedBox(height: 5),
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    WaveType.trackTitle.copyWith(fontSize: 12)),
            Text(subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.meta.copyWith(fontSize: 11)),
          ],
        ),
      ),
    ));
  }
}


