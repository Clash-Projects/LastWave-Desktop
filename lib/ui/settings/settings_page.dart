import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/window.dart';
import '../../app/auth_gate.dart';
import '../../core/audio/stream_models.dart';
import '../../core/env/app_env.dart';
import '../../core/storage/prefs.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/lastfm/auth_repository.dart';
import '../../features/settings/theme_controller.dart';
import '../../features/audio_output/output_controller.dart';
import '../../features/audio_output/output_path_sheet.dart';
import '../theme/tokens.dart';

const _waveSettingsSections = [
  ('general', 'General', FluentIcons.settings),
  ('playback', 'Playback', FluentIcons.play),
  ('audio', 'Audio', FluentIcons.speakers),
  ('quality', 'Quality', FluentIcons.music_note),
  ('downloads', 'Downloads', FluentIcons.download),
  ('lyrics', 'Lyrics', FluentIcons.microphone),
  ('appearance', 'Appearance', FluentIcons.brush),
  ('lastfm', 'Last.fm', FluentIcons.heart),
  ('integrations', 'Integrations', FluentIcons.link),
  ('experimental', 'Experimental', FluentIcons.bug),
  ('about', 'About', FluentIcons.info),
];

/// Fluent settings: left nav list + right form.
///
/// Reuses theme_controller + prefs logic; presentation is Fluent
/// (ToggleSwitch, Slider, ComboBox, ContentDialog) — no old ledger
/// switches or boxed groups.
class WaveSettingsPage extends ConsumerStatefulWidget {
  const WaveSettingsPage({super.key});

  @override
  ConsumerState<WaveSettingsPage> createState() =>
      _WaveSettingsPageState();
}

