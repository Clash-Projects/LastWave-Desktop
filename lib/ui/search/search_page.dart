import 'dart:async';
import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../components/buttons.dart' show LWTooltip;
import '../theme/wave_icons.dart';

import '../../app/track_actions.dart'
    show formatDuration, playGenerated;
import '../../core/audio/stream_models.dart';
import '../../features/feed/feed_repository.dart';
import '../../features/home/home_providers.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/player/playback_service.dart';
import '../../features/search/search_repository.dart';
import '../components/artwork.dart';
import '../components/desktop_table.dart';
import '../components/states.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

/// Live search providers, shared with the Ctrl+K palette.
///
/// Plain [FutureProvider.family] (keepAlive by default): repeat visits to
/// the same query resolve instantly and a new query never blanks the page —
/// [_CombinedResults] keeps the previous lists on screen with skeleton rows
/// for sections still pending.
final waveSearchSongsProvider = FutureProvider.autoDispose.family<
    List<SearchResultItem>, String>((ref, q) {
  if (q.trim().isEmpty) return Future.value(const <SearchResultItem>[]);
  return ref.watch(searchRepositoryProvider).search(SearchTab.tracks, q);
});
final waveSearchAlbumsProvider = FutureProvider.family<
    List<SearchResultItem>, String>((ref, q) {
  if (q.trim().isEmpty) return Future.value(const <SearchResultItem>[]);
  return ref.watch(searchRepositoryProvider).search(SearchTab.albums, q);
});
final waveSearchArtistsProvider = FutureProvider.family<
    List<SearchResultItem>, String>((ref, q) {
  if (q.trim().isEmpty) return Future.value(const <SearchResultItem>[]);
  return ref.watch(searchRepositoryProvider).search(SearchTab.artists, q);
});
final waveSearchPlaylistsProvider = FutureProvider.family<
    List<SearchResultItem>, String>((ref, q) {
  if (q.trim().isEmpty) return Future.value(const <SearchResultItem>[]);
  return ref.watch(searchRepositoryProvider).search(SearchTab.playlists, q);
});
final waveSuggestionsProvider =
    FutureProvider.family<List<SearchSuggestion>, String>((ref, q) async {
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
  int _suggestIndex = -1;
  bool _suggestDismissed = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
    _query = widget.initialQuery;
    _suggestQuery = widget.initialQuery;
    _submitted = widget.initialQuery;
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
      setState(() => _suggestIndex =
          (_suggestIndex + 1).clamp(0, suggestions.length - 1));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _suggestIndex =
          (_suggestIndex - 1).clamp(0, suggestions.length - 1));
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
                controller: _controller,
                focusNode: _focus,
                autofocus: true,
                placeholder: 'Songs, artists, albums…',
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
                    final pick = suggestions[
                        _suggestIndex.clamp(0, suggestions.length - 1)];
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
                    for (var i = 0; i < suggestions.take(6).length; i++)
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
            const SizedBox(height: 20),
            _CombinedResults(query: _submitted),
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
    final dark = waveIsDark(context);
    final active = widget.highlighted || _hover;
    final s = widget.suggestion;
    final isArtist = s.tab == SearchTab.artists;
    return MouseRegion(
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
                ? (dark ? Colors.white : Colors.black)
                    .withValues(alpha: WaveState.hoverAlpha)
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
            HyperlinkButton(
              onPressed: onClear,
              child: Text('Clear',
                  style: WaveType.label.copyWith(color: WaveColors.danger)),
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
    return Focus(
      canRequestFocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onOpen();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onOpen,
          child: AnimatedContainer(
            duration: WaveMotion.fast,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _hover
                  ? (dark ? WaveColors.surfaceOverlay : WaveColors.lightOverlay)
                  : (dark ? WaveColors.surface : WaveColors.lightSurface),
              borderRadius: BorderRadius.circular(WaveRadius.controls),
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
                    child: IconButton(
                      icon: Icon(WaveIcons.close,
                          size: 12, color: waveTextTertiary(context)),
                      onPressed: widget.onRemove,
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

class _BrowseCategories extends ConsumerWidget {
  final ValueChanged<String> onOpen;
  const _BrowseCategories({required this.onOpen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final charts =
        ref.watch(feedProvider).valueOrNull?.charts ?? const <GeneratedTrack>[];
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
                    artworkUrl: charts.isEmpty
                        ? ''
                        : charts[i % charts.length].artworkUrl,
                    onTap: () => onOpen(_browseCategories[i].query),
                  ),
                ),
            ],
          );
        }),
      ],
    );
  }
}

