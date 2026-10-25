import '../components/buttons.dart';
import '../components/inputs.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/window.dart';
import '../../app/auth_gate.dart';
import '../../core/app_info.dart';
import '../../core/audio/stream_models.dart';
import '../../core/diagnostics/diagnostics_log.dart';
import '../../core/env/app_env.dart';
import '../../core/storage/prefs.dart';
import '../../features/addons/addon_api.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/innertube/yt_library_providers.dart';
import '../../features/innertube/yt_session_keeper.dart';
import '../../features/innertube/yt_web_login.dart';
import '../components/artwork.dart';
import '../components/select.dart';
import 'yt_profile_chooser.dart';
import '../../features/home/home_providers.dart';
import '../../features/lastfm/auth_repository.dart';
import '../../features/settings/accent.dart';
import '../../features/settings/theme_controller.dart';
import '../../features/audio_output/output_controller.dart';
import '../../features/audio_output/output_path_sheet.dart';
import '../../features/lyrics/lyrics_providers.dart';
import '../theme/tokens.dart';
import '../theme/brand_icons.dart';
import '../../features/equalizer/equalizer_controller.dart';
import '../../features/equalizer/equalizer_models.dart';
import '../../features/equalizer/equalizer_panel.dart';
import '../../features/presence/discord_presence_service.dart';
import '../../features/telemetry/live_telemetry_service.dart';
import '../../features/updates/update_service.dart';
import '../updates/update_dialog.dart';
import 'backup_actions.dart';
import 'diagnostics_actions.dart';

const _waveSettingsSections = [
  ('general', 'General', FluentIcons.settings),
  ('playback', 'Playback', FluentIcons.play),
  ('audio', 'Audio', FluentIcons.speakers),
  ('downloads', 'Downloads', FluentIcons.download),
  ('lyrics', 'Lyrics', FluentIcons.microphone),
  ('appearance', 'Appearance', FluentIcons.brush),
  ('lastfm', 'Last.fm', FluentIcons.heart),
  ('integrations', 'Integrations', FluentIcons.link),
  ('sources', 'Sources', FluentIcons.cloud),
  ('experimental', 'Experimental', FluentIcons.bug),
  ('about', 'About', FluentIcons.info),
];

/// Fluent settings: left nav list + right form.
///
/// Reuses theme_controller + prefs logic; presentation is Fluent
/// (ToggleSwitch, Slider, WaveSelect, ContentDialog) — no old ledger
/// switches or boxed groups.
class WaveSettingsPage extends ConsumerStatefulWidget {
  /// Deep-link into a section rail entry (e.g. 'lastfm' from the
  /// profile empty state). Falls back to 'general' when unknown.
  final String? initialSection;
  const WaveSettingsPage({super.key, this.initialSection});

  @override
  ConsumerState<WaveSettingsPage> createState() => _WaveSettingsPageState();
}

class _WaveSettingsPageState extends ConsumerState<WaveSettingsPage> {
  late String _section;
  late final ScrollController _contentScrollController;
  late final ScrollController _narrowScrollController;
  late final ScrollController _railScrollController;

  @override
  void initState() {
    super.initState();
    _contentScrollController = ScrollController();
    _narrowScrollController = ScrollController();
    _railScrollController = ScrollController();
    final initial = widget.initialSection;
    _section =
        initial != null &&
                _waveSettingsSections.any((s) => s.$1 == initial)
            ? initial
            : 'general';
  }

  @override
  void dispose() {
    _contentScrollController.dispose();
    _narrowScrollController.dispose();
    _railScrollController.dispose();
    super.dispose();
  }

  Future<void> _update(Future<void> Function(Prefs) fn) async {
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
          return Scrollbar(
            controller: _narrowScrollController,
            interactive: true,
            child: ListView(
              controller: _narrowScrollController,
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                Text(
                  'SYSTEM',
                  style: WaveType.overline.copyWith(color: waveAccent(context)),
                ),
                const Text('Settings', style: WaveType.pageTitle),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final s in _waveSettingsSections)
                      ToggleButton(
                        checked: _section == s.$1,
                        onChanged: (_) => setState(() => _section = s.$1),
                        child: Text(s.$2),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                _SectionSwap(
                  child: RepaintBoundary(
                    key: ValueKey(_section),
                    child: _SectionBody(section: _section, onUpdate: _update),
                  ),
                ),
              ],
            ),
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 220,
              child: Scrollbar(
                controller: _railScrollController,
                interactive: true,
                child: SingleChildScrollView(
                  controller: _railScrollController,
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(24, 20, 12, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'SYSTEM',
                        style: WaveType.overline.copyWith(
                          color: waveAccent(context),
                        ),
                      ),
                      const Text('Settings', style: WaveType.pageTitle),
                      const SizedBox(height: 12),
                      for (final s in _waveSettingsSections)
                        ListTile.selectable(
                          shape: RoundedRectangleBorder(
                            borderRadius: WaveRadius.controlsRadius,
                          ),
                          selected: _section == s.$1,
                          selectionMode: ListTileSelectionMode.single,
                          leading: Icon(s.$3, size: 15),
                          title: Text(s.$2),
                          onPressed: () => setState(() => _section = s.$1),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Container(width: 1, color: waveDivider(context)),
            Expanded(
              child: Scrollbar(
                controller: _contentScrollController,
                interactive: true,
                child: ListView(
                  controller: _contentScrollController,
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
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
            ),
          ],
        );
      },
    );
  }
}

class _SectionBody extends ConsumerWidget {
  final String section;
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _SectionBody({required this.section, required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (section) {
      case 'general':
        return _General(onUpdate: onUpdate);
      case 'playback':
        return _Playback(onUpdate: onUpdate);
      case 'audio':
        return _Audio(onUpdate: onUpdate);
      case 'downloads':
        return _Downloads(onUpdate: onUpdate);
      case 'appearance':
        return _Appearance(onUpdate: onUpdate);
      case 'lyrics':
        return _Lyrics(onUpdate: onUpdate);
      case 'lastfm':
        return _LastFm(onUpdate: onUpdate);
      case 'integrations':
        return _Ytm(onUpdate: onUpdate);
      case 'sources':
        return _Sources(onUpdate: onUpdate);
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
      duration: waveMotion(context, WaveMotion.normal),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topLeft,
      child: AnimatedSwitcher(
        duration: waveMotion(context, WaveMotion.fast),
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
        transitionBuilder: (child, animation) =>
            FadeTransition(opacity: animation, child: child),
        child: child,
      ),
    );
  }
}

/// Live read of the resolved accent: swatch + where it came from.
///
/// Makes a source that cannot answer visible instead of silent — "system"
/// on a desktop that exposes no accent, or an artwork tint on a cover with
/// no hue, both keep the custom colour and say so here.
class _AccentPreview extends StatelessWidget {
  final AccentResolution resolution;
  const _AccentPreview({required this.resolution});

  @override
  Widget build(BuildContext context) {
    final argb = resolution.color.toARGB32();
    final hex =
        '#${argb.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
    final text = switch (resolution.source) {
      AccentSource.custom => 'Custom colour · $hex',
      AccentSource.lastwave => 'LastWave neutral · $hex',
      AccentSource.system => resolution.resolved
          ? 'Desktop accent · $hex'
          : 'This desktop exposes no accent — using custom colour',
      AccentSource.artwork => resolution.resolved
          ? 'Tinted from the current cover · $hex'
          : 'No cover hue to tint from — using custom colour',
    };
    return Row(
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: resolution.color,
            borderRadius: BorderRadius.circular(WaveRadius.tiny),
            border: Border.all(color: waveDivider(context)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
          ),
        ),
      ],
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
            borderRadius: const BorderRadius.vertical(top: Radius.circular(WaveRadius.floating)),
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
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(WaveRadius.floating),
            ),
          ),
          child: child,
        ),
      ],
    );
  }
}

class _Account extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Account({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authRepositoryProvider);
    final prefs = ref.watch(prefsProvider);
    final signedIn = auth.username.isNotEmpty;
    final guest = auth.status == AuthStatus.guest || prefs.isGuest;
    return _Group(
      title: 'Last.fm connection',
      subtitle: 'Scrobbling and discovery need a session',
      child: Column(
        children: [
          Row(
            children: [
              const Icon(FluentIcons.contact, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      signedIn
                          ? auth.username
                          : (guest ? 'Guest mode' : 'Not connected'),
                      style: WaveType.trackTitle,
                    ),
                    Text(
                      signedIn
                          ? 'Last.fm connected'
                          : (guest
                              ? 'Last.fm disabled — save keys below, then connect'
                              : 'Connect to scrobble and personalize'),
                      style: WaveType.meta,
                    ),
                  ],
                ),
              ),
              signedIn
                  ? WaveButton(
                      onPressed: () => signOutEverywhere(ref),
                      child: const Text('Sign out'),
                    )
                  : const SizedBox.shrink(),
            ],
          ),
          if (!signedIn) ...[
            const SizedBox(height: 10),
            const _InShellConnect(),
          ],
        ],
      ),
    );
  }
}

