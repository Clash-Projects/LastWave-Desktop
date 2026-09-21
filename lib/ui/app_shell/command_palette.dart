import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/audio/stream_models.dart';
import '../../features/player/playback_service.dart';
import '../../features/search/search_repository.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip;
import '../search/search_page.dart';
import '../theme/tokens.dart';

/// Keyboard-first command palette (Ctrl+K).
///
/// Shell placement + shortcuts (Ctrl+K open, Ctrl+F focus search, Esc
/// close) are owned by Agent 2 in app_shell.dart — this file owns search
/// behaviour only. [showWaveCommandPalette] keeps its signature so the
/// shell never breaks: recent searches + route shortcuts + live Top
/// Result / Songs / Albums / Artists mini-sections.
Future<void> showWaveCommandPalette(
  BuildContext context, {
  required List<String> recentSearches,
  required ValueChanged<String> onSearch,
  required ValueChanged<String> onGo,
}) {
  final controller = TextEditingController();
  final routes = <(String path, String label, IconData icon)>[
    (('/home'), 'Go to Home', FluentIcons.home),
    (('/search'), 'Go to Search', FluentIcons.search),
    (('/liked'), 'Go to Liked Songs', FluentIcons.heart),
    (('/albums'), 'Go to Albums', FluentIcons.music_note),
    (('/artists'), 'Go to Artists', FluentIcons.contact),
    (('/playlists'), 'Go to Playlists', FluentIcons.list_mirrored),
    (('/mixes'), 'Open Mix Lab', FluentIcons.lightbulb),
    (('/downloads'), 'Go to Downloads', FluentIcons.download),
    (('/history'), 'Go to History', FluentIcons.history),
    (('/now'), 'Open Now Playing', FluentIcons.circle_fill),
    (('/lyrics'), 'Open Lyrics', FluentIcons.microphone),
    (('/settings'), 'Open Settings', FluentIcons.settings),
  ];
  return showDialog(
    context: context,
    barrierDismissible: true,
    builder: (context) => _PaletteDialog(
      controller: controller,
      routes: routes,
      recentSearches: recentSearches,
      onSearch: onSearch,
      onGo: onGo,
    ),
  );
}

class _PaletteEntry {
  final String label;
  final String sub;
  final String group;
  final IconData icon;
  final String art;
  final bool circleArt;
  final VoidCallback action;
  const _PaletteEntry({
    required this.label,
    required this.sub,
    required this.group,
    required this.icon,
    required this.action,
    this.art = '',
    this.circleArt = false,
  });
}

class _PaletteDialog extends ConsumerStatefulWidget {
  final TextEditingController controller;
  final List<(String, String, IconData)> routes;
  final List<String> recentSearches;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onGo;
  const _PaletteDialog({
    required this.controller,
    required this.routes,
    required this.recentSearches,
    required this.onSearch,
    required this.onGo,
  });

  @override
  ConsumerState<_PaletteDialog> createState() => _PaletteDialogState();
}