class _BrowseTile extends StatefulWidget {
  final String name;
  final Color tint;
  final String artworkUrl;
  final VoidCallback onTap;
  const _BrowseTile({
    required this.name,
    required this.tint,
    required this.artworkUrl,
    required this.onTap,
  });
  @override
  State<_BrowseTile> createState() => _BrowseTileState();
}

class _BrowseTileState extends State<_BrowseTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 1.015 : 1,
          duration: WaveMotion.fast,
          curve: Curves.easeOutCubic,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(WaveRadius.menu),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: widget.tint),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        widget.tint,
                        Color.lerp(widget.tint, Colors.black, 0.35)!,
                      ],
                    ),
                  ),
                ),
                if (widget.artworkUrl.isNotEmpty)
                  Positioned(
                    right: -18,
                    bottom: -22,
                    child: Transform.rotate(
                      angle: 0.22,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius:
                              BorderRadius.circular(WaveRadius.artwork),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 12,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: WaveArtwork(
                          url: widget.artworkUrl,
                          size: 92,
                          radius: WaveRadius.artwork,
                          title: widget.name,
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 12,
                  right: 56,
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

class _CombinedResults extends ConsumerStatefulWidget {
  final String query;
  const _CombinedResults({required this.query});
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

  Future<void> _playSongs(
      WidgetRef ref, BuildContext context, int start) async {
    if (_songs.isEmpty) return;
    final generated = _songs
        .map((e) => GeneratedTrack(
            name: e.name,
            artist: e.artist,
            artworkUrl: e.artworkUrl,
            videoId: e.videoId,
            durationSeconds: e.durationSeconds))
        .toList();
    final at = start.clamp(0, generated.length - 1);
    await playGenerated(ref, context, generated[at],
        sourceLabel: 'Search',
        queueAll: generated,
        startIndex: at);
  }

  Future<void> _playSingle(
      WidgetRef ref, BuildContext context, SearchResultItem hero) async {
    await playGenerated(
        ref,
        context,
        GeneratedTrack(
            name: hero.name,
            artist: hero.artist,
            artworkUrl: hero.artworkUrl,
            videoId: hero.videoId),
        sourceLabel: 'Top result');
  }

  /// Primary action keeps hierarchy: artist → artist page, album →
  /// album page, song → play. (Previous build re-searched on artist tap
  /// and dwarfed the hero at 92px.)
  void _primary(SearchResultItem hero) {
    switch (hero.tab) {
      case SearchTab.artists:
        if (hero.name.isNotEmpty) {
          context.go('/artist/${Uri.encodeComponent(hero.name)}');
        }
      case SearchTab.albums:
        if (hero.entityId.isNotEmpty) {
          context.go('/album/${Uri.encodeComponent(hero.entityId)}');
        }
      case SearchTab.playlists:
        _openPlaylist(hero);
      case SearchTab.tracks:
        if (hero.videoId.isNotEmpty) _playSingle(ref, context, hero);
      case SearchTab.users:
        break;
    }
  }

  void _openPlaylist(SearchResultItem item) {
    // Local playlists live at /playlists/:id (int). YouTube Music
    // playlist ids (VLPL…) can't route there, so they play in place.
    final id = int.tryParse(item.entityId);
    if (id != null) {
      context.go('/playlists/$id');
      return;
    }
    _openCollection(item);
  }

  Future<void> _openCollection(SearchResultItem item) async {
    final tube = ref.read(innerTubeProvider);
    List<YouTubeMusicTrack> tracks = const [];
    try {
      if (item.tab == SearchTab.playlists) {
        final pl = await tube.fetchPlaylist(item.entityId);
        tracks = pl?.tracks ?? const [];
      } else {
        tracks = await tube.browseSongs(item.entityId, limit: 50);
      }
    } catch (_) {
      return;
    }
    if (tracks.isEmpty || !mounted) return;
    final generated = tracks
        .map((t) => GeneratedTrack(
            name: t.title,
            artist: t.artist,
            artworkUrl: t.artworkUrl,
            videoId: t.videoId))
        .toList();
    await playGenerated(ref, context, generated.first,
        sourceLabel: item.name, queueAll: generated);
  }

  @override
  Widget build(BuildContext context) {
    final songsAsync = ref.watch(waveSearchSongsProvider(widget.query));
    final albumsAsync =
        ref.watch(waveSearchAlbumsProvider(widget.query));
    final artistsAsync =
        ref.watch(waveSearchArtistsProvider(widget.query));
    final playlistsAsync =
        ref.watch(waveSearchPlaylistsProvider(widget.query));

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

    final anyLoading = songsAsync.isLoading ||
        albumsAsync.isLoading ||
        artistsAsync.isLoading ||
        playlistsAsync.isLoading;
    final allEmpty = _songs.isEmpty &&
        _albums.isEmpty &&
        _artists.isEmpty &&
        _playlists.isEmpty;

    if (allEmpty && !anyLoading) {
      final anyError = songsAsync.hasError ||
          albumsAsync.hasError ||
          artistsAsync.hasError ||
          playlistsAsync.hasError;
      return Padding(
        padding: const EdgeInsets.only(top: 20),
        child: WaveEmpty(
          icon: anyError ? FluentIcons.error : WaveIcons.search,
          title: anyError ? 'Search failed' : 'No results',
          subtitle: anyError
              ? 'Check your connection and try again.'
              : 'Try a different artist, album or track.',
        ),
      );
    }

    // Stagger slots for the results cascade (one per section).
    var e = 0;
    int slot() => e++;
    return WaveEntranceGroup(
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_songs.isNotEmpty ||
            _artists.isNotEmpty ||
            _albums.isNotEmpty) ...[
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
                  _albums.isNotEmpty ? _albums.first : null,
              onPrimary: _primary,
              onPlay: (h) => _playSingle(ref, context, h),
            ),
            ),
          const SizedBox(height: 24),
        ],
        // Songs — canonical desktop table (5 rows, shrink-wrapped).
        if (_songs.isNotEmpty || songsAsync.isLoading) ...[
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
              onPlay: (i) => _playSongs(ref, context, i),
            ),
          const SizedBox(height: 24),
        ],
        if (_albums.isNotEmpty || albumsAsync.isLoading) ...[
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
                itemCount: _albums.take(8).length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: 12),
                itemBuilder: (context, i) {
                  final a = _albums[i];
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
                        context.go(
                            '/album/${Uri.encodeComponent(a.entityId)}');
                      }
                    },
                  ),
                  );
                },
              ),
            ),
          const SizedBox(height: 24),
        ],
        if (_artists.isNotEmpty || artistsAsync.isLoading) ...[
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
                itemCount: _artists.take(8).length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: 16),
                itemBuilder: (context, i) {
                  final a = _artists[i];
                  return WaveEntrance(
                    index: i,
                    rise: 10,
                    child: GestureDetector(
                    onTap: () => context.go(
                        '/artist/${Uri.encodeComponent(a.name)}'),
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
                  ),
                  );
                },
              ),
            ),
          const SizedBox(height: 24),
        ],
        if (_playlists.isNotEmpty || playlistsAsync.isLoading) ...[
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
                itemCount: _playlists.take(8).length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: 12),
                itemBuilder: (context, i) {
                  final p = _playlists[i];
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
                                  BorderRadius.circular(3))),
                      const SizedBox(height: 6),
                      Container(
                          height: 9,
                          width: 120,
                          decoration: BoxDecoration(
                              color: wash,
                              borderRadius:
                                  BorderRadius.circular(3))),
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
                        BorderRadius.circular(3))),
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
    return GestureDetector(
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
              GestureDetector(
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
              )
            else
              Icon(WaveIcons.chevronRight,
                  size: 16, color: waveTextTertiary(context)),
          ],
        ),
      ),
    );
  }
}

