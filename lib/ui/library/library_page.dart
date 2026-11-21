import 'package:fluent_ui/fluent_ui.dart';

import '../collections/downloads_page.dart';
import 'library_browse.dart';
import '../theme/tokens.dart';

/// Library tabs. The id is the `?tab=` query value.
enum LibraryTab {
  songs('songs', 'Songs'),
  albums('albums', 'Albums'),
  artists('artists', 'Artists'),
  downloads('downloads', 'Downloads');

  final String id;
  final String label;
  const LibraryTab(this.id, this.label);

  static LibraryTab fromId(String? id) => LibraryTab.values.firstWhere(
        (t) => t.id == id,
        orElse: () => LibraryTab.values.first,
      );
}

/// Your music on this PC: local files, downloads and your own playlists,
/// managed like a desktop music player. Replaces the old Downloads page
/// (`/downloads` redirects to the Downloads tab).
class WaveLibraryPage extends StatefulWidget {
  final String? initialTab;
  const WaveLibraryPage({super.key, this.initialTab});

  @override
  State<WaveLibraryPage> createState() => _WaveLibraryPageState();
}

class _WaveLibraryPageState extends State<WaveLibraryPage> {
  late LibraryTab _tab = LibraryTab.fromId(widget.initialTab);

  @override
  void didUpdateWidget(covariant WaveLibraryPage old) {
    super.didUpdateWidget(old);
    // A link to a specific tab (e.g. the download-complete InfoBar) while
    // the page is already open.
    if (old.initialTab != widget.initialTab && widget.initialTab != null) {
      _tab = LibraryTab.fromId(widget.initialTab);
    }
  }

  Widget _body(LibraryTab tab) => switch (tab) {
        LibraryTab.songs => const LibrarySongsView(),
        LibraryTab.albums => const LibraryAlbumsView(),
        LibraryTab.artists => const LibraryArtistsView(),
        LibraryTab.downloads => const WaveDownloadsPage(showHero: false),
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Library', style: WaveType.pageTitle),
              const SizedBox(height: 10),
              LibraryTabBar(
                selected: _tab,
                onSelect: (t) => setState(() => _tab = t),
              ),
            ],
          ),
        ),
        Expanded(
          child: KeyedSubtree(key: ValueKey(_tab), child: _body(_tab)),
        ),
      ],
    );
  }
}

/// Text tabs with an accent underline on the selected one.
class LibraryTabBar extends StatelessWidget {
  final LibraryTab selected;
  final ValueChanged<LibraryTab> onSelect;
  const LibraryTabBar({
    super.key,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final accent = waveAccent(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: waveDivider(context))),
      ),
      child: Row(
        children: [
          for (final tab in LibraryTab.values)
            Semantics(
              button: true,
              selected: tab == selected,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelect(tab),
                  child: AnimatedContainer(
                    duration: waveMotion(context, WaveMotion.fast),
                    padding: const EdgeInsets.fromLTRB(2, 8, 2, 8),
                    margin: const EdgeInsets.only(right: 20),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: tab == selected
                              ? accent
                              : const Color(0x00000000),
                          width: 2,
                        ),
                      ),
                    ),
                    child: Text(
                      tab.label,
                      style: WaveType.label.copyWith(
                        fontSize: 13.5,
                        fontWeight: tab == selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: tab == selected
                            ? waveTextPrimary(context)
                            : waveTextSecondary(context),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
