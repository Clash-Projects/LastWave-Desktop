import 'package:fluent_ui/fluent_ui.dart';

import '../components/inputs.dart';
import '../theme/tokens.dart';

/// One jump target in Settings search.
///
/// [id] is the `id` of the `_Group` it scrolls to; [section] is the rail
/// section that group lives in. [keywords] lists the individual settings
/// inside the group, so a search for "crossfade" finds the Playback card.
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

/// Every searchable settings card. Keep ids in step with the `id:` passed
/// to `_Group` in `settings_page.dart`.
const settingsSearchEntries = <SettingsSearchEntry>[
  SettingsSearchEntry(
    id: 'general.behaviour',
    section: 'general',
    title: 'Behaviour',
    subtitle: 'Startup and window defaults',
    keywords: 'close button minimize tray background window startup',
  ),
  SettingsSearchEntry(
    id: 'general.language',
    section: 'general',
    title: 'Language',
    subtitle: 'Sidebar and new settings labels',
    keywords: 'language translation locale i18n',
  ),
  SettingsSearchEntry(
    id: 'general.backup',
    section: 'general',
    title: 'Backup',
    subtitle: 'Move your playlists and settings to another device',
    keywords: 'export import json restore backup playlists migrate',
  ),
  SettingsSearchEntry(
    id: 'general.diagnostics',
    section: 'general',
    title: 'Diagnostics',
    subtitle: 'Local logs for troubleshooting',
    keywords: 'logs verbose logging export log folder crash report debug',
  ),
  SettingsSearchEntry(
    id: 'playback.main',
    section: 'playback',
    title: 'Playback',
    subtitle: 'Gapless, crossfade and output behaviour',
    keywords: 'autoplay similar crossfade gapless radio queue ends',
  ),
  SettingsSearchEntry(
    id: 'audio.output',
    section: 'audio',
    title: 'Audio output',
    subtitle: 'Device, exclusive mode and bit-perfect',
    keywords: 'wasapi exclusive bit-perfect bit perfect device dac output',
  ),
  SettingsSearchEntry(
    id: 'audio.quality',
    section: 'audio',
    title: 'Streaming and Download quality',
    subtitle: 'Lossless-first with YouTube fallback',
    keywords: 'lossless hi-res flac opus prefer lossless streaming '
        'download quality bitrate',
  ),
  SettingsSearchEntry(
    id: 'audio.equalizer',
    section: 'audio',
    title: 'Equalizer & Sound FX',
    subtitle: '10-band ISO curves',
    keywords: 'eq equalizer studio master clarity preset bands sound fx',
  ),
  SettingsSearchEntry(
    id: 'downloads.offline',
    section: 'downloads',
    title: 'Offline',
    subtitle: 'Download behaviour, save location and folder layout',
    keywords: 'download lyrics lrc save location folder layout artist album '
        'year reorganize directory',
  ),
  SettingsSearchEntry(
    id: 'lyrics.timing',
    section: 'lyrics',
    title: 'Timing',
    subtitle: 'Synced lyrics providers',
    keywords: 'word by word karaoke synced lyrics provider source',
  ),
  SettingsSearchEntry(
    id: 'appearance.theme',
    section: 'appearance',
    title: 'Theme',
    subtitle: 'Midnight charcoal or pearl light',
    keywords: 'dark light midnight pearl accent colour color mode',
  ),
  SettingsSearchEntry(
    id: 'appearance.haze',
    section: 'appearance',
    title: 'Haze material',
    subtitle: 'Blur and translucency of panels',
    keywords: 'haze blur acrylic mica glass transparency intensity solid',
  ),
  SettingsSearchEntry(
    id: 'appearance.surfaces',
    section: 'appearance',
    title: 'Surfaces',
    subtitle: 'Contrast and artwork tinting',
    keywords: 'amoled black dynamic artwork theme tint now playing contrast',
  ),
  SettingsSearchEntry(
    id: 'lastfm.connection',
    section: 'lastfm',
    title: 'Last.fm connection',
    subtitle: 'Scrobbling and discovery need a session',
    keywords: 'lastfm last.fm account sign in sign out session profile',
  ),
  SettingsSearchEntry(
    id: 'lastfm.keys',
    section: 'lastfm',
    title: 'API keys',
    subtitle: 'Your own keys from last.fm/api/account/create',
    keywords: 'api key secret lastfm custom bring your own',
  ),
  SettingsSearchEntry(
    id: 'lastfm.scrobbling',
    section: 'lastfm',
    title: 'Last.fm scrobbling',
    subtitle: 'Thresholds mirror Last.fm rules',
    keywords: 'scrobble scrobbler now playing threshold percent history',
  ),
  SettingsSearchEntry(
    id: 'integrations.ytm',
    section: 'integrations',
    title: 'YouTube Music',
    subtitle: 'Personal library, history and uploads',
    keywords: 'youtube music ytm google account sign in cookies brand '
        'channel sync listening history liked songs',
  ),
  SettingsSearchEntry(
    id: 'integrations.discord',
    section: 'integrations',
    title: 'Discord',
    subtitle: 'Show what you are listening to',
    keywords: 'discord rich presence status activity',
  ),
  SettingsSearchEntry(
    id: 'sources.modules',
    section: 'sources',
    title: 'Provider modules',
    subtitle: 'Install a local .lwp module',
    keywords: 'lwp module plugin provider install',
  ),
  SettingsSearchEntry(
    id: 'sources.addons',
    section: 'sources',
    title: 'Addon sources',
    subtitle: 'Lossless catalog addons',
    keywords: 'addon url source lossless catalog provider server',
  ),
  SettingsSearchEntry(
    id: 'experimental.main',
    section: 'experimental',
    title: 'Experimental',
    subtitle: 'Opt-in desktop prototypes',
    keywords: 'extra translucency wavy seekbar timeline prototype beta',
  ),
  SettingsSearchEntry(
    id: 'about.main',
    section: 'about',
    title: 'About LastWave',
    subtitle: 'Build and project links',
    keywords: 'version update check updates github links',
  ),
];