/// Web-auth connect that runs inside Settings (no /welcome round-trip),
/// so guests can attach Last.fm after saving keys. Mirrors the welcome
/// approval flow: open the browser, approve, finish here.
class _InShellConnect extends ConsumerStatefulWidget {
  const _InShellConnect();
  @override
  ConsumerState<_InShellConnect> createState() => _InShellConnectState();
}

class _InShellConnectState extends ConsumerState<_InShellConnect> {
  WebAuthHandshake? _handshake;
  bool _busy = false;
  String? _error;

  Future<void> _begin() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final handshake = await ref
          .read(authRepositoryProvider.notifier)
          .beginWebAuth();
      if (!mounted) return;
      setState(() => _handshake = handshake);
      final uri = Uri.parse(handshake.url);
      try {
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      setState(() => _error =
          'Could not reach Last.fm. Check your connection and retry.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    final handshake = _handshake;
    if (handshake == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authRepositoryProvider.notifier)
          .completeWebAuth(handshake.token);
      ref.invalidate(feedProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error =
          'Not approved yet — approve LastWave in the browser, then retry.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final configured = ref.watch(prefsProvider).isLastFmConfigured;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null) ...[
          Text(
            _error!,
            style: WaveType.meta.copyWith(color: Colors.red),
          ),
          const SizedBox(height: 8),
        ],
        WaveFilledButton(
          onPressed: _busy || !configured ? null : _begin,
          child: _busy && _handshake == null
              ? const Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: ProgressRing(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('Contacting Last.fm…'),
                  ],
                )
              : Text(_handshake == null
                  ? 'Connect with Last.fm'
                  : 'Restart approval'),
        ),
        if (!configured) ...[
          const SizedBox(height: 6),
          Text(
            'Save your API keys below first.',
            style: WaveType.meta.copyWith(
              color: waveTextTertiary(context),
            ),
          ),
        ],
        if (_handshake != null) ...[
          const SizedBox(height: 8),
          WaveButton(
            onPressed: _busy ? null : _finish,
            child: _busy
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: ProgressRing(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text('Confirming…'),
                    ],
                  )
                : const Text("I've approved — finish sign-in"),
          ),
        ],
      ],
    );
  }
}

