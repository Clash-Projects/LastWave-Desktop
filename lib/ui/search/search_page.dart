import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../components/buttons.dart' show LWTooltip, WaveChip;
import '../theme/wave_icons.dart';

import '../../app/track_actions.dart' show playGenerated;
import '../../core/audio/stream_models.dart';
import '../../features/feed/feed_repository.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/player/playback_service.dart';
import '../../features/search/search_repository.dart';
import '../components/artwork.dart';
import '../components/desktop_table.dart';
import '../components/states.dart';
import '../theme/tokens.dart';

/// Live search providers, shared with the Ctrl+K palette.
///
/// Plain [FutureProvider.family] (keepAlive by default): repeat visits to
/// the same query resolve instantly and a new query never blanks the page —
/// [_CombinedResults] keeps the previous lists on screen with skeleton rows
/// for sections still pending.
final waveSearchSongsProvider = FutureProvider.family<
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
    FutureProvider.family<List<String>, String>((ref, q) async {
  if (q.trim().length < 2) return const <String>[];
  return ref.watch(searchRepositoryProvider).getSuggestions(q.trim());
});

const _tryHints = <String>[
  'Taylor Swift',
  'Lo-fi beats',
  'A. R. Rahman',
  '70s rock anthems',
  'Jazz piano',
  'Workout mix',
];

/// Search result → playable (queue key = title|artist, matching playback).
PlayableTrack playableFromSearch(SearchResultItem e) => PlayableTrack(
      title: e.name,
      artist: e.artist,
      album: e.subtitle,
      artworkUrl: e.artworkUrl,
      videoId: e.videoId,
    );