/// Entries matching every word of [query], title matches first. Empty
/// query returns nothing.
List<SettingsSearchEntry> filterSettings(
  List<SettingsSearchEntry> entries,
  String query, {
  int limit = 8,
}) {
  final words = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return const [];
  final scored = <(int, SettingsSearchEntry)>[];
  for (final entry in entries) {
    final title = entry.title.toLowerCase();
    final hay = '$title ${entry.subtitle} ${entry.keywords} ${entry.section}'
        .toLowerCase();
    if (!words.every(hay.contains)) continue;
    // Lower is better: every word in the title, then in the subtitle.
    final inTitle = words.every(title.contains);
    final inSubtitle = words.every(entry.subtitle.toLowerCase().contains);
    scored.add((inTitle ? 0 : (inSubtitle ? 1 : 2), entry));
  }
  scored.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final hit in scored.take(limit)) hit.$2];
}

/// Id of the card to flash after a jump, shared with every
/// [SettingsTarget] below it.
class SettingsSpotlight extends InheritedWidget {
  final String? activeId;
  const SettingsSpotlight({
    super.key,
    required this.activeId,
    required super.child,
  });

  static String? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SettingsSpotlight>()
      ?.activeId;

  @override
  bool updateShouldNotify(SettingsSpotlight oldWidget) =>
      oldWidget.activeId != activeId;
}

/// Makes a settings card reachable by [id]: registers a key the page can
/// scroll to, and outlines the card while it is the spotlight. The
/// outline is painted over the card, so it changes no layout.
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
    final accent = waveAccent(context);
    return AnimatedContainer(
      key: _key,
      duration: const Duration(milliseconds: 180),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(WaveRadius.floating),
        border: Border.all(
          color: active ? accent : const Color(0x00000000),
          width: 1.5,
        ),
        color: active ? accent.withValues(alpha: 0.07) : null,
      ),
      child: widget.child,
    );
  }
}

class SettingsSearchBox extends StatefulWidget {
  final ValueChanged<SettingsSearchEntry> onPick;
  const SettingsSearchBox({super.key, required this.onPick});

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

  void _pick(SettingsSearchEntry hit) {
    widget.onPick(hit);
    _controller.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    final hits = filterSettings(settingsSearchEntries, _query);
    final searching = _query.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextBox(
          controller: _controller,
          placeholder: 'Search settings',
          prefix: const Padding(
            padding: EdgeInsets.only(left: 10),
            child: Icon(FluentIcons.search, size: 13),
          ),
          decoration: waveInputDecoration(),
          onChanged: (value) => setState(() => _query = value),
          // Enter opens the best match.
          onSubmitted: (_) {
            if (hits.isNotEmpty) _pick(hits.first);
          },
        ),
        if (searching) ...[
          const SizedBox(height: 6),
          if (hits.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Text(
                'No settings match "${_query.trim()}".',
                style: WaveType.meta.copyWith(
                  color: waveTextSecondary(context),
                ),
              ),
            )
          else
            for (final hit in hits)
              ListTile(
                title: Text(hit.title),
                subtitle: Text(
                  '${_sectionLabel(hit.section)} · ${hit.subtitle}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onPressed: () => _pick(hit),
              ),
        ],
      ],
    );
  }
}

String _sectionLabel(String id) => switch (id) {
      'lastfm' => 'Last.fm',
      _ => '${id[0].toUpperCase()}${id.substring(1)}',
    };