class _WaveSettingsPageState
    extends ConsumerState<WaveSettingsPage> {
  String _section = 'general';

  Future<void> _update(
    Future<void> Function(Prefs) fn,
  ) async {
    await fn(ref.read(prefsProvider));
    ref.read(themeControllerProvider.notifier).refresh();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Content-aware (rail-aware): LayoutBuilder sees real content
        // width, unlike MediaQuery window width (+200 rail error).
        final narrow = constraints.maxWidth < 900;
        if (narrow) {
          return ListView(
            physics: const ClampingScrollPhysics(),
            padding:
                const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Text(
                'SYSTEM',
                style: WaveType.overline.copyWith(
                  color: waveAccent(context),
                ),
              ),
              const Text(
                'Settings',
                style: WaveType.pageTitle,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in _waveSettingsSections)
                    ToggleButton(
                      checked: _section == s.$1,
                      onChanged: (_) =>
                          setState(() => _section = s.$1),
                      child: Text(s.$2),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _SectionSwap(
                child: RepaintBoundary(
                  key: ValueKey(_section),
                  child: _SectionBody(
                    section: _section,
                    onUpdate: _update,
                  ),
                ),
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 220,
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                padding:
                    const EdgeInsets.fromLTRB(24, 20, 12, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'SYSTEM',
                      style: WaveType.overline.copyWith(
                        color: waveAccent(context),
                      ),
                    ),
                    const Text(
                      'Settings',
                      style: WaveType.pageTitle,
                    ),
                    const SizedBox(height: 12),
                    for (final s in _waveSettingsSections)
                      ListTile.selectable(
                        selected: _section == s.$1,
                        selectionMode:
                            ListTileSelectionMode.single,
                        leading: Icon(s.$3, size: 15),
                        title: Text(s.$2),
                        onPressed: () =>
                            setState(() => _section = s.$1),
                      ),
                  ],
                ),
              ),
            ),
            Container(
              width: 1,
              color: waveDivider(context),
            ),
            Expanded(
              child: ListView(
                physics: const ClampingScrollPhysics(),
                padding:
                    const EdgeInsets.fromLTRB(24, 20, 24, 24),
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 640,
                    ),
                    child: _SectionSwap(
                      child: RepaintBoundary(
                        key: ValueKey(_section),
                        child: _SectionBody(
                          section: _section,
                          onUpdate: _update,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SectionBody extends ConsumerWidget {
  final String section;
  final Future<void> Function(Future<void> Function(Prefs))
      onUpdate;
  const _SectionBody({
    required this.section,
    required this.onUpdate,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (section) {
      case 'general':
        return _General(onUpdate: onUpdate);
      case 'playback':
        return _Playback(onUpdate: onUpdate);
      case 'audio':
        return _Audio(onUpdate: onUpdate);
      case 'quality':
        return _Quality(onUpdate: onUpdate);
      case 'downloads':
        return _Downloads(onUpdate: onUpdate);
      case 'appearance':
        return _Appearance(onUpdate: onUpdate);
      case 'lyrics':
        return _Lyrics(onUpdate: onUpdate);
      case 'lastfm':
        return _LastFm(onUpdate: onUpdate);
      case 'integrations':
        return const _Ytm();
      case 'experimental':
        return _Experimental(onUpdate: onUpdate);
      default:
        return const _About();
    }
  }
}

/// Section swap: fade only, size from the incoming pane, outgoing overlaid
/// at the top so it cannot re-center or relayout the list mid-transition.
class _SectionSwap extends StatelessWidget {
  final Widget child;
  const _SectionSwap({required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: WaveMotion.normal,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topLeft,
      child: AnimatedSwitcher(
        duration: WaveMotion.fast,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeOutCubic,
        layoutBuilder: (currentChild, previousChildren) {
          return Stack(
            alignment: Alignment.topLeft,
            children: [
              for (final previous in previousChildren)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: IgnorePointer(
                    child: ExcludeSemantics(child: previous),
                  ),
                ),
              ?currentChild,
            ],
          );
        },
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: child,
        ),
        child: child,
      ),
    );
  }
}

class _Group extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  const _Group({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final stroke = theme.resources.cardStrokeColorDefault;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          decoration: BoxDecoration(
            color: theme.resources.cardBackgroundFillColorDefault,
            border: Border.all(color: stroke),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: WaveType.sectionTitle),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: WaveType.meta.copyWith(
                  color: waveTextSecondary(context),
                ),
              ),
            ],
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.resources.cardBackgroundFillColorSecondary,
            border: Border(
              left: BorderSide(color: stroke),
              right: BorderSide(color: stroke),
              bottom: BorderSide(color: stroke),
            ),
            borderRadius:
                const BorderRadius.vertical(bottom: Radius.circular(6)),
          ),
          child: child,
        ),
      ],
    );
  }
}

class _Account extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs))
      onUpdate;
  const _Account({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authRepositoryProvider);
    return _Group(
      title: 'Last.fm connection',
      subtitle: 'Scrobbling and discovery need a session',
      child: Row(
        children: [
          const Icon(FluentIcons.contact, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  auth.username.isEmpty
                      ? 'Not connected'
                      : auth.username,
                  style: WaveType.trackTitle,
                ),
                Text(
                  auth.username.isEmpty
                      ? 'Connect to scrobble and personalize'
                      : 'Last.fm connected',
                  style: WaveType.meta,
                ),
              ],
            ),
          ),
          auth.username.isEmpty
              ? FilledButton(
                  onPressed: () =>
                      context.go('/welcome'),
                  child: const Text('Connect'),
                )
              : Button(
                  onPressed: () =>
                      signOutEverywhere(ref),
                  child: const Text('Sign out'),
                ),
        ],
      ),
    );
  }
}

