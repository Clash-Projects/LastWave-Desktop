import 'package:fluent_ui/fluent_ui.dart';

import '../../l10n/shell_strings.dart';
import '../components/inputs.dart';
import '../theme/tokens.dart';

class SettingsSearchEntry {
  final String id;
  final String section;
  final String title;
  final String subtitle;
  final String keywords;
  const SettingsSearchEntry({
    required this.id,
    required this.section,
    required this.title,
    this.subtitle = '',
    this.keywords = '',
  });
}

List<SettingsSearchEntry> settingsSearchEntries(ShellStrings strings) {
  SettingsSearchEntry section(String id) => SettingsSearchEntry(
        id: 'section:$id',
        section: id,
        title: strings.section(id),
        keywords: id,
      );
  return [
    for (final id in const [
      'general',
      'playback',
      'audio',
      'downloads',
      'library',
      'lyrics',
      'appearance',
      'lastfm',
      'integrations',
      'sources',
      'experimental',
      'about',
    ])
      section(id),
    SettingsSearchEntry(
      id: 'general.language',
      section: 'general',
      title: strings('language'),
      subtitle: strings('languageHint'),
      keywords: 'locale language idioma sprache',
    ),
    SettingsSearchEntry(
      id: 'general.backup',
      section: 'general',
      title: strings('backup'),
      subtitle: strings('backupHint'),
      keywords: 'export import json restore backup',
    ),
    SettingsSearchEntry(
      id: 'integrations.spotify',
      section: 'integrations',
      title: strings('spotify'),
      subtitle: strings('spotifyBody'),
      keywords: 'spotify sp_dc cookie canvas login paste',
    ),
    SettingsSearchEntry(
      id: 'integrations.spotify.canvas',
      section: 'integrations',
      title: strings('spotifyCanvas'),
      subtitle: strings('spotifyCanvasHint'),
      keywords: 'canvas motion video spotify',
    ),
    SettingsSearchEntry(
      id: 'integrations.jam',
      section: 'integrations',
      title: strings('jamServer'),
      subtitle: strings('jam'),
      keywords: 'jam websocket room collaborative',
    ),
    SettingsSearchEntry(
      id: 'sources.modules',
      section: 'sources',
      title: strings('modules'),
      subtitle: strings('modulesHint'),
      keywords: 'lwp module provider addon',
    ),
    SettingsSearchEntry(
      id: 'downloads.layout',
      section: 'downloads',
      title: strings('folderLayout'),
      subtitle: strings('reorganizeHint'),
      keywords: 'folder artist album year download reorganize',
    ),
  ];
}

List<SettingsSearchEntry> filterSettings(
  List<SettingsSearchEntry> entries,
  String query,
) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  final hits = <SettingsSearchEntry>[];
  for (final entry in entries) {
    final hay =
        '${entry.title} ${entry.subtitle} ${entry.keywords} ${entry.section}'
            .toLowerCase();
    if (hay.contains(q) || (q.length >= 2 && _subsequence(hay, q))) {
      hits.add(entry);
    }
    if (hits.length >= 8) break;
  }
  return hits;
}

bool _subsequence(String hay, String needle) {
  var i = 0;
  for (final unit in hay.codeUnits) {
    if (i < needle.length && unit == needle.codeUnitAt(i)) i++;
  }
  return i == needle.length;
}

class SettingsSpotlight extends InheritedWidget {
  final String? activeId;
  const SettingsSpotlight({
    super.key,
    required this.activeId,
    required super.child,
  });

  static String? of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<SettingsSpotlight>()
        ?.activeId;
  }

  @override
  bool updateShouldNotify(SettingsSpotlight oldWidget) =>
      oldWidget.activeId != activeId;
}

class SettingsTarget extends StatefulWidget {
  final String id;
  final Widget child;
  const SettingsTarget({super.key, required this.id, required this.child});

  static final keys = <String, GlobalKey>{};

  @override
  State<SettingsTarget> createState() => _SettingsTargetState();
}

class _SettingsTargetState extends State<SettingsTarget> {
  final _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    SettingsTarget.keys[widget.id] = _key;
  }

  @override
  void didUpdateWidget(SettingsTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      if (SettingsTarget.keys[oldWidget.id] == _key) {
        SettingsTarget.keys.remove(oldWidget.id);
      }
      SettingsTarget.keys[widget.id] = _key;
    }
  }

  @override
  void dispose() {
    if (SettingsTarget.keys[widget.id] == _key) {
      SettingsTarget.keys.remove(widget.id);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = SettingsSpotlight.of(context) == widget.id;
    return Container(
      key: _key,
      decoration: BoxDecoration(
        borderRadius: WaveRadius.controlsRadius,
        border: Border.all(
          color: active ? waveAccent(context) : Colors.transparent,
          width: 1.5,
        ),
        color: active
            ? waveAccent(context).withValues(alpha: 0.08)
            : Colors.transparent,
      ),
      padding: const EdgeInsets.all(8),
      child: widget.child,
    );
  }
}

class SettingsSearchBox extends StatefulWidget {
  final List<SettingsSearchEntry> entries;
  final ValueChanged<SettingsSearchEntry> onPick;
  final String hint;
  final String empty;
  const SettingsSearchBox({
    super.key,
    required this.entries,
    required this.onPick,
    required this.hint,
    required this.empty,
  });

  @override
  State<SettingsSearchBox> createState() => _SettingsSearchBoxState();
}

class _SettingsSearchBoxState extends State<SettingsSearchBox> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hits = filterSettings(widget.entries, _query);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextBox(
          controller: _controller,
          placeholder: widget.hint,
          decoration: waveInputDecoration(),
          onChanged: (value) => setState(() => _query = value),
        ),
        if (_query.trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          if (hits.isEmpty)
            Text(
              widget.empty,
              style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
            )
          else
            for (final hit in hits)
              ListTile(
                title: Text(hit.title),
                subtitle: Text(
                  hit.subtitle.isEmpty ? hit.section : hit.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onPressed: () {
                  widget.onPick(hit);
                  _controller.clear();
                  setState(() => _query = '');
                },
              ),
        ],
      ],
    );
  }
}