class _SongsTable extends ConsumerWidget {
  final List<SearchResultItem> songs;
  final void Function(int index) onPlay;
  const _SongsTable({required this.songs, required this.onPlay});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playingKey = ref.watch(
      playbackServiceProvider.select((s) => s.current?.queueKey),
    );
    final shown = songs.take(5).toList();
    String keyOf(SearchResultItem e) =>
        '${e.name.toLowerCase()}|${e.artist.toLowerCase()}';
    return WaveDesktopTable<SearchResultItem>(
      shrinkWrap: true,
      playOnSingleTap: true,
      showArtistColumn: false,
      items: shown,
      keyOf: keyOf,
      titleOf: (e) => e.name,
      subtitleOf: (e) => e.artist,
      albumOf: (e) => e.subtitle,
      artworkOf: (e) => e.artworkUrl,
      playableOf: (e) => playableFromSearch(e),
      durationOf: (e) => e.durationSeconds > 0
          ? formatDuration(Duration(seconds: e.durationSeconds))
          : '',
      durationSortOf: (e) => e.durationSeconds,
      titleSortOf: (e) => e.name.toLowerCase(),
      isCurrent: (e) => playingKey == keyOf(e),
      isPlaying: (e) =>
          playingKey == keyOf(e) &&
          ref.watch(playbackServiceProvider
              .select((s) => s.isPlaying)),
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
    return GestureDetector(
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
    );
  }
}