/// Rebuilt Search — Top Result + Songs + Albums + Artists + Playlists.
///
/// Typing debounce 150ms, suggestions debounce 350ms (query >= 2 chars).
/// Empty state is Recent pills (clearable) + "Try…" hints — never dead
/// space. Results never blank the page: previous lists stay visible while
/// pending sections show skeleton rows.
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
  }

  KeyEventResult _onPageKey(KeyEvent event, List<String> suggestions) {
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
            const <String>[];
    final showSuggestions = _query.isNotEmpty &&
        _submitted != _query &&
        !_suggestDismissed &&
        suggestions.isNotEmpty;
    final history = ref.watch(searchRepositoryProvider).history();

    return Focus(
      onKeyEvent: (_, e) => _onPageKey(e, suggestions),
      child: ListView(
        physics: const ClampingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(28, 22, 28, 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(maxWidth: WaveDensity.contentMax),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Search',
                      style: WaveType.pageTitle.copyWith(fontSize: 22)),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, c) => ConstrainedBox(
                      constraints: BoxConstraints(
                        // 420 + page gutters (28×2) = 476: below that the
                        // box fills content instead of overflowing.
                        maxWidth: c.maxWidth < 476 ? c.maxWidth : 420,
                      ),
                      child: SizedBox(
                        width: double.infinity,
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
                            if (showSuggestions &&
                                _suggestIndex >= 0) {
                              final pick = suggestions[
                                  _suggestIndex.clamp(
                                      0, suggestions.length - 1)];
                              _controller.text = pick;
                              _submit(pick);
                            } else {
                              _submit(v);
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                if (showSuggestions) ...[
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0;
                            i < suggestions.take(6).length;
                            i++)
                          _SuggestionRow(
                            text: suggestions[i],
                            highlighted: i == _suggestIndex,
                            onTap: () {
                              _controller.text = suggestions[i];
                              _submit(suggestions[i]);
                            },
                            onHover: () => setState(
                              () => _suggestIndex = i,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                if (_submitted.isEmpty) ...[
                  const SizedBox(height: 16),
                  if (history.isNotEmpty) ...[
                    Row(
                      children: [
                        Text('Recent',
                            style: WaveType.label.copyWith(
                                color:
                                    waveTextTertiary(context))),
                        const Spacer(),
                        HyperlinkButton(
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
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: history.take(10).map((h) {
                        return LWTooltip(
                          message: 'Search "$h"',
                          child: Focus(
                            canRequestFocus: true,
                            onKeyEvent: (node, event) {
                              if (event is KeyDownEvent &&
                                  (event.logicalKey ==
                                          LogicalKeyboardKey.enter ||
                                      event.logicalKey ==
                                          LogicalKeyboardKey.space)) {
                                _controller.text = h;
                                _submit(h);
                                return KeyEventResult.handled;
                              }
                              return KeyEventResult.ignored;
                            },
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: () {
                                  _controller.text = h;
                                  _submit(h);
                                },
                                child: WaveChip(label: h),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text('Try…',
                      style: WaveType.label.copyWith(
                          color: waveTextTertiary(context))),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _tryHints.map((h) {
                      return LWTooltip(
                        message: 'Try "$h"',
                        child: Focus(
                          canRequestFocus: true,
                          onKeyEvent: (node, event) {
                            if (event is KeyDownEvent &&
                                (event.logicalKey ==
                                        LogicalKeyboardKey.enter ||
                                    event.logicalKey ==
                                        LogicalKeyboardKey.space)) {
                              _controller.text = h;
                              _submit(h);
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () {
                                _controller.text = h;
                                _submit(h);
                              },
                              child: WaveChip(label: h),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ] else ...[
                  const SizedBox(height: 20),
                  _CombinedResults(query: _submitted),
                ],
              ],
            ),
          ),
          ),
        ],
      ),
    );
  }
}

/// Suggestion row with artwork tile — not a bare text row.
///
/// `getSuggestions` returns plain strings (no art endpoint), so the tile
/// is the standard music placeholder at 32px; layout matches result rows
/// so the dropdown reads as results, not a text list.
class _SuggestionRow extends StatefulWidget {
  final String text;
  final bool highlighted;
  final VoidCallback onTap;
  final VoidCallback onHover;
  const _SuggestionRow({
    required this.text,
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
                  url: '', size: 32, radius: WaveRadius.artwork, label: widget.text),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.body,
                ),
              ),
              Icon(WaveIcons.mixes,
                  size: 15, color: waveTextTertiary(context)),
            ],
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
            videoId: e.videoId))
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_songs.isNotEmpty ||
            _artists.isNotEmpty ||
            _albums.isNotEmpty) ...[
          Text('Top Result', style: WaveType.sectionTitle),
          const SizedBox(height: 10),
          if (_songs.isEmpty &&
              _artists.isEmpty &&
              _albums.isEmpty &&
              anyLoading)
            const _SkeletonRows(count: 1, rowHeight: 64)
          else
            _TopResult(
              song: _songs.isNotEmpty ? _songs.first : null,
              artist:
                  _artists.isNotEmpty ? _artists.first : null,
              album:
                  _albums.isNotEmpty ? _albums.first : null,
              onPrimary: _primary,
              onPlay: (h) => _playSingle(ref, context, h),
            ),
          const SizedBox(height: 24),
        ],
        // Songs — canonical desktop table (5 rows, shrink-wrapped).
        if (_songs.isNotEmpty || songsAsync.isLoading) ...[
          _SectionHead(
              label: 'Songs', loading: songsAsync.isLoading),
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
          _SectionHead(
              label: 'Albums',
              loading: albumsAsync.isLoading),
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
                  return _CoverCard(
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
                  );
                },
              ),
            ),
          const SizedBox(height: 24),
        ],
        if (_artists.isNotEmpty || artistsAsync.isLoading) ...[
          _SectionHead(
              label: 'Artists',
              loading: artistsAsync.isLoading),
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
                  return GestureDetector(
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
                  );
                },
              ),
            ),
          const SizedBox(height: 24),
        ],
        if (_playlists.isNotEmpty || playlistsAsync.isLoading) ...[
          _SectionHead(
              label: 'Playlists',
              loading: playlistsAsync.isLoading),
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
                  return _CoverCard(
                    title: p.name,
                    subtitle: p.subtitle,
                    art: p.artworkUrl,
                    size: 124,
                    onTap: () => _openPlaylist(p),
                  );
                },
              ),
            ),
        ],
      ],
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
                    url: hero.artworkUrl, size: 48, label: hero.name)
                : WaveArtwork(
                    url: hero.artworkUrl,
                    size: 48,
                    radius: WaveRadius.artwork,
                    label: hero.name,
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
      titleSortOf: (e) => e.name.toLowerCase(),
      artistSortOf: (e) => e.artist.toLowerCase(),
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