class _Audio extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs))
      onUpdate;
  const _Audio({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    return Column(
      children: [
        _Group(
          title: 'Streaming',
          subtitle: 'Lossless-first with YouTube fallback',
          child: Column(
            children: [
              _QualityRow(
                title: 'Streaming quality',
                value: prefs.losslessQuality,
                onChanged: (q) => onUpdate(
                  (p) => p.setLosslessQuality(q),
                ),
              ),
              const SizedBox(height: 8),
              _QualityRow(
                title: 'Download quality',
                value: prefs.downloadQuality,
                onChanged: (q) => onUpdate(
                  (p) => p.setDownloadQuality(q),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _Group(
          title: 'Audio output',
          subtitle: Platform.isWindows ? 'WASAPI Exclusive bypasses the Windows mixer' : 'System audio output',
          child: _WasapiOutputSettings(onUpdate: onUpdate),
        ),
        const SizedBox(height: 8),
        _Group(
          title: 'Output',
          subtitle: 'Playback and offline behaviour',
          child: Column(
            children: [
              _SwitchRow(
                value: prefs.preferLossless,
                onChanged: (v) => onUpdate(
                  (p) => p.setPreferLossless(v),
                ),
                title: 'Prefer lossless',
                subtitle:
                    'Try lossless first, fall back to Opus',
              ),
              _SwitchRow(
                value: prefs.downloadLyrics,
                onChanged: (v) => onUpdate(
                  (p) => p.setDownloadLyrics(v),
                ),
                title: 'Download lyrics',
                subtitle:
                    'Save synced .lrc sidecars with downloads',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Appearance extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs))
      onUpdate;
  const _Appearance({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    final theme = ref.watch(themeControllerProvider);
    return Column(
      children: [
        _Group(
          title: 'Theme',
          subtitle: 'Midnight charcoal or pearl light',
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: ToggleButton(
                      checked: !theme.isLight,
                      onChanged: (_) async {
                        await ref
                            .read(themeControllerProvider
                                .notifier)
                            .setThemeMode(false);
                        await applyWindowMaterial(
                          isLight: false,
                        );
                      },
                      child: const Text('Midnight'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ToggleButton(
                      checked: theme.isLight,
                      onChanged: (_) async {
                        await ref
                            .read(themeControllerProvider
                                .notifier)
                            .setThemeMode(true);
                        await applyWindowMaterial(
                          isLight: true,
                        );
                      },
                      child: const Text('Pearl'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Accent source',
                style: WaveType.trackTitle,
              ),
              const SizedBox(height: 6),
              ComboBox<String>(
                value: theme.accentSource,
                items: const [
                  ComboBoxItem(
                      value: 'custom',
                      child: Text('Custom colour')),
                  ComboBoxItem(
                      value: 'lastwave',
                      child: Text('LastWave neutral')),
                  ComboBoxItem(
                      value: 'system',
                      child: Text('System accent')),
                  ComboBoxItem(
                      value: 'artwork',
                      child: Text('Artwork tint')),
                ],
                onChanged: (v) {
                  if (v != null) {
                    onUpdate((p) => p.setAccentSource(v));
                  }
                },
              ),
              const SizedBox(height: 10),
              const Text(
                'Accent colour',
                style: WaveType.trackTitle,
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final c in [
                    const Color(0xFFF5F4F0),
                    const Color(0xFF4CC2FF),
                    const Color(0xFFE03030),
                    const Color(0xFF7C4DFF),
                    const Color(0xFF2196C6),
                    const Color(0xFF6B9E6B),
                    const Color(0xFFE0A030),
                    const Color(0xFFE0507A),
                  ])
                    GestureDetector(
                      onTap: () => onUpdate(
                        (p) => p.setAccentColor(c.toARGB32()),
                      ),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: c,
                          border: Border.all(
                            color: theme.accent
                                        .toARGB32() ==
                                    c.toARGB32()
                                ? waveAccent(context)
                                : waveDivider(context),
                            width: 2,
                          ),
                        ),
                        child: theme.accent.toARGB32() ==
                                c.toARGB32()
                            ? Icon(
                                FluentIcons.check_mark,
                                size: 14,
                                color: c.computeLuminance() > 0.5
                                    ? Colors.black
                                    : Colors.white,
                              )
                            : null,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _Group(
          title: 'Haze material',
          subtitle:
              'Automatic uses Haze L1–L3 as designed · Solid disables blur',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ComboBox<String>(
                value: theme.hazeMaterial,
                items: const [
                  ComboBoxItem(
                      value: 'automatic',
                      child: Text('Automatic')),
                  ComboBoxItem(
                      value: 'haze', child: Text('Haze')),
                  ComboBoxItem(
                      value: 'solid', child: Text('Solid')),
                ],
                onChanged: (v) {
                  if (v != null) {
                    onUpdate((p) => p.setHazeMaterial(v));
                  }
                },
              ),
              const SizedBox(height: 10),
              const Text(
                'Haze intensity',
                style: WaveType.trackTitle,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  for (final opt in ['low', 'medium', 'high'])
                    Padding(
                      padding:
                          const EdgeInsets.only(right: 6),
                      child: ToggleButton(
                        checked: theme.hazeIntensity == opt,
                        onChanged: (_) => onUpdate(
                          (p) => p.setHazeIntensity(opt),
                        ),
                        child: Text(
                            '${opt[0].toUpperCase()}${opt.substring(1)}'),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _Group(
          title: 'Surfaces',
          subtitle: 'Contrast and artwork tinting',
          child: Column(
            children: [
              _SwitchRow(
                value: prefs.amoled,
                onChanged: (v) =>
                    onUpdate((p) => p.setAmoled(v)),
                title: 'AMOLED black',
              ),
              _SwitchRow(
                value: prefs.dynamicNowPlaying,
                onChanged: (v) => onUpdate(
                  (p) => p.setDynamicNowPlaying(v),
                ),
                title: 'Dynamic artwork theme',
                subtitle:
                    'Tint Now Playing from album art',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Lyrics extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs))
      onUpdate;
  const _Lyrics({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    return _Group(
      title: 'Timing',
      subtitle: 'Synced lyrics providers',
      child: _SwitchRow(
        value: prefs.wordByWord,
        onChanged: (v) =>
            onUpdate((p) => p.setWordByWord(v)),
        title: 'Word-by-word lyrics',
        subtitle:
            'Karaoke word highlight. Off uses Apple Music line lyrics.',
      ),
    );
  }
}

class _Scrobbler extends ConsumerStatefulWidget {
  final Future<void> Function(Future<void> Function(Prefs))
      onUpdate;
  const _Scrobbler({required this.onUpdate});

  @override
  ConsumerState<_Scrobbler> createState() => _ScrobblerState();
}

class _ScrobblerState extends ConsumerState<_Scrobbler> {
  double? _dragPercent;

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(prefsProvider);
    final percent =
        (_dragPercent ?? prefs.scrobblePercent.toDouble())
            .clamp(25, 90)
            .toDouble();
    return _Group(
      title: 'Last.fm scrobbling',
      subtitle: 'Thresholds mirror Last.fm rules',
      child: Column(
        children: [
          _SwitchRow(
            value: prefs.scrobblerEnabled,
            onChanged: (v) => widget.onUpdate(
              (p) => p.setScrobbler(enabled: v),
            ),
            title: 'Enable scrobbling',
            subtitle:
                'Requires a write-capable session',
          ),
          _SwitchRow(
            value: prefs.scrobbleNowPlaying,
            onChanged: (v) => widget.onUpdate(
              (p) => p.setScrobbler(nowPlaying: v),
            ),
            title: 'Now playing updates',
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Scrobble at ${percent.round()}% of track',
                    style: WaveType.trackTitle,
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: Slider(
                    value: percent,
                    min: 25,
                    max: 90,
                    onChanged: (v) =>
                        setState(() => _dragPercent = v),
                    onChangeEnd: (v) {
                      setState(() => _dragPercent = null);
                      widget.onUpdate(
                        (p) => p.setScrobbler(percent: v.round()),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Ytm extends ConsumerWidget {
  const _Ytm();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tube = ref.watch(innerTubeProvider);
    return _Group(
      title: 'YouTube Music',
      subtitle: 'Personal library, history and uploads',
      child: Row(
        children: [
          const Icon(FluentIcons.video, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              tube.connection.connected
                  ? 'Connected'
                  : 'Not connected',
              style: WaveType.trackTitle,
            ),
          ),
          tube.connection.connected
              ? Button(
                  onPressed: () async {
                    await tube.signOut();
                  },
                  child: const Text('Disconnect'),
                )
              : FilledButton(
                  onPressed: () =>
                      _ytConnect(context, ref),
                  child: const Text('Connect'),
                ),
        ],
      ),
    );
  }

  Future<void> _ytConnect(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final controller = TextEditingController();
    final cookies = await showDialog<String>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Connect YouTube Music'),
        content: TextBox(
          controller: controller,
          placeholder:
              '__Secure-3PAPISID=…; SAPISID=…',
        ),
        actions: [
          Button(
            onPressed: () =>
                Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context)
                .pop(controller.text.trim()),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (cookies != null && cookies.isNotEmpty) {
      await ref.read(innerTubeProvider).connect(cookies);
    }
  }
}

class _About extends StatelessWidget {
  const _About();

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri,
            mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return _Group(
      title: 'About LastWave',
      subtitle: 'Build, backend status, and project links',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'LastWave Desktop · v1.0.0',
            style: WaveType.trackTitle,
          ),
          const SizedBox(height: 2),
          Text(
            'Lossless: ${AppEnv.losslessCatalogLabel} · '
            'Lyrics key: ${AppEnv.lyricsApiKey.isNotEmpty ? 'set' : 'missing'}',
            style: WaveType.meta,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Button(
                onPressed: () => _open(
                    'https://github.com/Clash-Projects/LastWave-Desktop'),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.open_in_new_window, size: 14),
                    SizedBox(width: 6),
                    Text('GitHub repository'),
                  ],
                ),
              ),
              Button(
                onPressed: () => _open(
                    'https://github.com/Clash-Projects/LastWave-Desktop/issues'),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.error, size: 14),
                    SizedBox(width: 6),
                    Text('Report an issue'),
                  ],
                ),
              ),
              Button(
                onPressed: () => _open(
                    'https://github.com/Clash-Projects/LastWave-Desktop'),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.favorite_star, size: 14),
                    SizedBox(width: 6),
                    Text('Star / support the project'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _General extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _General({required this.onUpdate});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _Account(onUpdate: onUpdate),
        const SizedBox(height: 8),
        _Group(
          title: 'Behaviour',
          subtitle: 'Startup and window defaults',
          child: Text(
            'Last.fm sign-in is required at startup. The shell restores your last route and rail width automatically.',
            style: WaveType.meta.copyWith(
              color: waveTextSecondary(context),
            ),
          ),
        ),
      ],
    );
  }
}

class _Playback extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Playback({required this.onUpdate});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    return _Group(
      title: 'Playback',
      subtitle: 'Gapless, crossfade and output behaviour',
      child: Column(
        children: [
          _SwitchRow(
            value: prefs.crossfadeEnabled,
            onChanged: (v) async {
              await onUpdate((p) => p.setCrossfade(v));
              ref.read(audioOutputProvider.notifier).refreshPath();
            },
            title: 'Crossfade',
            subtitle:
                '${prefs.crossfadeSeconds}s · gapless otherwise',
          ),
        ],
      ),
    );
  }
}

class _Quality extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Quality({required this.onUpdate});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    return _Group(
      title: 'Streaming quality',
      subtitle: 'Lossless-first with YouTube fallback',
      child: Column(
        children: [
          _QualityRow(
            title: 'Streaming quality',
            value: prefs.losslessQuality,
            onChanged: (q) =>
                onUpdate((p) => p.setLosslessQuality(q)),
          ),
          const SizedBox(height: 8),
          _QualityRow(
            title: 'Download quality',
            value: prefs.downloadQuality,
            onChanged: (q) =>
                onUpdate((p) => p.setDownloadQuality(q)),
          ),
          const SizedBox(height: 8),
          _SwitchRow(
            value: prefs.preferLossless,
            onChanged: (v) =>
                onUpdate((p) => p.setPreferLossless(v)),
            title: 'Prefer lossless',
            subtitle: 'Try lossless first, fall back to Opus',
          ),
        ],
      ),
    );
  }
}

class _Downloads extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Downloads({required this.onUpdate});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    return _Group(
      title: 'Offline',
      subtitle: 'Download behaviour and lyrics sidecars',
      child: Column(
        children: [
          _SwitchRow(
            value: prefs.downloadLyrics,
            onChanged: (v) =>
                onUpdate((p) => p.setDownloadLyrics(v)),
            title: 'Download lyrics',
            subtitle: 'Save synced .lrc sidecars with downloads',
          ),
        ],
      ),
    );
  }
}

class _LastFm extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _LastFm({required this.onUpdate});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _Account(onUpdate: onUpdate),
        const SizedBox(height: 8),
        _Scrobbler(onUpdate: onUpdate),
      ],
    );
  }
}

class _Experimental extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Experimental({required this.onUpdate});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    return _Group(
      title: 'Experimental',
      subtitle: 'Opt-in desktop prototypes',
      child: Column(
        children: [
          _SwitchRow(
            value: prefs.liquidGlass,
            onChanged: (v) =>
                onUpdate((p) => p.setLiquidGlass(v)),
            title: 'Extra translucency',
            subtitle: 'Stronger Haze on panels (may cost FPS)',
          ),
          _SwitchRow(
            value: prefs.wavySeekbar,
            onChanged: (v) =>
                onUpdate((p) => p.setWavySeekbar(v)),
            title: 'Wavy seekbar',
            subtitle: 'Experimental timeline treatment',
          ),
        ],
      ),
    );
  }
}

class _WasapiOutputSettings extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _WasapiOutputSettings({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final output = ref.watch(audioOutputProvider);
    final notifier = ref.read(audioOutputProvider.notifier);
    final devices = output.devices;
    final selected = output.selectedId.isEmpty ? '' : output.selectedId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Device', style: WaveType.trackTitle),
        const SizedBox(height: 6),
        ComboBox<String>(
          isExpanded: true,
          value: devices.any((d) => d.id == selected) ? selected : '',
          items: [
            const ComboBoxItem(value: '', child: Text('System Default')),
            for (final d in devices)
              ComboBoxItem(
                value: d.id,
                child: Text(
                  d.isDefault ? '${d.displayName} (default)' : d.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) async {
            if (v == null) return;
            await notifier.selectDevice(v);
            await onUpdate((_) async {});
          },
        ),
        const SizedBox(height: 10),
        if (Platform.isWindows)
        _SwitchRow(
          value: output.exclusiveRequested,
          onChanged: (v) async {
            await notifier.setExclusive(v);
            await onUpdate((_) async {});
          },
          title: 'WASAPI Exclusive',
          subtitle: output.path.bitPerfect
              ? 'Mixer bypassed · bit-perfect when the DAC matches the source'
              : (output.exclusiveRequested
                  ? output.path.reason.label
                  : 'Shared mode — mixer may resample'),
        ),
        const SizedBox(height: 8),
        Text(
          output.selected == null
              ? 'Probe the DAC after connecting it to see exclusive PCM rates.'
              : output.selected!.supportedSummary,
          style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
        ),
        const SizedBox(height: 12),
        WaveStreamPathPanel(path: output.path),
      ],
    );
  }
}

class _QualityRow extends StatelessWidget {
  final String title;
  final int value;
  final ValueChanged<int> onChanged;
  const _QualityRow({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(title, style: WaveType.trackTitle),
              Text(
                AudioQualityTiers.label(value),
                style: WaveType.meta,
              ),
            ],
          ),
        ),
        ComboBox<int>(
          value: value,
          items: const [
            ComboBoxItem(
              value: 27,
              child: Text('Hi-Res · 24/192'),
            ),
            ComboBoxItem(
              value: 7,
              child: Text('Hi-Res · 24/96'),
            ),
            ComboBoxItem(
              value: 6,
              child: Text('Lossless · 16/44.1'),
            ),
            ComboBoxItem(
              value: 5,
              child: Text('320k MP3'),
            ),
            ComboBoxItem(
              value: -1,
              child: Text('Opus · YouTube'),
            ),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ],
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String? subtitle;
  const _SwitchRow({
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(title, style: WaveType.trackTitle),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: WaveType.meta.copyWith(
                      color:
                          waveTextSecondary(context),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          ToggleSwitch(
            checked: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}