class _PaletteDialogState extends ConsumerState<_PaletteDialog> {
  String _q = '';
  String _liveQ = '';
  Timer? _debounce;
  int _selected = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() {
      _q = v;
      _selected = 0;
    });
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _liveQ = v.trim());
    });
  }

  void _activate(List<_PaletteEntry> entries) {
    if (entries.isEmpty) return;
    final i = _selected.clamp(0, entries.length - 1);
    Navigator.of(context).pop();
    entries[i].action();
  }

  KeyEventResult _onKey(KeyEvent event, List<_PaletteEntry> entries) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (entries.isNotEmpty) {
        setState(() => _selected =
            (_selected + 1).clamp(0, entries.length - 1));
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (entries.isNotEmpty) {
        setState(() => _selected =
            (_selected - 1).clamp(0, entries.length - 1));
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  List<_PaletteEntry> _results() {
    final q = _q.trim().toLowerCase();
    final out = <_PaletteEntry>[];

    if (_q.trim().isNotEmpty) {
      out.add(_PaletteEntry(
        label: 'Search for “${_q.trim()}”',
        sub: 'Search',
        group: 'Search',
        icon: FluentIcons.search,
        action: () => widget.onSearch(_q.trim()),
      ));
    }

    // Live mini-sections (debounced repo queries, shared providers).
    if (_liveQ.isNotEmpty) {
      final songs =
          ref.watch(waveSearchSongsProvider(_liveQ)).valueOrNull ??
              const <SearchResultItem>[];
      final albums =
          ref.watch(waveSearchAlbumsProvider(_liveQ)).valueOrNull ??
              const <SearchResultItem>[];
      final artists =
          ref.watch(waveSearchArtistsProvider(_liveQ)).valueOrNull ??
              const <SearchResultItem>[];
      if (songs.isNotEmpty || artists.isNotEmpty || albums.isNotEmpty) {
        final top = songs.isNotEmpty
            ? songs.first
            : (artists.isNotEmpty ? artists.first : albums.first);
        out.add(_PaletteEntry(
          label: top.name,
          sub:
              'Top Result • ${searchTabLabel(top.tab)}${top.artist.isNotEmpty ? ' • ${top.artist}' : ''}',
          group: 'Top Result',
          icon: FluentIcons.trophy,
          art: top.artworkUrl,
          circleArt: top.tab == SearchTab.artists,
          action: () => _openResult(top),
        ));
      }
      for (final s in songs.take(3)) {
        out.add(_PaletteEntry(
          label: s.name,
          sub: s.artist.isNotEmpty ? s.artist : 'Song',
          group: 'Songs',
          icon: FluentIcons.music_note,
          art: s.artworkUrl,
          action: () => _playSong(s),
        ));
      }
      for (final a in albums.take(2)) {
        out.add(_PaletteEntry(
          label: a.name,
          sub: a.artist.isNotEmpty ? a.artist : 'Album',
          group: 'Albums',
          icon: FluentIcons.album,
          art: a.artworkUrl,
          action: () {
            if (a.entityId.isNotEmpty) {
              widget.onGo(
                  '/album/${Uri.encodeComponent(a.entityId)}');
            }
          },
        ));
      }
      for (final a in artists.take(2)) {
        out.add(_PaletteEntry(
          label: a.name,
          sub: 'Artist',
          group: 'Artists',
          icon: FluentIcons.contact,
          art: a.artworkUrl,
          circleArt: true,
          action: () => widget
              .onGo('/artist/${Uri.encodeComponent(a.name)}'),
        ));
      }
    }

    for (final r in widget.routes) {
      if (q.isEmpty || r.$2.toLowerCase().contains(q)) {
        out.add(_PaletteEntry(
          label: r.$2,
          sub: 'Navigate',
          group: 'Navigate',
          icon: r.$3,
          action: () => widget.onGo(r.$1),
        ));
      }
    }
    for (final h in widget.recentSearches) {
      if (q.isEmpty || h.toLowerCase().contains(q)) {
        out.add(_PaletteEntry(
          label: 'Search “$h”',
          sub: 'Recent',
          group: 'Recent',
          icon: FluentIcons.history,
          action: () => widget.onSearch(h),
        ));
      }
    }
    return out;
  }

  void _playSong(SearchResultItem s) {
    ref.read(playbackServiceProvider.notifier).playQueue(
      [
        PlayableTrack(
          title: s.name,
          artist: s.artist,
          album: s.subtitle,
          artworkUrl: s.artworkUrl,
          videoId: s.videoId,
        ),
      ],
      0,
      sourceLabel: 'Command palette',
    );
  }

  void _openResult(SearchResultItem top) {
    switch (top.tab) {
      case SearchTab.tracks:
        _playSong(top);
      case SearchTab.artists:
        widget.onGo('/artist/${Uri.encodeComponent(top.name)}');
      case SearchTab.albums:
        if (top.entityId.isNotEmpty) {
          widget
              .onGo('/album/${Uri.encodeComponent(top.entityId)}');
        }
      case SearchTab.playlists:
        widget.onSearch(top.name);
      case SearchTab.users:
        widget.onSearch(top.name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final results = _results();
    final sel = results.isEmpty
        ? 0
        : _selected.clamp(0, results.length - 1);
    final liveLoading = _liveQ.isNotEmpty &&
        (ref.watch(waveSearchSongsProvider(_liveQ)).isLoading ||
            ref.watch(waveSearchAlbumsProvider(_liveQ)).isLoading ||
            ref.watch(waveSearchArtistsProvider(_liveQ)).isLoading);

    // Group consecutive entries under mini-section headers.
    final children = <Widget>[];
    String? lastGroup;
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      if (r.group != lastGroup) {
        lastGroup = r.group;
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 2),
            child: Text(
              r.group.toUpperCase(),
              style: WaveType.overline.copyWith(
                fontSize: 9,
                color: waveTextTertiary(context),
              ),
            ),
          ),
        );
      }
      final selected = i == sel;
      final leading = r.art.isNotEmpty
          ? (r.circleArt
              ? WaveArtwork.circle(
                  url: r.art, size: 28, label: r.label)
              : WaveArtwork(
                  url: r.art,
                  size: 28,
                  radius: WaveRadius.artwork,
                  label: r.label,
                ))
          : Icon(r.icon, size: 15);
      children.add(
        LWTooltip(
          message: r.label,
          child: ListTile.selectable(
            selected: selected,
            selectionMode: ListTileSelectionMode.single,
            leading: SizedBox(width: 28, height: 28, child: leading),
            title: Text(
              r.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              r.sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: () {
              Navigator.of(context).pop();
              r.action();
            },
          ),
        ),
      );
    }

    return Focus(
      onKeyEvent: (_, e) => _onKey(e, results),
      child: ContentDialog(
        title: const Text('Commands'),
        // Canonical dialog width (menus.dart Add-to-playlist/Properties
        // both use 440) — keeps flyouts/dialogs coherent.
        constraints: const BoxConstraints(maxWidth: 440),
        style: ContentDialogThemeData(
          decoration: BoxDecoration(
            color: dark
                ? WaveColors.surfaceRaised
                : WaveColors.lightSurfaceRaised,
            borderRadius:
                const BorderRadius.all(Radius.circular(WaveRadius.floating)),
            border: Border.all(
              color: waveDivider(context),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.6 : 0.2),
                blurRadius: 28,
                spreadRadius: 2,
                offset: const Offset(0, 8),
              ),
            ],
          ),
        ),
        content: SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextBox(
                controller: widget.controller,
                autofocus: true,
                placeholder: 'Type a command or search…',
                prefix: const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(FluentIcons.search, size: 15),
                ),
                onChanged: _onChanged,
                onSubmitted: (_) => _activate(results),
              ),
              const SizedBox(height: WaveSpacing.x8),
              ConstrainedBox(
                constraints:
                    const BoxConstraints(maxHeight: 320),
                child: results.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(16),
                        child: liveLoading
                            ? const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: ProgressRing(
                                        strokeWidth: 2),
                                  ),
                                  SizedBox(width: 8),
                                  Text('Searching…'),
                                ],
                              )
                            : Text(
                                widget.controller.text.trim().isEmpty
                                    ? 'No matches.'
                                    : 'No matches — press Enter to search for "${widget.controller.text.trim()}".',
                              ),
                      )
                    : ListView(
                        physics: const ClampingScrollPhysics(),
                        children: children,
                      ),
              ),
            ],
          ),
        ),
        actions: [
          Button(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// Search tab labels shared by the palette and the search page.
String searchTabLabel(SearchTab tab) => switch (tab) {
      SearchTab.tracks => 'Songs',
      SearchTab.artists => 'Artists',
      SearchTab.albums => 'Albums',
      SearchTab.playlists => 'Playlists',
      SearchTab.users => 'People',
    };

/// Navigate helper that preserves title/artist resolution context.
void goSearch(BuildContext context, String query) {
  context.go('/search?q=${Uri.encodeComponent(query)}');
}