class _Audio extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Audio({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    return Column(
      children: [
        const SizedBox(height: 8),
        _Group(
          title: 'Audio output',
          subtitle: Platform.isWindows
              ? 'WASAPI Exclusive bypasses the Windows mixer'
              : 'System audio output',
          child: _WasapiOutputSettings(onUpdate: onUpdate),
        ),
        const SizedBox(height: 8),
        _Group(
          title: 'Streaming and Download quality',
          subtitle: 'Lossless-first with YouTube fallback',
          child: Column(
            children: [
              _QualityRow(
                title: 'Streaming quality',
                value: prefs.losslessQuality,
                onChanged: (q) => onUpdate((p) => p.setLosslessQuality(q)),
              ),
              const SizedBox(height: 8),
              _QualityRow(
                title: 'Download quality',
                value: prefs.downloadQuality,
                onChanged: (q) => onUpdate((p) => p.setDownloadQuality(q)),
              ),
              const SizedBox(height: 8),
              _SwitchRow(
                value: prefs.preferLossless,
                onChanged: (v) => onUpdate((p) => p.setPreferLossless(v)),
                title: 'Prefer lossless',
                subtitle: 'Try lossless first, fall back to Opus',
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _Group(
          title: 'Equalizer & Sound FX',
          subtitle: '10-band ISO curves with acoustic & stage compensation',
          child: const SizedBox(
            height: 560,
            child: WaveEqualizerPanel(embedded: true),
          ),
        ),
      ],
    );
  }
}

class _EqualizerSettingsSummary extends ConsumerWidget {
  const _EqualizerSettingsSummary();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eq = ref.watch(equalizerProvider);
    final notifier = ref.read(equalizerProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SwitchRow(
          value: eq.enabled,
          onChanged: (v) => notifier.setEnabled(v),
          title: '10-Band Equalizer',
          subtitle: eq.enabled
              ? 'Active: ${eq.presetName} (-8 dB to +8 dB per band)'
              : 'Bit-perfect direct stream bypass (filter removed)',
        ),
        const SizedBox(height: 8),
        _SwitchRow(
          value: eq.studioClarityEnabled,
          onChanged: (v) => notifier.setStudioClarityEnabled(v),
          title: 'Studio Master Clarity',
          subtitle: 'Acoustic & stage compensation (${eq.clarityPreset.displayName})',
        ),
        if (eq.studioClarityEnabled) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Clarity target', style: WaveType.trackTitle),
              const Spacer(),
              WaveSelect<String>(
                value: eq.clarityPreset.key,
                options: [
                  for (final t in ClarityPresets.all)
                    WaveSelectOption(value: t.key, label: t.displayName),
                ],
                onChanged: (key) => notifier.setClarityPreset(key),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('Equalizer preset', style: WaveType.trackTitle),
            const Spacer(),
            WaveSelect<String>(
              value: EqualizerPresets.all.any((p) => p.name == eq.presetName)
                  ? eq.presetName
                  : 'Custom',
              options: [
                for (final p in EqualizerPresets.all)
                  WaveSelectOption(value: p.name, label: p.name),
                if (!EqualizerPresets.all.any((p) => p.name == eq.presetName))
                  const WaveSelectOption(value: 'Custom', label: 'Custom'),
              ],
              onChanged: (preset) {
                if (preset != 'Custom') {
                  notifier.setPreset(preset);
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _Appearance extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: ToggleButton(
                      checked: !theme.isLight,
                      onChanged: (_) async {
                        await ref
                            .read(themeControllerProvider.notifier)
                            .setThemeMode(false);
                        await applyWindowMaterial(
                          isLight: false,
                          amoled: prefs.amoled,
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
                            .read(themeControllerProvider.notifier)
                            .setThemeMode(true);
                        await applyWindowMaterial(isLight: true);
                      },
                      child: const Text('Pearl'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text('Accent source', style: WaveType.trackTitle),
              const SizedBox(height: 6),
              WaveSelect<AccentSource>(
                value: AccentSource.fromId(theme.accentSource),
                options: [
                  for (final source in AccentSource.values)
                    WaveSelectOption(value: source, label: source.label),
                ],
                onChanged: (v) {
                  // Re-probe the desktop accent on every re-selection: the
                  // user may have just changed it in their OS settings.
                  if (v == AccentSource.system) {
                    ref.invalidate(systemAccentProvider);
                  }
                  onUpdate((p) => p.setAccentSource(v.id));
                },
              ),
              const SizedBox(height: 8),
              _AccentPreview(resolution: ref.watch(accentResolutionProvider)),
              const SizedBox(height: 10),
              const Text('Accent colour', style: WaveType.trackTitle),
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
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                      // Picking a swatch implies "custom colour": without
                      // this the swatches look inert while another accent
                      // source is active.
                      onTap: () => onUpdate((p) async {
                        await p.setAccentColor(c.toARGB32());
                        await p.setAccentSource(AccentSource.custom.id);
                      }),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: c,
                          border: Border.all(
                            color: theme.accent.toARGB32() == c.toARGB32()
                                ? waveAccent(context)
                                : waveDivider(context),
                            width: 2,
                          ),
                        ),
                        child: theme.accent.toARGB32() == c.toARGB32()
                            ? Icon(
                                FluentIcons.check_mark,
                                size: 14,
                                color: onAccentFor(c),
                              )
                            : null,
                      ),
                    )),
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
              WaveSelect<String>(
                value: theme.hazeMaterial,
                options: const [
                  WaveSelectOption(value: 'automatic', label: 'Automatic'),
                  WaveSelectOption(value: 'haze', label: 'Haze'),
                  WaveSelectOption(value: 'solid', label: 'Solid'),
                ],
                onChanged: (v) => onUpdate((p) => p.setHazeMaterial(v)),
              ),
              const SizedBox(height: 10),
              const Text('Haze intensity', style: WaveType.trackTitle),
              const SizedBox(height: 6),
              Row(
                children: [
                  for (final opt in ['low', 'medium', 'high'])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ToggleButton(
                        checked: theme.hazeIntensity == opt,
                        onChanged: (_) =>
                            onUpdate((p) => p.setHazeIntensity(opt)),
                        child: Text(
                          '${opt[0].toUpperCase()}${opt.substring(1)}',
                        ),
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
                enabled: !theme.isLight,
                onChanged: (v) => onUpdate((p) => p.setAmoled(v)),
                title: 'AMOLED black',
                subtitle: 'Pure-black surfaces · Midnight only',
              ),
              _SwitchRow(
                value: prefs.dynamicNowPlaying,
                onChanged: (v) => onUpdate((p) => p.setDynamicNowPlaying(v)),
                title: 'Dynamic artwork theme',
                subtitle: 'Tint Now Playing from album art',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Lyrics extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Lyrics({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    return _Group(
      title: 'Timing',
      subtitle: 'Synced lyrics providers',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SwitchRow(
            value: prefs.wordByWord,
            onChanged: (v) => onUpdate((p) => p.setWordByWord(v)),
            title: 'Word-by-word lyrics',
            subtitle: 'Karaoke word highlight. Off uses Apple Music line lyrics.',
          ),
          const SizedBox(height: 10),
          const Text('Primary provider', style: WaveType.trackTitle),
          const SizedBox(height: 6),
          WaveSelect<String>(
            value: LyricsProviderId.fromId(prefs.lyricsProviderId).id,
            options: [
              for (final provider in LyricsProviderId.values)
                WaveSelectOption(
                  value: provider.id,
                  label: provider.title,
                ),
            ],
            onChanged: (v) => onUpdate((p) => p.setLyricsProviderId(v)),
          ),
          const SizedBox(height: 4),
          Text(
            LyricsProviderId.fromId(prefs.lyricsProviderId).subtitle,
            style: WaveType.meta,
          ),
        ],
      ),
    );
  }
}

class _Scrobbler extends ConsumerStatefulWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Scrobbler({required this.onUpdate});

  @override
  ConsumerState<_Scrobbler> createState() => _ScrobblerState();
}

class _ScrobblerState extends ConsumerState<_Scrobbler> {
  double? _dragPercent;

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(prefsProvider);
    final percent = (_dragPercent ?? prefs.scrobblePercent.toDouble())
        .clamp(25, 90)
        .toDouble();
    return _Group(
      title: 'Last.fm scrobbling',
      subtitle: 'Thresholds mirror Last.fm rules',
      child: Column(
        children: [
          _SwitchRow(
            value: prefs.scrobblerEnabled,
            onChanged: (v) =>
                widget.onUpdate((p) => p.setScrobbler(enabled: v)),
            title: 'Enable scrobbling',
            subtitle: 'Requires a write-capable session',
          ),
          _SwitchRow(
            value: prefs.scrobbleNowPlaying,
            onChanged: (v) =>
                widget.onUpdate((p) => p.setScrobbler(nowPlaying: v)),
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
                    onChanged: (v) => setState(() => _dragPercent = v),
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
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Ytm({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Reactive mirror — the API singleton never changes identity, so
    // watching innerTubeProvider alone would never rebuild this row.
    final connection = ref.watch(ytConnectionProvider);
    final account = ref.watch(ytAccountProvider).valueOrNull;
    final prefs = ref.watch(prefsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Group(
          title: 'YouTube Music',
          subtitle: 'Personal library, history and uploads',
          child: connection.connected
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _connectedRow(context, ref, connection, account),
                    if (ref.watch(ytAuthStaleProvider)) ...[
                      const SizedBox(height: 10),
                      const _YtStaleBanner(),
                    ],
                    const SizedBox(height: 8),
                    _SwitchRow(
                      value: prefs.syncYtHistory,
                      onChanged: (v) =>
                          onUpdate((p) => p.setSyncYtHistory(v)),
                      title: 'Sync listening history',
                      subtitle:
                          'Record plays to your YouTube Music history',
                    ),
                  ],
                )
              : Row(
                  children: [
                    const Icon(FluentIcons.video, size: 18),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text('Not connected', style: WaveType.trackTitle),
                    ),
                    WaveButton(
                      onPressed: () => _ytConnectWithCookies(context, ref),
                      child: const Text('Use cookies'),
                    ),
                    const SizedBox(width: 8),
                    WaveFilledButton(
                      onPressed: () => _ytConnect(context, ref),
                      child: const Text('Connect'),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        _Group(
          title: 'Global Live Telemetry & Map',
          subtitle:
              'Anonymous real-time listening map at telemetry.clashprojects.qd.je',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SwitchRow(
                value: prefs.liveTelemetryEnabled,
                onChanged: (v) =>
                    onUpdate((p) => p.setLiveTelemetryEnabled(v)),
                title: 'Global Live Map Telemetry',
                subtitle: prefs.liveTelemetryEnabled
                    ? 'On • Listening ticks broadcast anonymously to the live world map'
                    : 'Off • Playback telemetry stays completely local',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Open Global Live Map',
                            style: WaveType.trackTitle),
                        const SizedBox(height: 2),
                        Text(
                          'telemetry.clashprojects.qd.je • Real-time vector map of global listeners',
                          style: WaveType.meta.copyWith(
                            color: waveTextSecondary(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  WaveFilledButton(
                    onPressed: () async {
                      final uri =
                          Uri.parse(LiveTelemetryService.telemetryBaseUrl);
                      try {
                        if (await canLaunchUrl(uri)) {
                          await launchUrl(uri,
                              mode: LaunchMode.externalApplication);
                        }
                      } catch (_) {}
                    },
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FluentIcons.globe, size: 14),
                        SizedBox(width: 6),
                        Text('Open Live Map'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Group(
          title: 'Discord',
          subtitle: 'Show what you are listening to on your Discord profile',
          child: _SwitchRow(
            value: prefs.discordRichPresence,
            onChanged: (v) async {
              await onUpdate((p) => p.setDiscordRichPresence(v));
              try {
                ref.read(discordPresenceProvider).refresh();
              } catch (_) {}
            },
            title: 'Discord Rich Presence',
            subtitle: 'Uses the local Discord client · no bot or login',
          ),
        ),
      ],
    );
  }

  Widget _connectedRow(
    BuildContext context,
    WidgetRef ref,
    YtConnection connection,
    YtAccount? account,
  ) {
    // Provisional connections (identity transiently empty right after
    // login) fall back to the roster email so the card never renders
    // a bare "Connected" for a known account.
    final connEmail =
        connection.profileEmail != 'unknown' ? connection.profileEmail : '';
    final rawName = account?.name ?? '';
    final name = rawName.isNotEmpty
        ? rawName
        : (connEmail.isNotEmpty ? connEmail : '');
    // Same @-gate as the chooser: fresh parses never emit junk, but
    // this keeps every path honest if a shape ever surprises us.
    final handle = (account?.handle ?? '').startsWith('@')
        ? account!.handle
        : '';
    final email = (account?.email ?? '').isNotEmpty
        ? account!.email
        : connEmail;
    final idLine = handle.isNotEmpty ? handle : ytDisplayEmail(email);
    final since = DateTime.fromMillisecondsSinceEpoch(
      connection.connectedAtMillis,
      isUtc: false,
    );
    final sinceText = connection.connectedAtMillis > 0
        ? ' · since ${since.year}-'
              '${since.month.toString().padLeft(2, '0')}-'
              '${since.day.toString().padLeft(2, '0')}'
        : '';
    final sub = [
      if (idLine.isNotEmpty) idLine,
      'Connected$sinceText',
    ].join(' · ');
    return Row(
      children: [
        if (account?.photoUrl.isNotEmpty == true)
          WaveArtwork.circle(
            url: account!.photoUrl,
            size: 40,
            label: name,
            // Identity avatar: never let the official-source upgrade
            // swap it for a Deezer artist photo matching the name.
            upgrade: false,
          )
        else
          const Icon(FluentIcons.video, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name.isNotEmpty ? name : 'Connected',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.trackTitle,
              ),
              Text(
                name.isNotEmpty ? sub : 'Connected$sinceText',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.meta.copyWith(
                  color: waveTextSecondary(context),
                ),
              ),
            ],
          ),
        ),
        const _CardActions(),
      ],
    );
  }


  /// In-app Google sign-in: opens music.youtube.com in a system
  /// WebView, waits for login, captures cookies automatically, then
  /// runs the shared roster upsert + chooser tail.
  Future<void> _ytConnect(BuildContext context, WidgetRef ref) async {
    var cancelled = false;
    // Non-blocking wait dialog — Cancel just stops listening; the
    // user closes the browser window via the native guard (hide).
    // NOTE: popped via the dialog's OWN context. A rootNavigator pop
    // here would eat the settings page under the go_router ShellRoute.
    BuildContext? waitDialogContext;
    unawaited(
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          waitDialogContext = dialogContext;
          return ContentDialog(
            title: const Text('Sign in with Google'),
            content: const Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SizedBox(width: 20, height: 20, child: ProgressRing()),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Complete the sign-in in the browser window. '
                        'This dialog closes automatically.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 8),
                Text(
                  'Passkey verified but the Google page looks stuck? '
                  'Press Reload — or pick "Try another way" in the '
                  'Google window and use your password instead.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
            actions: [
              WaveButton(
                onPressed: () {
                  YtWebLogin.reloadLoginPage();
                },
                child: const Text('Reload'),
              ),
              WaveButton(
                onPressed: () {
                  cancelled = true;
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      ),
    );
    if (kDebugMode) {
      debugPrint('YtWebSignIn: waiting for browser login');
    }
    String? header;
    try {
      header = await YtWebLogin.signIn();
    } catch (_) {
      header = null;
    }
    if (kDebugMode) {
      debugPrint(
        'YtWebSignIn: flow returned header=${header == null ? 'null' : '${header.length} chars'} cancelled=$cancelled',
      );
    }
    // Dismiss the wait dialog if it is still up.
    final waitCtx = waitDialogContext;
    if (waitCtx != null && waitCtx.mounted) {
      Navigator.of(waitCtx).maybePop();
    }
    if (cancelled || header == null || header.isEmpty) {
      if (!cancelled && context.mounted) {
        await _ytSignInFailed(context, ref);
      }
      return;
    }
    if (!context.mounted) return;
    await _ytConnectCaptured(
      context,
      ref,
      header: header,
      pageId: YtWebLogin.lastCapturedPageId ?? '',
    );
    await _refocusMain();
  }
}

/// Shown when YouTube definitively rejected the stored jar.
///
/// Tries the zero-UI hidden-window refresh exactly once per app run
/// (the WebView2 profile keeps the Google login, so reloading
/// music.youtube.com usually re-mints the rotated `__Secure-*PSIDTS`
/// cookies). When that is not possible the user gets an explicit
/// Reconnect instead of silently empty libraries.
class _YtStaleBanner extends ConsumerStatefulWidget {
  const _YtStaleBanner();

  @override
  ConsumerState<_YtStaleBanner> createState() => _YtStaleBannerState();
}

class _YtStaleBannerState extends ConsumerState<_YtStaleBanner> {
  static bool _autoAttempted = false;
  bool _busy = false;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    // One silent attempt per app run, and only when this run actually
    // created the sign-in window — with no cached window there is
    // nothing to reload and the user must sign in.
    if (!_autoAttempted && YtWebLogin.cachedWindow != null) {
      _autoAttempted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh();
      });
    }
  }

  Future<void> _refresh() async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    final ok = await YtSessionKeeper.refresh(ref);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      await _showYtFail(
        context,
        'The hidden browser window could not refresh this session. '
        'Sign in again — the browser window or a pasted cookie jar '
        'both work.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    return InfoBar(
      title: const Text('YouTube Music session expired'),
      content: const Text(
        'YouTube rejected the saved session. Library, history and '
        'uploads stay empty until you reconnect.',
      ),
      severity: InfoBarSeverity.warning,
      isLong: false,
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 14,
                height: 14,
                child: ProgressRing(),
              ),
            )
          else
            WaveLink(
              onPressed: _refresh,
              child: const Text('Refresh'),
            ),
          const SizedBox(width: 12),
          WaveLink(
            onPressed: () => _ytConnectWithCookies(context, ref),
            child: const Text('Reconnect'),
          ),
        ],
      ),
      onClose: () => setState(() => _dismissed = true),
    );
  }
}

/// Card buttons: Switch (multi-channel roster), Add (account/channel),
/// Disconnect. Extracted so the row rebuilds cheaply.
class _CardActions extends ConsumerWidget {
  const _CardActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var channels = 0;
    for (final p in ref.watch(ytProfilesProvider)) {
      channels += p.channels.isEmpty ? 1 : p.channels.length;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (channels >= 2)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: WaveButton(
              onPressed: () => _ytSwitch(context, ref),
              child: const Text('Switch'),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: WaveButton(
            onPressed: () => _ytAddMenu(context, ref),
            child: const Text('Add'),
          ),
        ),
        WaveButton(
          onPressed: () async {
            final tube = ref.read(innerTubeProvider);
            await tube.signOut();
            ref.read(ytConnectionProvider.notifier).state = tube.connection;
          },
          child: const Text('Disconnect'),
        ),
      ],
    );
  }

  static Future<void> _ytSwitch(BuildContext context, WidgetRef ref) async {
    final roster = ref.read(ytProfilesProvider);
    final conn = ref.read(ytConnectionProvider);
    final sel = await showYtProfileChooser(
      context: context,
      roster: roster,
      activeEmail: conn.profileEmail,
      activePageId: conn.activePageId,
      title: 'Switch channel',
    );
    if (sel == null || !context.mounted) return;
    YtProfile? target;
    for (final p in ref.read(ytProfilesProvider)) {
      if (p.email == sel.email) {
        target = p;
        break;
      }
    }
    if (target == null) return;
    if (target.email == conn.profileEmail && sel.pageId == conn.activePageId) {
      return; // already active
    }
    try {
      await switchYtIdentity(ref, profile: target, pageId: sel.pageId);
      if (context.mounted) {
        await _showYtOk(
          context,
          'Switched',
          'Now using ${target.email}'
              '${sel.pageId.isEmpty ? '' : ' · brand channel'}. '
              'Library, history and uploads reloaded.',
        );
      }
    } catch (e) {
      if (context.mounted) {
        await _showYtFail(context, e);
      }
    }
  }

  static Future<void> _ytAddMenu(BuildContext context, WidgetRef ref) async {
    final mode = await showDialog<String>(
      context: context,
      // Wider than the 368px ContentDialog default so the option rows
      // never squeeze their labels ("Cookie s", "Brand channe l").
      builder: (dialogContext) => ContentDialog(
        constraints: const BoxConstraints(maxWidth: 460),
        title: const Text('Add to YouTube Music'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Each identity keeps its own cookie jar, so adding one '
              'never signs the others out.',
              style: WaveType.meta.copyWith(
                color: waveTextSecondary(dialogContext),
              ),
            ),
            const SizedBox(height: 14),
            _YtAddOption(
              icon: FluentIcons.contact,
              title: 'Google account',
              subtitle: 'Sign in to another Google account in a browser window',
              onPressed: () => Navigator.of(dialogContext).pop('account'),
            ),
            const SizedBox(height: 8),
            _YtAddOption(
              icon: FluentIcons.people,
              title: 'Brand channel',
              subtitle: 'Add a channel on the current login (needs the '
                  'browser window)',
              onPressed: () => Navigator.of(dialogContext).pop('channel'),
            ),
            const SizedBox(height: 8),
            _YtAddOption(
              icon: FluentIcons.link,
              title: 'Cookies',
              subtitle: 'Paste a session exported from your own browser — '
                  'works when the built-in window is blocked',
              onPressed: () => Navigator.of(dialogContext).pop('cookie'),
            ),
          ],
        ),
        actions: [
          WaveButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (mode == null || !context.mounted) return;
    if (mode == 'account') {
      await _ytAddAccount(context, ref);
    } else if (mode == 'cookie') {
      await _ytConnectWithCookies(context, ref);
    } else {
      await _ytAddChannel(context, ref);
    }
  }

  /// Add another Google login: clean-room sign-in (logout URL first,
  /// same window, never destroyed), then the shared capture tail.
  static Future<void> _ytAddAccount(BuildContext context, WidgetRef ref) async {
    var cancelled = false;
    BuildContext? waitCtx;
    unawaited(
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          waitCtx = dialogContext;
          return ContentDialog(
            title: const Text('Add Google account'),
            content: const Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SizedBox(width: 20, height: 20, child: ProgressRing()),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Log in as the other Google account in the '
                        'browser window. This dialog closes automatically.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 8),
                Text(
                  'Passkey verified but the Google page looks stuck? '
                  'Press Reload — or pick "Try another way" in the '
                  'Google window and use your password instead.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
            actions: [
              WaveButton(
                onPressed: () {
                  YtWebLogin.reloadLoginPage();
                },
                child: const Text('Reload'),
              ),
              WaveButton(
                onPressed: () {
                  cancelled = true;
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      ),
    );
    String? header;
    try {
      header = await YtWebLogin.signInFresh();
    } catch (_) {
      header = null;
    }
    final wc = waitCtx;
    if (wc != null && wc.mounted) {
      Navigator.of(wc).maybePop();
    }
    if (cancelled || header == null || header.isEmpty) {
      if (!cancelled && context.mounted) {
        await _ytSignInFailed(context, ref);
      }
      return;
    }
    if (!context.mounted) return;
    await _ytConnectCaptured(
      context,
      ref,
      header: header,
      pageId: YtWebLogin.lastCapturedPageId ?? '',
    );
    await _refocusMain();
  }

  /// Add a brand channel: the window already holds the Google login;
  /// the user flips to the brand channel in-page, presses Done, and
  /// the delegation page ID is read from ytcfg.
  static Future<void> _ytAddChannel(BuildContext context, WidgetRef ref) async {
    final w = await YtWebLogin.ensureWindow();
    if (w == null) {
      if (context.mounted) {
        await _showYtFail(context, 'No system WebView available.');
      }
      return;
    }
    if (!context.mounted) return;
    try {
      w.launch('https://music.youtube.com/',
          triggerOnUrlRequestEvent: false);
    } catch (_) {}
    var cancelled = false;
    var done = false;
    BuildContext? waitCtx;
    unawaited(
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          waitCtx = dialogContext;
          return ContentDialog(
            title: const Text('Add brand channel'),
            content: const Row(
              children: [
                SizedBox(width: 20, height: 20, child: ProgressRing()),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Sign in if needed, then switch to the brand '
                    'channel in the browser window and press Done.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            actions: [
              WaveButton(
                onPressed: () {
                  cancelled = true;
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('Cancel'),
              ),
              WaveFilledButton(
                onPressed: () {
                  done = true;
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
    String? header;
    try {
      // Generous window: user may need to sign in first.
      header = await YtWebLogin.waitForLoginSession(
        w,
        timeout: const Duration(minutes: 5),
      );
      if (header != null && !cancelled) {
        // Wait for Done/Cancel (the dialog above stays up).
        while (!done && !cancelled) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
    } catch (_) {
      header = null;
    }
    final wc = waitCtx;
    if (wc != null && wc.mounted) {
      Navigator.of(wc).maybePop();
    }
    await YtWebLogin.hideWindow();
    await _refocusMain();
    if (cancelled || header == null || header.isEmpty) {
      if (!cancelled && context.mounted) {
        await _showYtFail(
          context,
          'No session was captured. Please try again.',
        );
      }
      return;
    }
    if (!context.mounted) return;
    final pageId = await YtWebLogin.readDelegatedPageId(w) ?? '';
    if (kDebugMode) {
      debugPrint(
        'YtChannel: Done with pageId=${pageId.isEmpty ? 'main' : '${pageId.length} digits'}',
      );
    }
    if (!context.mounted) return;
    await _ytConnectCaptured(context, ref, header: header, pageId: pageId);
  }
}

/// Connect with pasted YouTube Music session cookies (raw header, Netscape
/// cookies.txt, or JSON array). Normalizes and validates via InnerTubeMusicApi.
///
/// This is a first-class path, not a hidden fallback: Google refuses
/// its sign-in page to embedded browsers on macOS (`disallowed_useragent`),
/// and a broken WebView2 environment can leave Windows stuck on
/// about:blank. A jar exported from the user's own browser is a normal
/// Chrome session, so it is the only path that works everywhere.
Future<void> _ytConnectWithCookies(
  BuildContext context,
  WidgetRef ref,
) async {
  final controller = TextEditingController();
  String? errorText;
  var missing = const <String>[];
  var hasInput = false;

  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) {
        void analyse() {
          final text = controller.text.trim();
          hasInput = text.isNotEmpty;
          missing = hasInput
              ? YtWebLogin.missingMarkerNames(_cookieNamesFrom(text))
              : const [];
        }

        return ContentDialog(
          constraints: const BoxConstraints(maxWidth: 540),
          title: const Text('Connect with cookies'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Use this when the built-in sign-in window is blocked or '
                'cannot load. The jar comes from your own browser, so '
                'Google sees a normal desktop session. A pasted jar '
                'connects the main channel only — brand channels still '
                'need the browser window.',
                style: WaveType.meta.copyWith(
                  color: waveTextSecondary(context),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  WaveButton(
                    onPressed: _openYtInBrowser,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FluentIcons.open_in_new_window, size: 14),
                        SizedBox(width: 6),
                        Text('Open music.youtube.com'),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  WaveButton(
                    onPressed: () async {
                      final text = await _pickCookieFile();
                      if (text == null || text.isEmpty) return;
                      controller.text = text;
                      setState(() {
                        errorText = null;
                        analyse();
                      });
                    },
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FluentIcons.open_folder_horizontal, size: 14),
                        SizedBox(width: 6),
                        Text('Import cookies.txt'),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'In Chrome/Edge: sign in to music.youtube.com, press F12 '
                '→ Network, reload the page, open any music.youtube.com '
                'request and copy the value of its Cookie request header '
                '(right-click → Copy value). Paste it below. '
                'Firefox works the same way; a cookies.txt extension '
                'export is also accepted.',
                style: WaveType.meta.copyWith(
                  color: waveTextSecondary(context),
                ),
              ),
              const SizedBox(height: 12),
              TextBox(
                decoration: waveInputDecoration(),
                controller: controller,
                placeholder: 'SID=...; __Secure-3PAPISID=...; SAPISID=...',
                maxLines: 7,
                minLines: 4,
                autofocus: true,
                onChanged: (_) => setState(() {
                  errorText = null;
                  analyse();
                }),
              ),
              const SizedBox(height: 10),
              _CookieChecklist(missing: missing, hasInput: hasInput),
              if (errorText != null) ...[
                const SizedBox(height: 8),
                Text(
                  errorText!,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.red,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            WaveButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            WaveFilledButton(
              onPressed: () {
                final text = controller.text.trim();
                if (text.isEmpty) {
                  setState(() => errorText = 'Paste the cookie text first.');
                  return;
                }
                try {
                  Navigator.of(dialogContext).pop(
                    InnerTubeMusicApi.normalizeCookies(text),
                  );
                } catch (e) {
                  setState(() {
                    errorText = e is FormatException
                        ? e.message
                        : 'Invalid cookies. Make sure SAPISID is present.';
                  });
                }
              },
              child: const Text('Connect'),
            ),
          ],
        );
      },
    ),
  );
  controller.dispose();

  if (result != null && result.isNotEmpty && context.mounted) {
    await _ytConnectCaptured(
      context,
      ref,
      header: result,
      pageId: '',
    );
  }
}

/// Cookie names present in any accepted paste format, for the live
/// completeness checklist. Best-effort: normalizeCookies throws on
/// unusable input, which just means "nothing detected yet".
List<String> _cookieNamesFrom(String raw) {
  try {
    final normalized = InnerTubeMusicApi.normalizeCookies(raw);
    final out = <String>[];
    for (final part in normalized.split(';')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      final n = part.substring(0, i).trim();
      if (n.isNotEmpty) out.add(n);
    }
    return out;
  } catch (_) {
    return const [];
  }
}

Future<void> _openYtInBrowser() async {
  final uri = Uri.parse('https://music.youtube.com/');
  try {
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  } catch (_) {}
}

/// Read a cookies.txt / JSON export picked by the user. Capped at 2 MB
/// (session exports are a few KB) so a stray file can never stall the
/// dialog.
Future<String?> _pickCookieFile() async {
  try {
    final f = await FilePicker.pickFile(
      dialogTitle: 'Select a cookies.txt export',
      type: FileType.any,
    );
    if (f == null) return null;
    final size = await f.length();
    if (size > 2 * 1024 * 1024) return null;
    final bytes = await f.readAsBytes();
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return null;
  }
}

/// Live "does this jar look complete?" indicator under the paste box.
class _CookieChecklist extends StatelessWidget {
  final List<String> missing;
  final bool hasInput;
  const _CookieChecklist({required this.missing, required this.hasInput});

  @override
  Widget build(BuildContext context) {
    if (!hasInput) return const SizedBox.shrink();
    final ok = missing.isEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          ok ? FluentIcons.check_mark : FluentIcons.warning,
          size: 14,
          color: ok ? null : Colors.orange,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            ok
                ? 'Session markers detected — this jar looks complete.'
                : 'Not detected yet: ${missing.join(' · ')}. '
                    'YouTube needs these to treat the jar as signed in.',
            style: WaveType.meta.copyWith(
              color: waveTextSecondary(context),
            ),
          ),
        ),
      ],
    );
  }
}

/// One full-width choice in the "Add to YouTube Music" dialog.
class _YtAddOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onPressed;
  const _YtAddOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: WaveButton(
        onPressed: onPressed,
        style: const ButtonStyle(
          padding: WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.start,
                    style: WaveType.trackTitle,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.start,
                    style: WaveType.meta.copyWith(
                      color: waveTextSecondary(context),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(FluentIcons.chevron_right, size: 12),
          ],
        ),
      ),
    );
  }
}

/// Shared capture tail: roster upsert → ALWAYS show the channel
/// chooser (even a single row — identity double-check) → switch to
/// the pick. Cancelled chooser falls back to connecting the captured
/// jar directly (legacy behavior).
Future<void> _ytConnectCaptured(
  BuildContext context,
  WidgetRef ref, {
  required String header,
  required String pageId,
}) async {
  final profile = await upsertYtCapture(ref, cookies: header, pageId: pageId);
  if (!context.mounted) return;
  final roster = ref.read(ytProfilesProvider);
  final conn = ref.read(ytConnectionProvider);
  final sel = await showYtProfileChooser(
    context: context,
    roster: roster,
    activeEmail: profile?.email ?? conn.profileEmail,
    activePageId: pageId,
  );
  if (!context.mounted) return;
  if (sel == null) {
    await _YtmStaticFallback.finish(context, ref, header, profile, pageId);
    return;
  }
  YtProfile? target;
  for (final p in ref.read(ytProfilesProvider)) {
    if (p.email == sel.email) {
      target = p;
      break;
    }
  }
  target ??= profile;
  if (target == null) {
    await _showYtFail(context, 'Profile vanished — please try again.');
    return;
  }
  try {
    await switchYtIdentity(ref, profile: target, pageId: sel.pageId);
    // Identity is often transiently empty right after login; one
    // force-refresh backfills the roster row + settings card without
    // needing an app restart. Best-effort: failures just leave the
    // provisional entry for the startup repair pass.
    await _refreshYtIdentity(ref, pageId: sel.pageId);
    if (context.mounted) {
      await _showYtOk(
        context,
        'YouTube Music connected',
        'Account verified — library, history and uploads are unlocked.',
      );
    }
  } catch (e) {
    if (context.mounted) {
      await _showYtFail(context, e);
    }
  }
}

/// One best-effort identity backfill after a fresh connect: re-runs
/// the roster upsert now that the session is live (YouTube serves
/// identity a moment after login — the capture-time resolve is often
/// transiently empty) and refreshes the account card. Best-effort:
/// failures just leave the provisional entry for the startup repair
/// pass.
Future<void> _refreshYtIdentity(WidgetRef ref, {String pageId = ''}) async {
  try {
    final cookies = ref.read(innerTubeProvider).connection.cookies;
    if (cookies.isNotEmpty) {
      await upsertYtCapture(ref, cookies: cookies, pageId: pageId);
    }
    ref.invalidate(ytAccountProvider);
  } catch (_) {}
}

/// Cancelled-chooser fallback: connect the captured jar directly.
abstract class _YtmStaticFallback {
  static Future<void> finish(
    BuildContext context,
    WidgetRef ref,
    String header,
    YtProfile? profile,
    String pageId,
  ) async {
    final tube = ref.read(innerTubeProvider);
    try {
      await tube.connectAs(
        cookies: header,
        profileEmail: profile?.email ?? '',
        pageId: pageId,
      );
      ref.read(ytConnectionProvider.notifier).state = tube.connection;
      await _refreshYtIdentity(ref, pageId: pageId);
      if (context.mounted) {
        await _showYtOk(
          context,
          'YouTube Music connected',
          'Account verified — library, history and uploads are unlocked.',
        );
      }
    } catch (e) {
      if (context.mounted) {
        await _showYtFail(context, e);
      }
    }
  }
}

Future<void> _showYtOk(BuildContext context, String title, String message) {
  return showDialog(
    context: context,
    builder: (dialogContext) => ContentDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        WaveFilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

Future<void> _showYtFail(BuildContext context, Object e) {
  return showDialog(
    context: context,
    builder: (dialogContext) => ContentDialog(
      title: const Text('Connection failed'),
      content: Text('$e'),
      actions: [
        WaveFilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// Explains WHY the system-WebView sign-in produced nothing and offers
/// the cookie path, which is the only route that works when Google
/// refuses its sign-in page to an embedded browser.
Future<void> _ytSignInFailed(BuildContext context, WidgetRef ref) async {
  final failure = YtWebLogin.lastFailure;
  if (failure == YtSignInFailure.windowClosed) return;

  late String title;
  late String body;
  switch (failure) {
    case YtSignInFailure.browserBlocked:
      title = 'Google blocked the built-in browser';
      body = 'Google refuses to serve its sign-in page to embedded '
          'browsers — this is expected on macOS, and no in-app retry can '
          'get past that page.\n\n'
          'Use "Connect with cookies" instead: sign in to '
          'music.youtube.com in Chrome, Edge or Firefox, copy the cookie '
          'table, and paste it here. That jar is a normal browser '
          'session and works on every platform.';
    case YtSignInFailure.unavailable:
      title = 'No system WebView available';
      body = 'This machine has no usable WebView runtime (WebView2 on '
          'Windows, WebKitGTK on Linux), so the sign-in window cannot '
          'open. Install the runtime, or connect with cookies instead — '
          'that path does not need a WebView.';
    case YtSignInFailure.blankPage:
      title = 'The sign-in window did not load';
      body = 'The browser window stayed on a blank or error page even '
          'after reloading. That usually means the WebView profile '
          'folder is not writable or the runtime is damaged.\n\n'
          'Connecting with cookies does not depend on the WebView and '
          'will work.';
    case YtSignInFailure.timeout:
      title = 'Sign-in timed out';
      body = 'No session was captured in ten minutes. Make sure the '
          'sign-in finishes on music.youtube.com — an intermediate '
          'accounts.google.com page has no YouTube session yet.\n\n'
          'You can try again, or connect with cookies instead.';
    case YtSignInFailure.noSession:
    case YtSignInFailure.none:
    case YtSignInFailure.windowClosed:
      title = 'Sign-in incomplete';
      body = 'No session was captured. Complete the Google sign-in fully '
          'on music.youtube.com before closing the window.\n\n'
          'If Google shows a passkey step that stalls after Windows '
          'Hello, press Reload in the wait dialog, or pick "Try another '
          'way" and use your password. If the page never lets you in, '
          'connect with cookies instead.';
  }
  final useCookies = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => ContentDialog(
      constraints: const BoxConstraints(maxWidth: 470),
      title: Text(title),
      content: Text(body),
      actions: [
        WaveButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Close'),
        ),
        WaveFilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Connect with cookies'),
        ),
      ],
    ),
  );
  if (useCookies == true && context.mounted) {
    await _ytConnectWithCookies(context, ref);
  }
}

Future<void> _refocusMain() async {
  try {
    await windowManager.focus();
  } catch (_) {}
}

/// Addon sources: personal addon URLs replace the built-in lossless
/// backend as the lossless tier (see [AddonApi]). Quota meters fill
/// in after playback; unknown until the first stream attempt.
class _Sources extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Sources({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final urls = ref.watch(prefsProvider).addonUrls;
    final src = ref.watch(losslessApiProvider);
    final quotas = src is AddonApi
        ? src.quotaByBase
        : const <String, AddonQuota>{};
    return _Group(
      title: 'Addon sources',
      subtitle: urls.isEmpty
          ? 'No addon configured — using the built-in lossless backend'
          : 'Addons serve the lossless tier instead of the built-in backend',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (AppEnv.addonClientSecret.isEmpty &&
              urls.any((u) => AddonApi.tokenOfRoot(u).isNotEmpty))
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'This build has no addon app key — official addons may fail. '
                'Rebuild with ADDON_CLIENT_SECRET set.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          for (final u in urls)
            _AddonRow(
              url: u,
              quota: quotas[u],
              onRemove: () async {
                await onUpdate(
                  (p) => p.setAddonUrls(urls.where((e) => e != u).toList()),
                );
                ref.invalidate(losslessApiProvider);
              },
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: WaveFilledButton(
              onPressed: () => _addAddonDialog(context, ref, urls, onUpdate),
              child: const Text('Add addon'),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Paste the full addon URL from your dashboard. Anyone holding '
            'it plays on your quota — keep the dashboard backup safe.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  Future<void> _addAddonDialog(
    BuildContext context,
    WidgetRef ref,
    List<String> urls,
    Future<void> Function(Future<void> Function(Prefs)) onUpdate,
  ) async {
    final controller = TextEditingController();
    final pasted = await showDialog<String>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Add addon'),
        content: TextBox(
          decoration: waveInputDecoration(),
          controller: controller,
          placeholder: 'https://…/a/<token>/ or https://…',
          maxLines: 2,
        ),
        actions: [
          WaveButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          WaveFilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    final raw = pasted ?? '';
    controller.dispose();
    if (raw.isEmpty || !context.mounted) return;
    final parsed = AddonApi.parseAddonUrl(raw);
    if (parsed == null) {
      if (context.mounted) {
        await showDialog(
          context: context,
          builder: (dialogContext) => ContentDialog(
            title: const Text('Not an addon URL'),
            content: const Text(
              'Expected something like https://host/a/<token>/ or https://host/.',
            ),
            actions: [
              WaveFilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return;
    }
    AddonManifest? manifest;
    try {
      manifest = await AddonApi([parsed.root]).manifestFor(parsed.root);
    } catch (_) {
      manifest = null;
    }
    if (!context.mounted) return;
    if (manifest == null) {
      await showDialog(
        context: context,
        builder: (dialogContext) => ContentDialog(
          title: const Text('Addon unreachable'),
          content: const Text(
            'No usable addon answered there — revoked, offline, '
            'or wrong URL. Nothing was saved.',
          ),
          actions: [
            WaveFilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    final root = parsed.root;
    final next = [...urls.where((e) => e != root), root];
    await onUpdate((p) => p.setAddonUrls(next));
    ref.invalidate(losslessApiProvider);
    ref.invalidate(addonManifestProvider);
  }
}

class _AddonRow extends ConsumerWidget {
  final String url;
  final AddonQuota? quota;
  final Future<void> Function() onRemove;
  const _AddonRow({
    required this.url,
    required this.quota,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manifest = ref.watch(addonManifestProvider(url)).valueOrNull;
    final host = Uri.tryParse(url)?.host ?? url;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Icon(FluentIcons.cloud, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  manifest?.name ?? host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.trackTitle,
                ),
                Text(
                  manifest == null ? '$host · unreachable' : host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.meta.copyWith(
                    color: waveTextSecondary(context),
                  ),
                ),
              ],
            ),
          ),
          WaveButton(onPressed: () => onRemove(), child: const Text('Remove')),
        ],
      ),
    );
  }
}

class _About extends ConsumerStatefulWidget {
  const _About();

  @override
  ConsumerState<_About> createState() => _AboutState();
}

class _AboutState extends ConsumerState<_About> {
  bool _checking = false;
  bool _upToDate = false;
  AppUpdateInfo? _updateAvailable;

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  Future<void> _checkForUpdates() async {
    setState(() {
      _checking = true;
      _upToDate = false;
    });

    try {
      final update = await ref.read(updateServiceProvider).checkForUpdate();
      if (!mounted) return;
      setState(() {
        _checking = false;
        _updateAvailable = update;
        _upToDate = update == null;
      });
      if (update != null && mounted) {
        await showUpdateDialog(context, update, isManualCheck: true);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _checking = false;
        });
      }
    }
  }

  Widget _buildUpdateButton() {
    if (_checking) {
      return const WaveButton(
        onPressed: null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: ProgressRing(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text('Checking...'),
          ],
        ),
      );
    }

    if (_updateAvailable != null) {
      return WaveFilledButton(
        onPressed: () => showUpdateDialog(
          context,
          _updateAvailable!,
          isManualCheck: true,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(FluentIcons.update_restore, size: 14),
            const SizedBox(width: 6),
            Text('Update available: v${_updateAvailable!.version}'),
          ],
        ),
      );
    }

    if (_upToDate) {
      return WaveButton(
        onPressed: _checkForUpdates,
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FluentIcons.check_mark, size: 14, color: WaveColors.success),
            SizedBox(width: 6),
            Text('Up to date (check again)'),
          ],
        ),
      );
    }

    return WaveButton(
      onPressed: _checkForUpdates,
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(FluentIcons.sync, size: 14),
          SizedBox(width: 6),
          Text('Check for updates'),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _Group(
      title: 'About LastWave',
      subtitle: 'Build and project links',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('LastWave Desktop · v$appVersion', style: WaveType.trackTitle),
              _buildUpdateButton(),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              WaveButton(
                onPressed: () =>
                    _open('https://github.com/Clash-Projects/LastWave-Desktop'),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.open_in_new_window, size: 14),
                    SizedBox(width: 6),
                    Text('GitHub repository'),
                  ],
                ),
              ),
              WaveButton(
                onPressed: () => _open(
                  'https://github.com/Clash-Projects/LastWave-Desktop/issues',
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.error, size: 14),
                    SizedBox(width: 6),
                    Text('Report an issue'),
                  ],
                ),
              ),
              WaveButton(
                onPressed: () =>
                    _open('https://github.com/Clash-Projects/LastWave-Desktop'),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.favorite_star, size: 14),
                    SizedBox(width: 6),
                    Text('Star / support the project'),
                  ],
                ),
              ),
              WaveButton(
                onPressed: () =>
                    _open('https://t.me/clashprojects'),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TelegramIcon(size: 14),
                    SizedBox(width: 6),
                    Text('Telegram community'),
                  ],
                ),
              ),
              WaveButton(
                onPressed: () => _open(
                  'https://discord.com/invite/TMCEPSUNk2',
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DiscordIcon(size: 14),
                    SizedBox(width: 6),
                    Text('Discord server'),
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
    final prefs = ref.watch(prefsProvider);
    return Column(
      children: [
        _Group(
          title: 'Behaviour',
          subtitle: 'Startup and window defaults',
          child: Column(
            children: [
              _SwitchRow(
                value: prefs.closeToTray,
                onChanged: (v) => onUpdate((p) => p.setCloseToTray(v)),
                title: 'Close button minimize to tray.',
                subtitle:
                    'Keep the player running in the background when closed.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Group(
          title: 'Backup & Restore',
          subtitle: 'Playlists and "don\'t recommend" list, synced through '
              'one file shared with the LastWave phone app',
          child: Row(
            children: [
              WaveFilledButton(
                onPressed: () => exportBackup(context, ref),
                child: const Text('Export backup'),
              ),
              const SizedBox(width: 8),
              WaveButton(
                onPressed: () => syncWithFile(context, ref),
                child: const Text('Sync with file'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Diagnostics live on the General page on purpose: a user with a
        // problem finds them without knowing what "Advanced" means, and
        // the export is the only thing we ever ask them to send.
        _Group(
          title: 'Diagnostics',
          subtitle: 'Local logs for troubleshooting — nothing is uploaded',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SwitchRow(
                value: prefs.verboseLogs,
                onChanged: (v) async {
                  await onUpdate((p) => p.setVerboseLogs(v));
                  DiagnosticsLog.verbose = v;
                },
                title: 'Verbose logging',
                subtitle: 'Adds per-request detail (stream clients, audio '
                    'probes). Reproduce the problem with it on.',
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  WaveFilledButton(
                    onPressed: () => exportDiagnostics(context, ref),
                    child: const Text('Export diagnostic logs'),
                  ),
                  const SizedBox(width: 8),
                  WaveButton(
                    onPressed: openLogFolder,
                    child: const Text('Open log folder'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Packages the last 5 runs and the crash trail into one zip. '
                'URLs, cookies and tokens are stripped; track titles are kept '
                'so a wrong-song report stays actionable.',
                style: WaveType.meta.copyWith(
                  color: waveTextSecondary(context),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Playback extends ConsumerStatefulWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Playback({required this.onUpdate});

  @override
  ConsumerState<_Playback> createState() => _PlaybackState();
}

class _PlaybackState extends ConsumerState<_Playback> {
  double? _dragSeconds;

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(prefsProvider);
    final currentSeconds = _dragSeconds ?? prefs.crossfadeSeconds.toDouble();

    return _Group(
      title: 'Playback',
      subtitle: 'Gapless, crossfade and output behaviour',
      child: Column(
        children: [
          _SwitchRow(
            value: prefs.autoplaySimilar,
            onChanged: (v) => widget.onUpdate((p) => p.setAutoplaySimilar(v)),
            title: 'Autoplay similar',
            subtitle: 'Keep playing related tracks after a queue ends',
          ),
          const SizedBox(height: 8),
          _SwitchRow(
            value: prefs.crossfadeEnabled,
            onChanged: (v) async {
              await widget.onUpdate((p) => p.setCrossfade(v));
              ref.read(audioOutputProvider.notifier).refreshPath();
            },
            title: 'Crossfade',
            subtitle: prefs.crossfadeEnabled
                ? '${prefs.crossfadeSeconds}s crossfade duration'
                : 'Gapless direct transition (crossfade disabled)',
          ),
          if (prefs.crossfadeEnabled) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Crossfade duration',
                        style: WaveType.trackTitle,
                      ),
                      const Spacer(),
                      Text(
                        '${currentSeconds.round()}s',
                        style: WaveType.meta.copyWith(
                          color: waveAccent(context),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Slider(
                    value: currentSeconds.clamp(3.0, 12.0),
                    min: 3.0,
                    max: 12.0,
                    divisions: 9,
                    onChanged: (v) => setState(() => _dragSeconds = v),
                    onChangeEnd: (v) async {
                      setState(() => _dragSeconds = null);
                      final secs = v.round().clamp(3, 12);
                      await widget.onUpdate((p) => p.setCrossfadeSeconds(secs));
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('3s (Short)',
                          style: WaveType.meta
                              .copyWith(color: waveTextSecondary(context))),
                      Text('7s (Standard)',
                          style: WaveType.meta
                              .copyWith(color: waveTextSecondary(context))),
                      Text('12s (Long)',
                          style: WaveType.meta
                              .copyWith(color: waveTextSecondary(context))),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Downloads extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Downloads({required this.onUpdate});

  Future<void> _pickDir(WidgetRef ref) async {
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose download folder',
      );
      if (path == null || path.trim().isEmpty) return;
      await onUpdate((p) => p.setDownloadDir(path));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    final custom = prefs.downloadDir;
    return _Group(
      title: 'Offline',
      subtitle: 'Download behaviour and lyrics sidecars',
      child: Column(
        children: [
          _SwitchRow(
            value: prefs.downloadLyrics,
            onChanged: (v) => onUpdate((p) => p.setDownloadLyrics(v)),
            title: 'Download lyrics',
            subtitle: 'Save synced .lrc sidecars with downloads',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(
                  FluentIcons.open_folder_horizontal, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Save location',
                        style: WaveType.trackTitle),
                    Text(
                      custom.isEmpty
                          ? 'Default location'
                          : custom,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.meta,
                    ),
                  ],
                ),
              ),
              WaveButton(
                onPressed: () => _pickDir(ref),
                child: const Text('Change'),
              ),
              if (custom.isNotEmpty) ...[
                const SizedBox(width: 8),
                WaveButton(
                  onPressed: () =>
                      onUpdate((p) => p.resetDownloadDir()),
                  child: const Text('Reset'),
                ),
              ],
            ],
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
        const _ApiKeys(),
        const SizedBox(height: 8),
        _Scrobbler(onUpdate: onUpdate),
      ],
    );
  }
}

/// Last.fm BYOK editor: the user's own API key + shared secret.
///
/// Validated with a signed `auth.getToken` call before persisting;
/// saving *different* keys signs the session out (sessions belong to
/// their API key). Key values are never logged — only presence.
class _ApiKeys extends ConsumerStatefulWidget {
  const _ApiKeys();
  @override
  ConsumerState<_ApiKeys> createState() => _ApiKeysState();
}

class _ApiKeysState extends ConsumerState<_ApiKeys> {
  TextEditingController? _key;
  TextEditingController? _secret;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _key?.dispose();
    _secret?.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider.notifier).saveCustomKeys(
            _key?.text ?? '',
            _secret?.text ?? '',
          );
    } catch (e) {
      if (mounted) {
        setState(() => _error = _shortError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider.notifier).clearCustomKeys();
      _key?.clear();
      _secret?.clear();
    } catch (e) {
      if (mounted) {
        setState(() => _error = _shortError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _shortError(Object e) =>
      e.toString().replaceFirst('LastFmException(null): ', '');

  @override
  Widget build(BuildContext context) {
    // Subscribe to auth transitions so the status line below flips
    // right after save/clear: Prefs itself never notifies (see
    // welcome _AuthPanel — same pattern).
    ref.watch(authRepositoryProvider.select((s) => s.status));
    final prefs = ref.watch(prefsProvider);
    _key ??= TextEditingController(text: prefs.lastFmApiKey);
    _secret ??= TextEditingController(text: prefs.lastFmApiSecret);
    final configured = prefs.isLastFmConfigured;
    return _Group(
      title: 'API keys',
      subtitle: 'Your own keys from last.fm/api/account/create',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                configured
                    ? FluentIcons.check_mark
                    : FluentIcons.warning,
                size: 14,
                color: configured ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  configured
                      ? 'Keys saved — values never shown here'
                      : 'Not configured — Last.fm is disabled',
                  style: WaveType.meta,
                ),
              ),
              if (configured)
                WaveButton(
                  onPressed: _busy ? null : _clear,
                  child: const Text('Clear'),
                ),
            ],
          ),
          const SizedBox(height: 10),
          const Text('API key', style: WaveType.label),
          const SizedBox(height: 4),
          TextBox(
            decoration: waveInputDecoration(),
            controller: _key,
            placeholder: '32-character hex key',
          ),
          const SizedBox(height: 8),
          const Text('Shared secret', style: WaveType.label),
          const SizedBox(height: 4),
          TextBox(
            decoration: waveInputDecoration(),
            controller: _secret,
            placeholder: 'Shared secret',
            obscureText: true,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: WaveType.meta.copyWith(color: Colors.red),
            ),
          ],
          const SizedBox(height: 10),
          WaveFilledButton(
            onPressed: _busy ? null : _save,
            child: _busy
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: ProgressRing(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text('Validating…'),
                    ],
                  )
                : const Text('Save & validate'),
          ),
          const SizedBox(height: 6),
          Text(
            'Saving different keys signs you out — sessions belong '
            'to their API key. Reconnect afterwards.',
            style: WaveType.meta.copyWith(
              color: waveTextTertiary(context),
            ),
          ),
        ],
      ),
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
            onChanged: (v) => onUpdate((p) => p.setLiquidGlass(v)),
            title: 'Extra translucency',
            subtitle: 'Stronger Haze on panels (may cost FPS)',
          ),
          _SwitchRow(
            value: prefs.wavySeekbar,
            onChanged: (v) => onUpdate((p) => p.setWavySeekbar(v)),
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
        WaveSelect<String>(
          expanded: true,
          value: devices.any((d) => d.id == selected) ? selected : '',
          options: [
            const WaveSelectOption(value: '', label: 'System Default'),
            for (final d in devices)
              WaveSelectOption(
                value: d.id,
                label: d.displayName,
                hint: d.isDefault ? 'default' : null,
              ),
          ],
          onChanged: (v) async {
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: WaveType.trackTitle),
              Text(AudioQualityTiers.label(value), style: WaveType.meta),
            ],
          ),
        ),
        WaveSelect<int>(
          value: value,
          options: const [
            WaveSelectOption(value: 28, label: 'Dolby Atmos'),
            WaveSelectOption(value: 27, label: 'Hi-Res · 24/192'),
            WaveSelectOption(value: 7, label: 'Hi-Res · 24/96'),
            WaveSelectOption(value: 6, label: 'Lossless · 16/44.1'),
            WaveSelectOption(value: 5, label: '320k MP3'),
            WaveSelectOption(value: -1, label: 'Opus · YouTube'),
          ],
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  final String title;
  final String? subtitle;
  const _SwitchRow({
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: WaveType.trackTitle),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: WaveType.meta.copyWith(
                      color: waveTextSecondary(context),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: ToggleSwitch(
            checked: value,
            onChanged: enabled ? onChanged : null,
          )),
        ],
      ),
    );
  }
}
