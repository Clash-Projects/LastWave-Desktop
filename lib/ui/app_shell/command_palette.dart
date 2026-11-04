import '../components/buttons.dart';
import '../components/inputs.dart';
import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/search/search_repository.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Keyboard-first command palette (Ctrl+K).
///
/// Shell placement + shortcuts (Ctrl+K open, Esc
/// close) are owned by Agent 2 in app_shell.dart — this file owns search
/// behaviour only. [showWaveCommandPalette] keeps its signature so the
/// shell never breaks: recent searches + route shortcuts + live Top
/// Result / Songs / Albums / Artists mini-sections.
Future<void> showWaveCommandPalette(
  BuildContext context, {
  required ValueChanged<String> onGo,
}) {
  final controller = TextEditingController();
  final routes = <(String path, String label, IconData icon)>[
    (('/home'), 'Go to Home', WaveIcons.home),
    (('/search'), 'Go to Search', WaveIcons.search),
    (('/liked'), 'Go to Liked Songs', WaveIcons.liked),
    (('/albums'), 'Go to Albums', FluentIcons.music_note),
    (('/artists'), 'Go to Artists', FluentIcons.contact),
    (('/playlists'), 'Go to Playlists', WaveIcons.playlists),
    (('/podcasts'), 'Go to Podcasts', FluentIcons.headset),
    (('/mixes'), 'Open Mix Lab', FluentIcons.lightbulb),
    (('/downloads'), 'Go to Downloads', FluentIcons.download),
    (('/history'), 'Go to History', WaveIcons.history),
    (('/now'), 'Open Now Playing', FluentIcons.circle_fill),
    (('/settings'), 'Open Settings', FluentIcons.settings),
  ];
  return showDialog(
    context: context,
    barrierDismissible: true,
    builder: (context) => _PaletteDialog(
      controller: controller,
      routes: routes,
      onGo: onGo,
    ),
  );
}

class _PaletteEntry {
  final String label;
  final String sub;
  final String group;
  final IconData icon;
  final VoidCallback action;
  const _PaletteEntry({
    required this.label,
    required this.sub,
    required this.group,
    required this.icon,
    required this.action,
  });
}

class _PaletteDialog extends ConsumerStatefulWidget {
  final TextEditingController controller;
  final List<(String, String, IconData)> routes;
  final ValueChanged<String> onGo;
  const _PaletteDialog({
    required this.controller,
    required this.routes,
    required this.onGo,
  });

  @override
  ConsumerState<_PaletteDialog> createState() => _PaletteDialogState();
}

class _PaletteDialogState extends ConsumerState<_PaletteDialog> {
  String _q = '';
  int _selected = 0;
  // Rides on whichever row is selected so arrow keys can scroll it into view.
  final _selectedKey = GlobalKey();

  @override
  void dispose() {
    // showWaveCommandPalette creates this controller for the dialog alone
    // and never disposed it. Children unmount first, so the TextBox has
    // already detached its listeners by the time this runs.
    widget.controller.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() {
      _q = v;
      _selected = 0;
    });
  }

  void _activate(List<_PaletteEntry> entries) {
    if (entries.isEmpty) return;
    final i = _selected.clamp(0, entries.length - 1);
    Navigator.of(context).pop();
    entries[i].action();
  }

  // The list is lazy, but the neighbour of the selected row is always inside
  // its cache extent, so the selected row exists by the next frame.
  void _revealSelected({required bool down}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOutCubic,
        alignmentPolicy: down
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    });
  }

  KeyEventResult _onKey(KeyEvent event, List<_PaletteEntry> entries) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (entries.isNotEmpty) {
        setState(() => _selected =
            (_selected + 1).clamp(0, entries.length - 1));
        _revealSelected(down: true);
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (entries.isNotEmpty) {
        setState(() => _selected =
            (_selected - 1).clamp(0, entries.length - 1));
        _revealSelected(down: false);
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
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final results = _results();
    final sel = results.isEmpty
        ? 0
        : _selected.clamp(0, results.length - 1);
    // Group consecutive entries under mini-section headers. Rows are
    // built lazily (ListView.builder below) so open only pays for
    // visible items; each row is a light _PaletteRow with NO tooltip
    // (tooltips spin up an overlay portal per row — pure open-frame
    // cost for labels that are already visible).
    final items = <Object>[];
    String? lastGroup;
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      if (r.group != lastGroup) {
        lastGroup = r.group;
        items.add(_PaletteHeader(title: r.group));
      }
      items.add(_PaletteRowData(entry: r, selected: i == sel));
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
            color: waveSurfaceRaised(context),
            borderRadius:
                const BorderRadius.all(Radius.circular(WaveRadius.floating)),
            border: Border.all(
              color: waveDivider(context),
            ),
            // Cheap open frame: blur 28/2 rasterizes a large shadow on
            // the exact frame the dialog appears; 12/0 reads the same
            // at 440px width.
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.6 : 0.2),
                blurRadius: 12,
                spreadRadius: 0,
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
                decoration: waveInputDecoration(),
                controller: widget.controller,
                autofocus: true,
                placeholder: 'Type a command…',
                prefix: const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(WaveIcons.search, size: 15),
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
                        child: const Text('No matching commands.'),
                      )
                    : ListView.builder(
                        physics: const ClampingScrollPhysics(),
                        itemCount: items.length,
                        itemBuilder: (context, i) {
                          final item = items[i];
                          if (item is _PaletteHeader) {
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  10, 10, 10, 2),
                              child: Text(
                                item.title.toUpperCase(),
                                style: WaveType.overline.copyWith(
                                  fontSize: 9,
                                  color: waveTextTertiary(context),
                                ),
                              ),
                            );
                          }
                          final row = item as _PaletteRowData;
                          return _PaletteRow(
                            key: row.selected ? _selectedKey : null,
                            entry: row.entry,
                            selected: row.selected,
                            onTap: () {
                              Navigator.of(context).pop();
                              row.entry.action();
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        actions: [
          WaveButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// Mini-section header marker for the lazy results list.
class _PaletteHeader {
  final String title;
  const _PaletteHeader({required this.title});
}

/// Row payload: entry + selection state, rendered by [_PaletteRow].
class _PaletteRowData {
  final _PaletteEntry entry;
  final bool selected;
  const _PaletteRowData({required this.entry, required this.selected});
}

/// Single palette row. Stateless + tooltip-free by design: the label
/// is already visible, and each tooltip would cost an overlay portal
/// on the dialog's open frame.
class _PaletteRow extends StatelessWidget {
  final _PaletteEntry entry;
  final bool selected;
  final VoidCallback onTap;
  const _PaletteRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final r = entry;
    final leading = Icon(r.icon, size: 15);
    return ListTile.selectable(
      shape: RoundedRectangleBorder(
        borderRadius: WaveRadius.controlsRadius,
      ),
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
      onPressed: onTap,
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
