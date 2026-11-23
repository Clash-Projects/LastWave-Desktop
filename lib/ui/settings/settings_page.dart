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

import '../../app/auth_gate.dart';
import '../../core/app_info.dart';
import '../../core/audio/stream_models.dart';
import '../../core/diagnostics/diagnostics_log.dart';
import '../../core/env/app_env.dart';
import '../../core/storage/prefs.dart';
import '../../core/platform/renderer_mode.dart';
import '../../core/l10n/app_language.dart';
import '../../core/l10n/app_localizations.dart';
import '../../features/settings/app_fonts.dart';
import '../../features/settings/ui_scale.dart';
import '../../features/scrobblers/extra_scrobblers.dart';
import '../../features/addons/addon_api.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/innertube/yt_library_providers.dart';
import '../../features/innertube/yt_session_keeper.dart';
import '../../features/innertube/yt_web_login.dart';
import '../components/ambient.dart' show AmbientStyle, ambientStyleProvider;
import '../components/artwork.dart';
import '../components/select.dart';
import 'yt_profile_chooser.dart';
import 'spotify_connect.dart';
import '../../features/spotify/spotify_api.dart';
import '../../features/spotify/spotify_auth.dart';
import '../../features/home/home_providers.dart';
import '../../features/lastfm/auth_repository.dart';
import '../auth/lastfm_key_guide.dart';
import '../../features/settings/accent.dart';
import '../../features/settings/theme_controller.dart';
import '../../features/audio_output/output_controller.dart';
import '../../features/audio_output/output_path_sheet.dart';
import '../../features/lyrics/lyrics_providers.dart';
import '../theme/tokens.dart';
import '../theme/brand_icons.dart';
import '../../features/equalizer/equalizer_panel.dart';
import '../../features/equalizer/headphone_profiles.dart';
import '../../features/player/loudness.dart';
import '../../features/player/playback_service.dart';
import '../../features/performance/performance_controller.dart';
import '../../features/presence/discord_presence_service.dart';
import '../../features/updates/update_service.dart';
import '../updates/update_dialog.dart';
import 'backup_settings.dart';
import 'cache_settings.dart';
import 'diagnostics_actions.dart';
import 'download_layout_settings.dart';
import 'library_settings.dart';
import 'performance_mode_card.dart';
import 'settings_search.dart';
import '../theme/wave_icons.dart';

const waveSettingsSections = [
  ('general', 'General', WaveIcons.settings),
  ('appearance', 'Appearance', WaveIcons.theme),
  ('audio', 'Audio', WaveIcons.speaker),
  ('playback', 'Playback', WaveIcons.equalizer),
  ('lyrics', 'Lyrics', WaveIcons.lyrics),
  ('library', 'Library & Storage', WaveIcons.library),
  ('accounts', 'Accounts', FluentIcons.link),
  ('about', 'About', WaveIcons.info),
];

String normalizeSection(String? raw) {
  if (raw == null || raw.isEmpty) return 'general';
  return switch (raw.toLowerCase()) {
    'general' || 'display' || 'behaviour' || 'language' => 'general',
    'appearance' || 'theme' => 'appearance',
    'audio' || 'sound' => 'audio',
    'playback' => 'playback',
    'lyrics' => 'lyrics',
    'library' || 'downloads' || 'storage' => 'library',
    'accounts' || 'services' || 'lastfm' || 'integrations' || 'scrobbler' || 'spotify' || 'discord' => 'accounts',
    'about' || 'updates' || 'diagnostics' || 'sources' || 'experimental' => 'about',
    _ => 'general',
  };
}

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

String _sectionTitle(BuildContext context, String key, String fallback) {
  final l10n = context.l10n;
  return switch (key) {
    'general' => l10n.settingsGeneral,
    'appearance' => l10n.settingsAppearance,
    'audio' => l10n.settingsAudio,
    'playback' => l10n.settingsPlayback,
    'lyrics' => l10n.settingsLyrics,
    'library' => l10n.settingsLibrary,
    'accounts' => l10n.settingsAccounts,
    'about' => l10n.settingsAbout,
    _ => fallback,
  };
}

Future<void> _confirmDisablePerformanceMode(
  BuildContext context,
  WidgetRef ref,
  String featureName,
  VoidCallback onEnable,
) async {
  final l10n = context.l10n;
  await showDialog<bool>(
    context: context,
    builder: (ctx) => ContentDialog(
      constraints: const BoxConstraints(minWidth: 420, maxWidth: 460),
      title: Text(
        l10n.performanceModeConflictTitle,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      content: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 12),
        child: Text(
          'Enabling "$featureName" requires background GPU shaders and animations. This will turn off Performance Mode to apply your change.',
          style: const TextStyle(fontSize: 13, height: 1.4),
        ),
      ),
      actions: [
        Button(
          onPressed: () => Navigator.pop(ctx, false),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Text(
              l10n.performanceModeConflictCancel,
              maxLines: 1,
            ),
          ),
        ),
        FilledButton(
          onPressed: () {
            ref.read(performanceModeProvider.notifier).setPerformanceMode(false);
            onEnable();
            Navigator.pop(ctx, true);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Text(
              l10n.performanceModeConflictConfirm,
              maxLines: 1,
            ),
          ),
        ),
      ],
    ),
  );
}

class _WaveSettingsPageState extends ConsumerState<WaveSettingsPage> {
  late String _section;
  String? _highlightId;
  Timer? _highlightTimer;
  late final ScrollController _contentScrollController;
  late final ScrollController _narrowScrollController;
  late final ScrollController _railScrollController;

  @override
  void initState() {
    super.initState();
    _contentScrollController = ScrollController();
    _narrowScrollController = ScrollController();
    _railScrollController = ScrollController();
    _section = normalizeSection(widget.initialSection);
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _contentScrollController.dispose();
    _narrowScrollController.dispose();
    _railScrollController.dispose();
    super.dispose();
  }

  /// Opens the card's section, scrolls to it and outlines it for a moment.
  void _jump(SettingsSearchEntry entry) {
    final switching = _section != entry.section;
    setState(() {
      _section = entry.section;
      _highlightId = entry.id;
    });
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _highlightId = null);
    });
    // A section change cross-fades and resizes first; wait for it so the
    // scroll lands on the card's final position.
    Future<void>.delayed(Duration(milliseconds: switching ? 320 : 30), () {
      if (!mounted) return;
      final target = SettingsTarget.keys[entry.id]?.currentContext;
      if (target == null || !target.mounted) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.08,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _update(Future<void> Function(Prefs) fn) async {
    await fn(ref.read(prefsProvider));
    ref.read(themeControllerProvider.notifier).refresh();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSpotlight(
      activeId: _highlightId,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: SettingsSearchBox(onPick: _jump),
              ),
            ),
          ),
          Expanded(child: _layout()),
        ],
      ),
    );
  }

  Widget _layout() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Content-aware (rail-aware): LayoutBuilder sees real content
        // width, unlike MediaQuery window width (+200 rail error).
        final narrow = constraints.maxWidth < 900;
        if (narrow) {
          return ListView(
            controller: _narrowScrollController,
            physics: const ClampingScrollPhysics(),
            padding: waveDockPadding(context, const EdgeInsets.fromLTRB(16, 16, 16, 24)),
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
                    for (final s in waveSettingsSections)
                      ToggleButton(
                        checked: _section == s.$1,
                        onChanged: (_) => setState(() => _section = s.$1),
                        child: Text(_sectionTitle(context, s.$1, s.$2)),
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
            );
          }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 240,
              child: SingleChildScrollView(
                controller: _railScrollController,
                physics: const ClampingScrollPhysics(),
                padding: waveDockPadding(context, const EdgeInsets.fromLTRB(20, 20, 12, 20)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'SYSTEM',
                      style: WaveType.overline.copyWith(
                        color: waveAccent(context),
                      ),
                    ),
                    Text(context.l10n.navSettings, style: WaveType.pageTitle),
                    const SizedBox(height: 12),
                    for (final s in waveSettingsSections)
                      ListTile.selectable(
                        shape: RoundedRectangleBorder(
                          borderRadius: WaveRadius.controlsRadius,
                        ),
                        selected: _section == s.$1,
                        selectionMode: ListTileSelectionMode.single,
                        leading: Icon(s.$3, size: 16),
                        title: Text(
                          _sectionTitle(context, s.$1, s.$2),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onPressed: () => setState(() => _section = s.$1),
                      ),
                  ],
                ),
              ),
            ),
            Container(width: 1, color: waveDivider(context)),
            Expanded(
              child: ListView(
                controller: _contentScrollController,
                physics: const ClampingScrollPhysics(),
                padding: waveDockPadding(context, const EdgeInsets.fromLTRB(24, 20, 24, 24)),
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
    switch (normalizeSection(section)) {
      case 'general':
        return _GeneralSection(onUpdate: onUpdate);
      case 'appearance':
        return _AppearanceSection(onUpdate: onUpdate);
      case 'audio':
        return _AudioSection(onUpdate: onUpdate);
      case 'playback':
        return _PlaybackSection(onUpdate: onUpdate);
      case 'lyrics':
        return _LyricsSection(onUpdate: onUpdate);
      case 'library':
        return _LibrarySection(onUpdate: onUpdate);
      case 'accounts':
        return _AccountsSection(onUpdate: onUpdate);
      case 'about':
      default:
        return _AboutSection(onUpdate: onUpdate);
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
      AccentSource.system =>
        resolution.resolved
            ? 'Desktop accent · $hex'
            : 'This desktop exposes no accent — using custom colour',
      AccentSource.artwork =>
        resolution.resolved
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
  /// Search target id (see `settings_search.dart`). Null = not searchable.
  final String? id;
  final String title;
  final String subtitle;
  final Widget child;
  const _Group({
    this.id,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final card = _card(context);
    final id = this.id;
    return id == null ? card : SettingsTarget(id: id, child: card);
  }

  Widget _card(BuildContext context) {
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
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(WaveRadius.floating),
            ),
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

class _StatusPill extends StatelessWidget {
  final String label;
  final Color? color;
  const _StatusPill(this.label, {this.color});

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? WaveColors.success;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 1.5, 6, 2.5),
      decoration: BoxDecoration(
        color: effectiveColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1.1,
          color: effectiveColor,
        ),
      ),
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
    return SettingsTarget(
      id: 'accounts.connection',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFFD51007).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: Icon(
                    WaveIcons.music,
                    size: 16,
                    color: Color(0xFFE0506A),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            signedIn
                                ? auth.username
                                : (guest ? 'Guest mode' : 'Last.fm'),
                            style: WaveType.trackTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (signedIn) ...[
                          const SizedBox(width: 8),
                          const _StatusPill('Connected'),
                        ],
                      ],
                    ),
                    Text(
                      signedIn
                          ? 'Connected · Scrobbling & real-time discovery active'
                          : (guest
                              ? 'Last.fm disabled — save API keys below, then connect'
                              : 'Connect your Last.fm account to scrobble and personalize'),
                      style: WaveType.meta.copyWith(
                        color: waveTextSecondary(context),
                      ),
                    ),
                  ],
                ),
              ),
              if (signedIn)
                WaveButton(
                  onPressed: () => signOutEverywhere(ref),
                  child: const Text('Sign out'),
                )
              else
                const SizedBox.shrink(),
            ],
          ),
          if (!signedIn) ...[
            const SizedBox(height: 10),
            const _InShellConnect(),
          ],
          const SizedBox(height: 14),
          const _ApiKeys(),
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
      setState(
        () => _error =
            'Could not reach Last.fm. Check your connection and retry.',
      );
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
      setState(
        () => _error =
            'Not approved yet — approve LastWave in the browser, then retry.',
      );
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
          Text(_error!, style: WaveType.meta.copyWith(color: Colors.red)),
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
              : Text(
                  _handshake == null
                      ? 'Connect with Last.fm'
                      : 'Restart approval',
                ),
        ),
        if (!configured) ...[
          const SizedBox(height: 6),
          Text(
            'Save your API keys below first.',
            style: WaveType.meta.copyWith(color: waveTextTertiary(context)),
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

class _AudioSection extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _AudioSection({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    return Column(
      children: [
        _Group(
          id: 'audio.output',
          title: 'Audio output',
          subtitle: Platform.isWindows
              ? 'WASAPI Exclusive and hardware output routing'
              : 'System audio device and hardware routing',
          child: _WasapiOutputSettings(onUpdate: onUpdate),
        ),
        const SizedBox(height: 16),
        _Group(
          id: 'audio.quality',
          title: 'Streaming and Download quality',
          subtitle: 'High-fidelity lossless streaming and offline downloads',
          child: Column(
            children: [
              _QualityRow(
                title: 'Streaming quality',
                subtitle: 'Target audio fidelity for live network playback',
                value: prefs.losslessQuality,
                onChanged: (q) => onUpdate((p) => p.setLosslessQuality(q)),
              ),
              const SizedBox(height: 10),
              _QualityRow(
                title: 'Download quality',
                subtitle: 'Saved audio quality for offline library tracks',
                value: prefs.downloadQuality,
                onChanged: (q) => onUpdate((p) => p.setDownloadQuality(q)),
              ),
              const SizedBox(height: 10),
              _SwitchRow(
                value: prefs.preferLossless,
                onChanged: (v) => onUpdate((p) => p.setPreferLossless(v)),
                title: 'Prefer lossless',
                subtitle:
                    'Stream in lossless FLAC when available, otherwise standard high quality',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Group(
          id: 'audio.loudness',
          title: 'Loudness',
          subtitle:
              'Normalization · ${LoudnessMath.settingsSubtitle(prefs.loudnessMode)}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Normalization', style: WaveType.trackTitle),
              const SizedBox(height: 4),
              Text(
                'Prevents sudden volume jumps between quiet and loud songs',
                style:
                    WaveType.meta.copyWith(color: waveTextSecondary(context)),
              ),
              const SizedBox(height: 8),
              WaveSelect<String>(
                value: prefs.loudnessMode,
                options: const [
                  WaveSelectOption(
                    value: 'off',
                    label: 'Off',
                    hint: 'Original dynamic range untouched',
                  ),
                  WaveSelectOption(
                    value: 'track',
                    label: 'Track',
                    hint: 'Equal volume per track (best for shuffle & playlists)',
                  ),
                  WaveSelectOption(
                    value: 'album',
                    label: 'Album',
                    hint: 'Preserves dynamic contrasts across a full album',
                  ),
                ],
                onChanged: (mode) async {
                  await onUpdate((p) => p.setLoudnessMode(mode));
                  await ref
                      .read(playbackServiceProvider.notifier)
                      .applyAudioPrefs();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlaybackSection extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _PlaybackSection({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    final activeProfile = HeadphoneProfiles.byId(prefs.headphoneProfile);

    return Column(
      children: [
        _Playback(onUpdate: onUpdate),
        const SizedBox(height: 16),
        _Group(
          id: 'playback.headphones',
          title: 'Headphone correction',
          subtitle:
              'Calibrated acoustic response curves for popular headphones',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Acoustic profile', style: WaveType.trackTitle),
              const SizedBox(height: 4),
              Text(
                'Flattens frequency response for neutral, balanced sound reproduction',
                style:
                    WaveType.meta.copyWith(color: waveTextSecondary(context)),
              ),
              const SizedBox(height: 8),
              WaveSelect<String>(
                expanded: true,
                value: activeProfile.id,
                options: [
                  for (final profile in HeadphoneProfiles.all)
                    WaveSelectOption(
                      value: profile.id,
                      label: profile.name,
                      hint: profile.isOff ? null : profile.description,
                    ),
                ],
                onChanged: (id) async {
                  await onUpdate((p) => p.setHeadphoneProfile(id));
                  await ref
                      .read(playbackServiceProvider.notifier)
                      .applyAudioPrefs();
                },
              ),
              if (!activeProfile.isOff) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: waveSurface(context),
                    borderRadius: BorderRadius.circular(WaveRadius.menu),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        FluentIcons.headset,
                        size: 14,
                        color: waveAccent(context),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          activeProfile.description,
                          style: WaveType.meta.copyWith(
                            color: waveTextSecondary(context),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        _TimedMixSettings(onUpdate: onUpdate),
        const SizedBox(height: 16),
        _Group(
          id: 'playback.equalizer',
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

const _accentPresets = <Color>[
  Color(0xFFF5F4F0),
  Color(0xFF4CC2FF),
  Color(0xFFE03030),
  Color(0xFF7C4DFF),
  Color(0xFF2196C6),
  Color(0xFF6B9E6B),
  Color(0xFFE0A030),
  Color(0xFFE0507A),
];

class _Appearance extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Appearance({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    final theme = ref.watch(themeControllerProvider);
    final isPerfOn = ref.watch(performanceModeProvider);
    final l10n = context.l10n;
    // Each font's name drawn in its own typeface in the picker.
    final previews =
        ref.watch(appFontPreviewsProvider).valueOrNull ?? const {};
    return Column(
      children: [
        _Group(
          id: 'appearance.theme',
          title: 'Theme',
          subtitle: 'Midnight, Pearl, artwork, or your own colours',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  for (final (mode, label) in const [
                    ('dark', 'Midnight'),
                    ('light', 'Pearl'),
                    ('artwork', 'Artwork'),
                    ('custom', 'Custom'),
                  ]) ...[
                    if (mode != 'dark') const SizedBox(width: 8),
                    Expanded(
                      child: ToggleButton(
                        checked: switch (mode) {
                          'light' => theme.isLight,
                          'custom' => theme.isCustom,
                          'artwork' => theme.isArtwork,
                          _ =>
                            !theme.isLight &&
                                !theme.isCustom &&
                                !theme.isArtwork,
                        },
                        onChanged: (_) => ref
                            .read(themeControllerProvider.notifier)
                            .setThemeMode(mode),
                        child: Text(label),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              _SwitchRow(
                value: isPerfOn ? false : theme.glass,
                enabled: !isPerfOn,
                badgeText: isPerfOn ? l10n.performanceModeManagedTag : null,
                onDisabledTap: isPerfOn
                    ? () => _confirmDisablePerformanceMode(
                          context,
                          ref,
                          'Glassmorphism',
                          () => onUpdate((p) => p.setGlassmorphism(true)),
                        )
                    : null,
                onChanged: (v) => onUpdate((p) => p.setGlassmorphism(v)),
                title: 'Glassmorphism',
                subtitle: isPerfOn
                    ? 'Frosted glass is paused by Performance Mode to reduce GPU blur.'
                    : 'The whole app as frosted glass over the playing '
                        'artwork · works with every theme',
              ),
              if (theme.isCustom) ...[
                const SizedBox(height: 12),
                _CustomThemeEditor(base: theme.customBase),
              ],
              if (theme.isArtwork) ...[
                const SizedBox(height: 8),
                Text(
                  'Surfaces take their colour from the song that is playing '
                  'and blend as tracks change. Midnight while nothing plays.',
                  style: WaveType.meta.copyWith(
                    color: waveTextTertiary(context),
                  ),
                ),
              ],
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
                runSpacing: 8,
                children: [
                  for (final c in _accentPresets)
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
                      ),
                    ),
                  _PickColorSwatch(
                    tooltip: 'Pick any accent colour',
                    current: theme.accent,
                    selected: !_accentPresets.any(
                      (c) => c.toARGB32() == theme.accent.toARGB32(),
                    ),
                    onPicked: (c) => onUpdate((p) async {
                      await p.setAccentColor(c.toARGB32());
                      await p.setAccentSource(AccentSource.custom.id);
                    }),
                    dialogTitle: 'Accent colour',
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Group(
          id: 'appearance.haze',
          title: 'Haze material',
          subtitle: isPerfOn
              ? 'Solid mode active · Managed by Performance Mode'
              : 'Automatic uses Haze L1–L3 as designed · Solid disables blur',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              WaveSelect<String>(
                value: isPerfOn ? 'solid' : theme.hazeMaterial,
                options: const [
                  WaveSelectOption(value: 'automatic', label: 'Automatic'),
                  WaveSelectOption(value: 'haze', label: 'Haze'),
                  WaveSelectOption(value: 'solid', label: 'Solid'),
                ],
                onChanged: isPerfOn
                    ? (v) {
                        if (v != 'solid') {
                          _confirmDisablePerformanceMode(
                            context,
                            ref,
                            'Haze glass effects',
                            () => onUpdate((p) => p.setHazeMaterial(v)),
                          );
                        }
                      }
                    : (v) => onUpdate((p) => p.setHazeMaterial(v)),
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
                        onChanged: isPerfOn
                            ? (_) => _confirmDisablePerformanceMode(
                                  context,
                                  ref,
                                  'Haze intensity',
                                  () => onUpdate((p) => p.setHazeIntensity(opt)),
                                )
                            : (_) => onUpdate((p) => p.setHazeIntensity(opt)),
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

        const SizedBox(height: 16),
        _Group(
          id: 'appearance.font',
          title: 'Font',
          subtitle: 'The typeface used across the app',
          child: _BehaviourSelectRow(
            title: 'App font',
            subtitle: appFonts.firstWhere((f) => f.id == theme.font,
                        orElse: () => appFonts.first).web
                ? 'Downloaded once, then works offline.'
                : 'Installed with Windows.',
            value: appFonts.any((f) => f.id == theme.font) ? theme.font : '',
            options: [
              for (final f in appFonts)
                WaveSelectOption(
                  value: f.id,
                  label: f.label,
                  fontFamily: previews[f.id],
                ),
            ],
            onChanged: (v) => onUpdate((p) => p.setAppFont(v)),
          ),
        ),
        const SizedBox(height: 16),
        _Group(
          id: 'appearance.scale',
          title: 'Interface scale',
          subtitle: 'Adjust app zoom for display resolution or preference (Ctrl +/-)',
          child: _BehaviourSelectRow<double>(
            title: 'Zoom level',
            subtitle: 'Shortcuts: Ctrl + to zoom in, Ctrl - to zoom out, Ctrl 0 to reset.',
            value: ref.watch(uiScaleProvider),
            options: [
              for (final val in UiScalePresets.values)
                WaveSelectOption<double>(
                  value: val,
                  label: UiScalePresets.label(val),
                  hint: val == 1.0 ? 'Default' : '${(val * 100).round()}%',
                ),
            ],
            onChanged: (v) => ref.read(uiScaleProvider.notifier).setScale(v),
          ),
        ),
        const SizedBox(height: 16),
        _Group(
          id: 'appearance.surfaces',
          title: 'Surfaces',
          subtitle: 'Contrast and artwork tinting',
          child: Column(
            children: [
              _SwitchRow(
                value: prefs.amoled,
                enabled: !theme.isLight && !theme.isCustom && !theme.isArtwork,
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

/// Custom theme: preset base tones, any colour through the picker, and a
/// live preview of the generated surfaces.
class _CustomThemeEditor extends ConsumerWidget {
  final Color base;
  const _CustomThemeEditor({required this.base});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(themeControllerProvider.notifier);
    final argb = base.toARGB32();
    final isPreset = WaveSurfaces.customPresets.any(
      (p) => p.$2.toARGB32() == argb,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Base colour', style: WaveType.trackTitle),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (name, color) in WaveSurfaces.customPresets)
              _ColorSwatchButton(
                color: color,
                selected: color.toARGB32() == argb,
                tooltip: name,
                onTap: () => controller.setCustomBase(color),
              ),
            _PickColorSwatch(
              tooltip: 'Pick any base colour',
              current: base,
              selected: !isPreset,
              dialogTitle: 'Theme base colour',
              onPicked: controller.setCustomBase,
            ),
          ],
        ),
        const SizedBox(height: 10),
        _ThemePreview(
          surfaces: WaveSurfaces.fromCustomBase(base),
          light: WaveSurfaces.isLightBase(base),
        ),
        const SizedBox(height: 6),
        Text(
          'Dark colours give light text, light colours give dark text. '
          'Very bright or vivid picks are toned down so text stays readable.',
          style: WaveType.meta.copyWith(color: waveTextTertiary(context)),
        ),
      ],
    );
  }
}

/// A 28px colour dot: selected ring + check, same metrics as the accent
/// swatches.
class _ColorSwatchButton extends StatelessWidget {
  final Color color;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;
  final Widget? child;

  const _ColorSwatchButton({
    required this.color,
    required this.selected,
    required this.tooltip,
    required this.onTap,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return LWTooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              border: Border.all(
                color: selected ? waveAccent(context) : waveDivider(context),
                width: 2,
              ),
            ),
            child:
                child ??
                (selected
                    ? Icon(
                        FluentIcons.check_mark,
                        size: 14,
                        color: onAccentFor(color),
                      )
                    : null),
          ),
        ),
      ),
    );
  }
}

/// Last swatch in a row: opens the system-style colour picker. Shows the
/// current colour when it isn't one of the presets.
class _PickColorSwatch extends StatelessWidget {
  final String tooltip;
  final Color current;
  final bool selected;
  final String dialogTitle;
  final ValueChanged<Color> onPicked;

  const _PickColorSwatch({
    required this.tooltip,
    required this.current,
    required this.dialogTitle,
    required this.onPicked,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return _ColorSwatchButton(
      color: selected ? current : waveSurfaceOverlay(context),
      selected: selected,
      tooltip: tooltip,
      onTap: () async {
        final picked = await showWaveColorPicker(
          context,
          title: dialogTitle,
          initial: current,
        );
        if (picked != null) onPicked(picked);
      },
      child: selected
          ? null
          : Icon(WaveIcons.theme, size: 14, color: waveTextSecondary(context)),
    );
  }
}

/// Opens the Fluent colour picker (spectrum ring + hex) in a dialog.
/// Returns null when cancelled. Alpha is fixed at opaque.
Future<Color?> showWaveColorPicker(
  BuildContext context, {
  required String title,
  required Color initial,
}) {
  var picked = initial.withValues(alpha: 1);
  return showDialog<Color>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) => ContentDialog(
      constraints: const BoxConstraints(maxWidth: 380),
      title: Text(title),
      content: SingleChildScrollView(
        child: StatefulBuilder(
          builder: (context, setState) => ColorPicker(
            color: picked,
            onChanged: (c) => setState(() => picked = c.withValues(alpha: 1)),
            isAlphaEnabled: false,
            isAlphaSliderVisible: false,
            isAlphaTextInputVisible: false,
            isMoreButtonVisible: false,
            isColorChannelTextInputVisible: false,
          ),
        ),
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(picked),
          child: const Text('Apply'),
        ),
      ],
    ),
  );
}

/// Miniature of the generated theme: rail, page, card, raised and hover
/// tiles, dock, with real text tokens on top.
class _ThemePreview extends StatelessWidget {
  final WaveSurfaces surfaces;
  final bool light;
  const _ThemePreview({required this.surfaces, required this.light});

  @override
  Widget build(BuildContext context) {
    final text = light ? WaveColors.lightTextPrimary : WaveColors.textPrimary;
    final text2 = light
        ? WaveColors.lightTextSecondary
        : WaveColors.textSecondary;
    final accent = waveAccent(context);
    Widget tile(Color fill, String label) => Expanded(
      child: Container(
        height: 28,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: WaveRadius.controlsRadius,
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: WaveType.meta.copyWith(color: text2),
        ),
      ),
    );
    return ClipRRect(
      borderRadius: WaveRadius.artworkRadius,
      child: Container(
        height: 132,
        decoration: BoxDecoration(
          color: surfaces.background,
          border: Border.all(color: surfaces.outlineSoft),
          borderRadius: WaveRadius.artworkRadius,
        ),
        child: Column(
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 36,
                    decoration: BoxDecoration(
                      color: surfaces.railTranslucent,
                      border: Border(
                        right: BorderSide(color: surfaces.outlineSoft),
                      ),
                    ),
                    child: Column(
                      children: [
                        const SizedBox(height: 10),
                        Icon(WaveIcons.home, size: 14, color: accent),
                        const SizedBox(height: 12),
                        Icon(WaveIcons.search, size: 14, color: text2),
                        const SizedBox(height: 12),
                        Icon(WaveIcons.liked, size: 14, color: text2),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: surfaces.surface,
                          border: Border.all(color: surfaces.outlineSoft),
                          borderRadius: WaveRadius.controlsRadius,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Now playing',
                              style: WaveType.trackTitle.copyWith(color: text),
                            ),
                            const Spacer(),
                            Row(
                              children: [
                                tile(surfaces.surfaceRaised, 'Raised'),
                                const SizedBox(width: 8),
                                tile(surfaces.surfaceOverlay, 'Hover'),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              height: 26,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: surfaces.dockTranslucent,
                border: Border(top: BorderSide(color: surfaces.outlineSoft)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: text2.withValues(alpha: 0.35),
                        borderRadius: WaveRadius.tinyRadius,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Lyrics extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Lyrics({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    final activeProvider = LyricsProviderId.fromId(prefs.lyricsProviderId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Group(
          id: 'lyrics.animation',
          title: 'Lyrics animation',
          subtitle: 'Visual animation style for synced lyrics in Now Playing',
          child: _BehaviourSelectRow(
            title: 'Animation style',
            subtitle: switch (prefs.lyricsAnimation) {
              'glow_pulse' =>
                'Rich centered radial glow bloom with steady alignment',
              'karaoke_bounce' => 'Energetic rhythmic syllable bounce',
              'smooth_fade' => 'Minimalist clean highlight without motion',
              _ => 'Smooth fluid syllable wipe with gentle micro-float',
            },
            value: prefs.lyricsAnimation,
            options: [
              for (final entry in Prefs.lyricsAnimationOptions.entries)
                WaveSelectOption(value: entry.key, label: entry.value),
            ],
            onChanged: (v) => onUpdate((p) => p.setLyricsAnimation(v)),
          ),
        ),
        const SizedBox(height: 16),
        _Group(
          id: 'lyrics.timing',
          title: 'Timing',
          subtitle: 'Synced lyrics precision and primary metadata provider',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SwitchRow(
                value: prefs.wordByWord,
                onChanged: (v) => onUpdate((p) => p.setWordByWord(v)),
                title: 'Word-by-word lyrics',
                subtitle:
                    'Real-time karaoke word highlight. When disabled, highlights full lines.',
              ),
              const SizedBox(height: 12),
              const Text('Primary provider', style: WaveType.trackTitle),
              const SizedBox(height: 4),
              Text(
                'Source used first when matching lyrics for playing tracks',
                style:
                    WaveType.meta.copyWith(color: waveTextSecondary(context)),
              ),
              const SizedBox(height: 8),
              WaveSelect<String>(
                expanded: true,
                value: activeProvider.id,
                options: [
                  for (final provider in LyricsProviderId.values)
                    WaveSelectOption(
                      value: provider.id,
                      label: provider.title,
                      hint: provider.subtitle,
                    ),
                ],
                onChanged: (v) => onUpdate((p) => p.setLyricsProviderId(v)),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: waveSurface(context),
                  borderRadius: BorderRadius.circular(WaveRadius.menu),
                ),
                child: Row(
                  children: [
                    Icon(
                      FluentIcons.document,
                      size: 14,
                      color: waveAccent(context),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        activeProvider.subtitle,
                        style: WaveType.meta.copyWith(
                          color: waveTextSecondary(context),
                        ),
                      ),
                    ),
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

class _NowPlayingAmbient extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _NowPlayingAmbient({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentStyle = ref.watch(ambientStyleProvider);
    return _Group(
      id: 'lyrics.ambient',
      title: 'Now Playing ambient',
      subtitle: 'Dynamic backdrop styling behind cover art and lyrics',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final style in AmbientStyle.values) ...[
                if (style != AmbientStyle.values.first)
                  const SizedBox(width: 8),
                Expanded(
                  child: ToggleButton(
                    checked: currentStyle == style,
                    onChanged: (_) =>
                        ref.read(ambientStyleProvider.notifier).set(style),
                    child: Text(style.label),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            currentStyle == AmbientStyle.apple
                ? 'Vivid blurred colors sampled from the artwork on a dark stage with clean white text.'
                : 'A calm, subtle accent tone sampled from the artwork that harmonizes with your active app theme.',
            style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
          ),
        ],
      ),
    );
  }
}

class _LyricsSection extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _LyricsSection({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _Lyrics(onUpdate: onUpdate),
        const SizedBox(height: 16),
        _NowPlayingAmbient(onUpdate: onUpdate),
      ],
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
    return SettingsTarget(
      id: 'accounts.scrobbling',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: WaveColors.warn.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: Icon(
                    WaveIcons.gauge,
                    size: 15,
                    color: WaveColors.warn,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Scrobbling Rules', style: WaveType.trackTitle),
                    Text(
                      'Thresholds and live updates apply across all scrobbler services',
                      style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _SwitchRow(
            value: prefs.scrobblerEnabled,
            onChanged: (v) =>
                widget.onUpdate((p) => p.setScrobbler(enabled: v)),
            title: 'Enable scrobbling',
            subtitle: 'Send played tracks to connected scrobbler accounts',
          ),
          _SwitchRow(
            value: prefs.scrobbleNowPlaying,
            enabled: prefs.scrobblerEnabled,
            onChanged: (v) =>
                widget.onUpdate((p) => p.setScrobbler(nowPlaying: v)),
            title: 'Now playing updates',
            subtitle: 'Broadcast current playing track in real-time',
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Scrobble at ${percent.round()}% of track',
                        style: WaveType.trackTitle.copyWith(
                          color: prefs.scrobblerEnabled
                              ? null
                              : waveTextTertiary(context),
                        ),
                      ),
                      Text(
                        'Trigger scrobble after listening to ${percent.round()}% of the song',
                        style: WaveType.meta.copyWith(
                          color: waveTextTertiary(context),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: Slider(
                    value: percent,
                    min: 25,
                    max: 90,
                    onChanged: prefs.scrobblerEnabled
                        ? (v) => setState(() => _dragPercent = v)
                        : null,
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

/// Spotify account: two sign-in routes (system WebView, pasted `sp_dc`),
/// connection state, Canvas toggle.
class _SpotifyCard extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _SpotifyCard({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(spotifyAuthProvider);
    final prefs = ref.watch(prefsProvider);
    final isPerfOn = ref.watch(performanceModeProvider);
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: WaveColors.success.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Center(
                child: Icon(
                  WaveIcons.streamPath,
                  size: 16,
                  color: WaveColors.success,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        auth.connected ? 'Spotify' : 'Not connected',
                        style: WaveType.trackTitle,
                      ),
                      if (auth.connected) ...[
                        const SizedBox(width: 8),
                        const _StatusPill('Active'),
                      ],
                    ],
                  ),
                  Text(
                    auth.connected
                        ? 'Connected · Liked tracks, playlists & Canvas video loops enabled'
                        : 'Connect using session cookies to unlock Spotify Canvas & song radio',
                    style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
                  ),
                ],
              ),
            ),
            if (auth.connected)
              WaveButton(
                onPressed: () async {
                  await auth.disconnect();
                  ref.invalidate(spotifyPlaylistsProvider);
                },
                child: const Text('Disconnect'),
              )
            else ...[
              WaveFilledButton(
                onPressed: () => spotifyConnectWithCookie(context, ref),
                child: const Text('Login with cookies'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        _SwitchRow(
          value: isPerfOn ? false : prefs.spotifyCanvasEnabled,
          enabled: !isPerfOn,
          badgeText: isPerfOn ? l10n.performanceModeManagedTag : null,
          onDisabledTap: isPerfOn
              ? () => _confirmDisablePerformanceMode(
                    context,
                    ref,
                    'Spotify Canvas',
                    () => onUpdate((p) => p.setSpotifyCanvasEnabled(true)),
                  )
              : null,
          onChanged: (v) => onUpdate((p) => p.setSpotifyCanvasEnabled(v)),
          title: 'Spotify Canvas',
          subtitle: isPerfOn
              ? 'Video canvas is paused by Performance Mode to save CPU usage.'
              : 'Use Spotify\'s vertical looping video in the Canvas panel '
                  '(needs a connected account)',
        ),
        const SizedBox(height: 6),
        _BehaviourSelectRow(
          title: 'Recommendations',
          subtitle: prefs.recommendationSource == 'spotify'
              ? (auth.connected
                    ? 'Autoplay and radio use Spotify\'s own song radio.'
                    : 'Spotify is not connected, so YouTube Music is used '
                          'until you sign in.')
              : 'Autoplay and radio use YouTube Music\'s related songs.',
          value: prefs.recommendationSource,
          options: const [
            WaveSelectOption(value: 'youtube', label: 'YouTube Music'),
            WaveSelectOption(value: 'spotify', label: 'Spotify'),
          ],
          onChanged: (v) => onUpdate((p) => p.setRecommendationSource(v)),
        ),
      ],
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
          id: 'accounts.ytm',
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
                      onChanged: (v) => onUpdate((p) => p.setSyncYtHistory(v)),
                      title: 'Sync listening history',
                      subtitle: 'Songs you play here show up in your YouTube Music history',
                    ),
                  ],
                )
              : Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: WaveColors.danger.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Center(
                        child: Icon(
                          WaveIcons.play,
                          size: 16,
                          color: WaveColors.danger,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Not connected',
                            style: WaveType.trackTitle,
                          ),
                          Text(
                            'Sign in with Google to access playlists, liked songs & history',
                            style: WaveType.meta.copyWith(
                              color: waveTextSecondary(context),
                            ),
                          ),
                        ],
                      ),
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
          id: 'accounts.spotify',
          title: 'Spotify',
          subtitle: 'Your playlists, Liked Songs and Canvas',
          child: _SpotifyCard(onUpdate: onUpdate),
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
    final profiles = ref.watch(ytProfilesProvider);
    YtProfile? activeProfile;
    for (final profile in profiles) {
      if (profile.email == connection.profileEmail ||
          (connection.profileEmail.isEmpty &&
              profile.cookies == connection.cookies)) {
        activeProfile = profile;
        break;
      }
    }
    YtChannel? activeChannel;
    for (final channel in activeProfile?.channels ?? const <YtChannel>[]) {
      if (channel.pageId == connection.activePageId) {
        activeChannel = channel;
        break;
      }
    }
    // Provisional connections (identity transiently empty right after
    // login) fall back to the roster email so the card never renders
    // a bare "Connected" for a known account.
    final connEmail =
        activeProfile?.email ??
        (connection.profileEmail != 'unknown' ? connection.profileEmail : '');
    final rawName = account?.name ?? '';
    final name = rawName.isNotEmpty
        ? rawName
        : (activeChannel?.name.isNotEmpty == true
              ? activeChannel!.name
              : connection.accountName.isNotEmpty
              ? connection.accountName
              : connEmail);
    // Same @-gate as the chooser: fresh parses never emit junk, but
    // this keeps every path honest if a shape ever surprises us.
    final channelHandle = account?.handle.isNotEmpty == true
        ? account!.handle
        : (activeChannel?.handle.isNotEmpty == true
              ? activeChannel!.handle
              : connection.channelHandle);
    final handle = channelHandle.startsWith('@') ? channelHandle : '';
    final email = (account?.email ?? '').isNotEmpty
        ? account!.email
        : connEmail;
    final photoUrl = account?.photoUrl.isNotEmpty == true
        ? account!.photoUrl
        : (activeChannel?.photoUrl.isNotEmpty == true
              ? activeChannel!.photoUrl
              : connection.photoUrl);
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
        if (photoUrl.isNotEmpty)
          WaveArtwork.circle(
            url: photoUrl,
            size: 40,
            label: name,
            // Identity avatar: never let the official-source upgrade
            // swap it for a Deezer artist photo matching the name.
            upgrade: false,
          )
        else
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: WaveColors.danger.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Center(
              child: Icon(
                WaveIcons.play,
                size: 18,
                color: WaveColors.danger,
              ),
            ),
          ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      name.isNotEmpty ? name : 'Connected',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.trackTitle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const _StatusPill('Connected'),
                ],
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
        const SizedBox(width: 12),
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
  bool _busy = false;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    // One silent attempt per app run (shared with the shell info bar).
    // The persisted WebView2 profile survives restarts and updates, so
    // this works even when this run never opened the sign-in window.
    if (!YtSessionKeeper.autoAttempted && !YtSessionKeeper.isRunning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh(auto: true);
      });
    }
  }

  Future<void> _refresh({bool auto = false}) async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    final ok = auto
        ? await YtSessionKeeper.autoRecover(ref)
        : await YtSessionKeeper.refresh(ref, allowCreateWindow: true);
    if (!mounted) return;
    if (auto && !ok) {
      // Silent first attempt: no error dialog, the banner stays.
      setState(() => _busy = false);
      return;
    }
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
              child: SizedBox(width: 14, height: 14, child: ProgressRing()),
            )
          else
            WaveLink(onPressed: _refresh, child: const Text('Refresh')),
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
            // Otherwise the window's persisted Google login is re-captured
            // instantly on the next Connect.
            await YtWebLogin.signOutWebview();
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
              icon: WaveIcons.friends,
              title: 'Brand channel',
              subtitle:
                  'Add a channel on the current login (needs the '
                  'browser window)',
              onPressed: () => Navigator.of(dialogContext).pop('channel'),
            ),
            const SizedBox(height: 8),
            _YtAddOption(
              icon: FluentIcons.link,
              title: 'Cookies',
              subtitle:
                  'Paste a session exported from your own browser — '
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
      w.launch('https://music.youtube.com/', triggerOnUrlRequestEvent: false);
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
Future<void> _ytConnectWithCookies(BuildContext context, WidgetRef ref) async {
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
                'Google sees a normal desktop session. Brand channels on '
                'the same Google login are detected after connecting — '
                'pick one in the channel chooser.',
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
                      // The picker is not modal everywhere (Linux
                      // portals): the dialog may have closed and its
                      // controller been disposed while it was open.
                      if (!context.mounted) return;
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
                  style: TextStyle(fontSize: 12, color: Colors.red),
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
                  Navigator.of(dialogContext)
                      .pop(InnerTubeMusicApi.normalizeCookies(text));
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
    await _ytConnectCaptured(context, ref, header: result, pageId: '');
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
            style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
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
  // A captured jar is account-level: the active channel rides per
  // request (`X-Goog-PageId`), never in the cookies. Ask YouTube which
  // channels this login can act as and seed them into the roster, so
  // the chooser can offer brand channels even when the capture came
  // from pasted cookies (no WebView to read DELEGATED_SESSION_ID from).
  // Best-effort: an empty list keeps today's single-row behavior.
  if (profile != null) {
    final discovered = await ref
        .read(innerTubeProvider)
        .fetchChannelsFor(header);
    if (discovered.isNotEmpty) {
      await upsertYtChannels(
        ref,
        cookies: header,
        email: profile.email,
        channels: discovered,
      );
    }
  }
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
      body =
          'Google refuses to serve its sign-in page to embedded '
          'browsers — this is expected on macOS, and no in-app retry can '
          'get past that page.\n\n'
          'Use "Connect with cookies" instead: sign in to '
          'music.youtube.com in Chrome, Edge or Firefox, copy the cookie '
          'table, and paste it here. That jar is a normal browser '
          'session and works on every platform.';
    case YtSignInFailure.unavailable:
      title = 'No system WebView available';
      body =
          'This machine has no usable WebView runtime (WebView2 on '
          'Windows, WebKitGTK on Linux), so the sign-in window cannot '
          'open. Install the runtime, or connect with cookies instead — '
          'that path does not need a WebView.';
    case YtSignInFailure.startFailed:
      title = 'The sign-in window could not start';
      body =
          'WebView2 is installed, but the sign-in window failed to start '
          'twice. Quit LastWave completely (including the tray icon), '
          'open it again and retry. If it keeps happening, connect with '
          'cookies instead — that path does not need the window. The '
          'reason is recorded in the exported diagnostic logs.';
    case YtSignInFailure.blankPage:
      title = 'The sign-in window did not load';
      body =
          'The browser window stayed on a blank or error page even '
          'after reloading. That usually means the WebView profile '
          'folder is not writable or the runtime is damaged.\n\n'
          'Connecting with cookies does not depend on the WebView and '
          'will work.';
    case YtSignInFailure.timeout:
      title = 'Sign-in timed out';
      body =
          'No session was captured in ten minutes. Make sure the '
          'sign-in finishes on music.youtube.com — an intermediate '
          'accounts.google.com page has no YouTube session yet.\n\n'
          'You can try again, or connect with cookies instead.';
    case YtSignInFailure.noSession:
    case YtSignInFailure.none:
    case YtSignInFailure.windowClosed:
      title = 'Sign-in incomplete';
      body =
          'No session was captured. Complete the Google sign-in fully '
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
      id: 'about.addons',
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
        onPressed: () =>
            showUpdateDialog(context, _updateAvailable!, isManualCheck: true),
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
      id: 'about.about',
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
              Text(
                'LastWave Desktop · v$appVersion',
                style: WaveType.trackTitle,
              ),
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
                onPressed: () => _open('https://t.me/clashprojects'),
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
                onPressed: () => _open('https://discord.com/invite/TMCEPSUNk2'),
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

class _GeneralSection extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _GeneralSection({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        const SettingsTarget(
          id: 'general.performance',
          child: PerformanceModeCard(),
        ),
        const SizedBox(height: 16),
        _Behaviour(onUpdate: onUpdate),
        const SizedBox(height: 16),
        _Experimental(onUpdate: onUpdate),
      ],
    );
  }
}

class _AppearanceSection extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _AppearanceSection({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _Appearance(onUpdate: onUpdate);
  }
}

class _Behaviour extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Behaviour({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    return Column(
      children: [
        _Group(
          id: 'general.behaviour',
          title: 'Behaviour',
          subtitle: 'Startup and window defaults',
          child: Column(
            children: [
              _SwitchRow(
                value: prefs.closeToTray,
                onChanged: (v) => onUpdate((p) => p.setCloseToTray(v)),
                title: 'Minimize to system tray on close',
                subtitle:
                    'Keep the player running in the background when closed.',
              ),
              const SizedBox(height: 10),
              _BehaviourSelectRow(
                title: 'Miniplayer style',
                subtitle: switch (prefs.miniPlayerStyle) {
                  'compact' =>
                    'Ultra-slim strip with essential playback controls.',
                  'card' =>
                    'Square album artwork card with overlay controls.',
                  'ambient' =>
                    'Wide glowing panel with blurred artwork and seekbar.',
                  'lyrics' =>
                    'Dynamic ambient panel with live synced lyrics.',
                  _ =>
                    'Standard floating bar with artwork, title and controls.',
                },
                value: prefs.miniPlayerStyle,
                options: const [
                  WaveSelectOption(
                    value: 'classic',
                    label: 'Classic bar',
                    hint: 'Standard',
                  ),
                  WaveSelectOption(
                    value: 'compact',
                    label: 'Compact strip',
                    hint: 'Minimal',
                  ),
                  WaveSelectOption(
                    value: 'card',
                    label: 'Artwork card',
                    hint: 'Cover art',
                  ),
                  WaveSelectOption(
                    value: 'ambient',
                    label: 'Ambient wide',
                    hint: 'Artwork glow',
                  ),
                  WaveSelectOption(
                    value: 'lyrics',
                    label: 'Ambient + lyrics',
                    hint: 'Synced lyrics',
                  ),
                ],
                onChanged: (v) => onUpdate((p) => p.setMiniPlayerStyle(v)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Group(
          id: 'general.language',
          title: context.l10n.settingsLanguage,
          subtitle: context.l10n.settingsLanguageSub,
          child: const _LanguageSelectRow(),
        ),
      ],
    );
  }
}

class _LibrarySection extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _LibrarySection({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _Downloads(onUpdate: onUpdate),
        const SizedBox(height: 16),
        _Group(
          id: 'library.sync',
          title: 'Library',
          subtitle: 'Podcasts, YouTube Music sync, and hidden tracks',
          child: LibrarySettings(onUpdate: onUpdate),
        ),
        const SizedBox(height: 16),
        const _Group(
          id: 'library.cache',
          title: 'Cached data',
          subtitle: 'Pages saved on this device so they open instantly',
          child: CacheSettings(),
        ),
        const SizedBox(height: 16),
        const _Group(
          id: 'library.backup',
          title: 'Backup',
          subtitle: 'Move your playlists and settings to another device',
          child: BackupSettings(),
        ),
      ],
    );
  }
}

class _Diagnostics extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Diagnostics({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    return _Group(
      id: 'about.diagnostics',
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
            subtitle:
                'Adds per-request detail (stream clients, audio '
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
    );
  }
}

class _AccountsSection extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _AccountsSection({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _Ytm(onUpdate: onUpdate),
        const SizedBox(height: 16),
        _LastFm(onUpdate: onUpdate),
        const SizedBox(height: 16),
        _DiscordCard(onUpdate: onUpdate),
      ],
    );
  }
}

class _DiscordCard extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _DiscordCard({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    final isEnabled = prefs.discordRichPresence;
    final theme = FluentTheme.of(context);
    return _Group(
      id: 'accounts.discord',
      title: 'Discord',
      subtitle: 'Share your live playback status with friends on Discord',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF5865F2).withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: DiscordIcon(
                    size: 18,
                    color: Color(0xFF5865F2),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'Discord Rich Presence',
                          style: WaveType.trackTitle,
                        ),
                        if (isEnabled) ...[
                          const SizedBox(width: 8),
                          const _StatusPill('Active'),
                        ],
                      ],
                    ),
                    Text(
                      isEnabled
                          ? 'Broadcasting playback to local Discord client'
                          : 'Uses the local Discord desktop client · No bot or login required',
                      style: WaveType.meta.copyWith(
                        color: waveTextSecondary(context),
                      ),
                    ),
                  ],
                ),
              ),
              ToggleSwitch(
                checked: isEnabled,
                onChanged: (v) async {
                  await onUpdate((p) => p.setDiscordRichPresence(v));
                  try {
                    ref.read(discordPresenceProvider).refresh();
                  } catch (_) {}
                },
              ),
            ],
          ),
          if (isEnabled) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: theme.resources.cardBackgroundFillColorSecondary,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: waveDivider(context).withValues(alpha: 0.5),
                  width: 0.8,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFF5865F2),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Preview: ',
                    style: WaveType.label.copyWith(
                      color: waveTextSecondary(context),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      'Listening to LastWave · Track name, artist & elapsed time',
                      style: WaveType.meta.copyWith(
                        color: waveTextTertiary(context),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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

class _AboutSection extends ConsumerWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _AboutSection({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        const _About(),
        const SizedBox(height: 16),
        _Sources(onUpdate: onUpdate),
        const SizedBox(height: 16),
        _Diagnostics(onUpdate: onUpdate),
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
      id: 'playback.playback',
      title: 'Playback',
      subtitle: 'Queue behaviour, transitions and gapless playback',
      child: Column(
        children: [
          _SwitchRow(
            value: prefs.autoplaySimilar,
            onChanged: (v) => widget.onUpdate((p) => p.setAutoplaySimilar(v)),
            title: 'Autoplay similar',
            subtitle:
                'Keep playing related tracks and artist radio when a queue ends',
          ),
          const SizedBox(height: 8),
          _SwitchRow(
            value: prefs.crossfadeEnabled,
            badgeText: prefs.autoMixEnabled ? 'AutoMix Active' : null,
            onChanged: (v) async {
              await widget.onUpdate((p) => p.setCrossfade(v));
              await ref
                  .read(playbackServiceProvider.notifier)
                  .applyAudioPrefs();
              ref.read(audioOutputProvider.notifier).refreshPath();
            },
            title: 'Crossfade',
            subtitle: prefs.autoMixEnabled
                ? 'Standard crossfade is paused while beat-matched AutoMix is on'
                : prefs.crossfadeEnabled
                    ? 'Fades out the ending track while fading in the next over ${prefs.crossfadeSeconds}s'
                    : 'Gapless direct transition without overlapping audio',
          ),
          if (prefs.crossfadeEnabled && !prefs.autoMixEnabled) ...[
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
                      Text(
                        '3s (Quick fade)',
                        style: WaveType.meta.copyWith(
                          color: waveTextSecondary(context),
                        ),
                      ),
                      Text(
                        '7s (Recommended)',
                        style: WaveType.meta.copyWith(
                          color: waveTextSecondary(context),
                        ),
                      ),
                      Text(
                        '12s (Long blend)',
                        style: WaveType.meta.copyWith(
                          color: waveTextSecondary(context),
                        ),
                      ),
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
      id: 'library.offline',
      title: 'Offline',
      subtitle: 'Download location, folder organization and lyrics sidecars',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SwitchRow(
            value: prefs.downloadLyrics,
            onChanged: (v) => onUpdate((p) => p.setDownloadLyrics(v)),
            title: 'Download lyrics sidecars',
            subtitle:
                'Automatically saves synced .lrc files alongside downloaded music',
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: waveSurface(context),
              borderRadius: BorderRadius.circular(WaveRadius.menu),
            ),
            child: Row(
              children: [
                Icon(
                  FluentIcons.open_folder_horizontal,
                  size: 20,
                  color: waveAccent(context),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Save location', style: WaveType.trackTitle),
                      const SizedBox(height: 2),
                      Text(
                        custom.isEmpty ? 'Default music folder' : custom,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.meta.copyWith(
                          color: waveTextSecondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                WaveFilledButton(
                  onPressed: () => _pickDir(ref),
                  child: const Text('Change'),
                ),
                if (custom.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  WaveButton(
                    onPressed: () => onUpdate((p) => p.resetDownloadDir()),
                    child: const Text('Reset'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          DownloadLayoutSettings(onUpdate: onUpdate),
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
    return _Group(
      title: 'Scrobblers & History',
      subtitle: 'Send played tracks to Last.fm, ListenBrainz and Libre.fm',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Scrobbler(onUpdate: onUpdate),
          const SizedBox(height: 18),
          Container(height: 1, color: waveDivider(context)),
          const SizedBox(height: 18),
          _Account(onUpdate: onUpdate),
          const SizedBox(height: 18),
          Container(height: 1, color: waveDivider(context)),
          const SizedBox(height: 18),
          const _OtherScrobblers(),
        ],
      ),
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
      await ref
          .read(authRepositoryProvider.notifier)
          .saveCustomKeys(_key?.text ?? '', _secret?.text ?? '');
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
    // Lives inside the Last.fm connection card; the keys belong to it.
    return SettingsTarget(
      id: 'accounts.keys',
      child: Expander(
        initiallyExpanded: !configured,
        header: Row(
          children: [
            Icon(
              configured ? FluentIcons.permissions : FluentIcons.warning,
              size: 14,
              color: configured ? waveAccent(context) : Colors.orange,
            ),
            const SizedBox(width: 8),
            Text(
              configured
                  ? 'Advanced: Custom API Key & Secret'
                  : 'Setup Last.fm API Keys (Required)',
              style: WaveType.label,
            ),
            if (configured) ...[
              const SizedBox(width: 8),
              const _StatusPill('Configured'),
            ],
          ],
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Your own API credentials from last.fm/api/account/create',
              style: WaveType.meta.copyWith(color: waveTextTertiary(context)),
            ),
            const SizedBox(height: 10),
            const LastFmKeyGuide(),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  configured ? FluentIcons.check_mark : FluentIcons.warning,
                  size: 14,
                  color: configured ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    configured
                        ? 'Keys saved — values never shown in plain text'
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
              Text(_error!, style: WaveType.meta.copyWith(color: Colors.red)),
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
              style: WaveType.meta.copyWith(color: waveTextTertiary(context)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Experimental extends ConsumerStatefulWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _Experimental({required this.onUpdate});

  @override
  ConsumerState<_Experimental> createState() => _ExperimentalState();
}

class _ExperimentalState extends ConsumerState<_Experimental> {
  bool _impeller = false;
  bool _restartNeeded = false;

  @override
  void initState() {
    super.initState();
    RendererMode.isImpellerEnabled().then((val) {
      if (mounted) {
        setState(() => _impeller = val);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(prefsProvider);
    final isPerfOn = ref.watch(performanceModeProvider);
    final l10n = context.l10n;
    return _Group(
      id: 'general.experimental',
      title: 'Experimental',
      subtitle: 'Opt-in desktop prototypes',
      child: Column(
        children: [
          _SwitchRow(
            value: isPerfOn ? false : prefs.liquidGlass,
            enabled: !isPerfOn,
            badgeText: isPerfOn ? l10n.performanceModeManagedTag : null,
            onDisabledTap: isPerfOn
                ? () => _confirmDisablePerformanceMode(
                      context,
                      ref,
                      'Extra translucency',
                      () => widget.onUpdate((p) => p.setLiquidGlass(true)),
                    )
                : null,
            onChanged: (v) => widget.onUpdate((p) => p.setLiquidGlass(v)),
            title: 'Extra translucency',
            subtitle: isPerfOn
                ? 'Extra translucency is paused by Performance Mode to maintain FPS.'
                : 'Stronger Haze on panels (may cost FPS)',
          ),
          _SwitchRow(
            value: prefs.wavySeekbar,
            onChanged: (v) => widget.onUpdate((p) => p.setWavySeekbar(v)),
            title: 'Wavy seekbar',
            subtitle: 'Experimental timeline treatment',
          ),
          _SwitchRow(
            value: _impeller,
            onChanged: (v) async {
              setState(() {
                _impeller = v;
                _restartNeeded = true;
              });
              await RendererMode.setImpellerEnabled(v);
            },
            title: 'Impeller rendering engine (Experimental)',
            subtitle: 'Use Impeller backend instead of Skia (requires app restart)',
          ),
          if (_restartNeeded)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    FluentIcons.info,
                    size: 14,
                    color: FluentTheme.of(context).accentColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Restart LastWave to apply graphics renderer changes.',
                      style: TextStyle(
                        color: FluentTheme.of(context).accentColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
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

class _TimedMixSettings extends ConsumerStatefulWidget {
  final Future<void> Function(Future<void> Function(Prefs)) onUpdate;
  const _TimedMixSettings({required this.onUpdate});

  @override
  ConsumerState<_TimedMixSettings> createState() => _TimedMixSettingsState();
}

class _TimedMixSettingsState extends ConsumerState<_TimedMixSettings> {
  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(prefsProvider);
    return _Group(
      id: 'playback.automix',
      title: 'AutoMix',
      subtitle: prefs.autoMixEnabled
          ? 'Intelligent beat-matched DJ transitions active'
          : 'Seamless DJ-style beatmatched transitions between tracks',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SwitchRow(
            value: prefs.autoMixEnabled,
            badgeText: prefs.autoMixEnabled ? 'Beat-Matched' : null,
            onChanged: (v) async {
              await widget.onUpdate((p) => p.setAutoMixEnabled(v));
              await ref
                  .read(playbackServiceProvider.notifier)
                  .applyAudioPrefs();
            },
            title: 'Timed mix',
            subtitle: prefs.autoMixEnabled
                ? 'Blends each ending into the next song over ${prefs.autoMixBars} bars on beat, with a smooth bass handover. Album tracks stay gapless.'
                : 'Intelligently mixes consecutive tracks on beat without cutting music',
          ),
          if (prefs.autoMixEnabled) ...[
            const SizedBox(height: 10),
            const Text('Blend length', style: WaveType.trackTitle),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final (bars, label) in const [
                  (8, '8 bars (~15s)'),
                  (16, '16 bars (~30s)'),
                ]) ...[
                  if (bars != 8) const SizedBox(width: 8),
                  Expanded(
                    child: ToggleButton(
                      checked: prefs.autoMixBars == bars,
                      onChanged: (_) =>
                          widget.onUpdate((p) => p.setAutoMixBars(bars)),
                      child: Text(label),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            _SwitchRow(
              value: prefs.autoMixSpectral,
              onChanged: (v) async {
                await widget.onUpdate((p) => p.setAutoMixSpectral(v));
                await ref
                    .read(playbackServiceProvider.notifier)
                    .applyAudioPrefs();
              },
              title: 'Bass swap & EQ filters',
              subtitle:
                  'Hands the bassline over on beat and crosses frequencies, emulating a club DJ mixer.',
            ),
          ],
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

    final isBitPerfect = output.path.bitPerfect;
    final isExclusive = output.path.exclusiveActive;
    final statusColor = isBitPerfect
        ? WaveColors.success
        : (isExclusive ? waveAccent(context) : waveTextSecondary(context));
    final statusLabel = isBitPerfect
        ? 'Bit-Perfect'
        : (isExclusive ? 'Exclusive' : 'Shared Mixer');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Output device', style: WaveType.trackTitle),
        const SizedBox(height: 6),
        WaveSelect<String>(
          expanded: true,
          value: devices.any((d) => d.id == selected) ? selected : '',
          options: [
            const WaveSelectOption(
              value: '',
              label: 'System Default',
              hint: 'Follows OS audio settings',
            ),
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
        if (Platform.isWindows) ...[
          const SizedBox(height: 12),
          _SwitchRow(
            value: output.exclusiveRequested,
            onChanged: (v) async {
              await notifier.setExclusive(v);
              await onUpdate((_) async {});
            },
            title: 'WASAPI Exclusive',
            subtitle: isBitPerfect
                ? 'Bit-perfect direct PCM · Bypasses the Windows system mixer'
                : (output.exclusiveRequested
                      ? output.path.reason.label
                      : 'Shared mode — Audio is mixed with system sounds'),
          ),
        ],
        const SizedBox(height: 12),
        Expander(
          initiallyExpanded: false,
          header: Row(
            children: [
              Icon(
                WaveIcons.streamPath,
                size: 14,
                color: waveTextSecondary(context),
              ),
              const SizedBox(width: 8),
              Text(
                'Audio Pipeline & Hardware Details',
                style: WaveType.meta.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              _StatusPill(statusLabel, color: statusColor),
            ],
          ),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (output.selected != null &&
                  output.selected!.supportedSummary.isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: waveSurface(context),
                    borderRadius: BorderRadius.circular(WaveRadius.menu),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Reported DAC PCM Capabilities',
                        style: WaveType.overline.copyWith(
                          color: waveTextSecondary(context),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        output.selected!.supportedSummary,
                        style: WaveType.meta,
                      ),
                    ],
                  ),
                ),
              ] else if (output.selected == null) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    Platform.isWindows
                        ? 'Connect an external DAC to probe supported hardware PCM rates.'
                        : 'Using system audio output engine.',
                    style: WaveType.meta.copyWith(
                      color: waveTextSecondary(context),
                    ),
                  ),
                ),
              ],
              WaveStreamPathPanel(path: output.path),
            ],
          ),
        ),
      ],
    );
  }
}

class _QualityRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final int value;
  final ValueChanged<int> onChanged;
  const _QualityRow({
    required this.title,
    this.subtitle,
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
              const SizedBox(height: 2),
              Text(
                subtitle ?? AudioQualityTiers.label(value),
                style:
                    WaveType.meta.copyWith(color: waveTextSecondary(context)),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        WaveSelect<int>(
          value: value,
          options: const [
            WaveSelectOption(value: 28, label: 'Dolby Atmos', hint: 'Spatial'),
            WaveSelectOption(value: 27, label: 'Hi-Res · 24/192', hint: 'Lossless'),
            WaveSelectOption(value: 7, label: 'Hi-Res · 24/96', hint: 'Lossless'),
            WaveSelectOption(value: 6, label: 'Lossless · 16/44.1', hint: 'CD Quality'),
            WaveSelectOption(value: 5, label: '320k MP3', hint: 'High'),
            WaveSelectOption(value: -1, label: 'Opus · YouTube', hint: 'Standard'),
            WaveSelectOption(value: 4, label: 'Data saver', hint: 'Low data'),
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
  final VoidCallback? onDisabledTap;
  final String title;
  final String? subtitle;
  final String? badgeText;
  const _SwitchRow({
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.enabled = true,
    this.onDisabledTap,
    this.badgeText,
  });

  @override
  Widget build(BuildContext context) {
    final rowContent = Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(title, style: WaveType.trackTitle),
                  if (badgeText != null) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF107C41).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        badgeText!,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF107C41),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
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
        IgnorePointer(
          ignoring: !enabled,
          child: MouseRegion(
            cursor: enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: ToggleSwitch(
              checked: value,
              onChanged: enabled ? onChanged : null,
            ),
          ),
        ),
      ],
    );

    if (!enabled && onDisabledTap != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onDisabledTap,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: rowContent,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: rowContent,
    );
  }
}

class _BehaviourSelectRow<T> extends StatelessWidget {
  final String title;
  final String subtitle;
  final T value;
  final List<WaveSelectOption<T>> options;
  final ValueChanged<T> onChanged;
  const _BehaviourSelectRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: WaveType.trackTitle),
                Text(
                  subtitle,
                  style: WaveType.meta.copyWith(
                    color: waveTextSecondary(context),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 220,
            child: WaveSelect<T>(
              expanded: true,
              minMenuWidth: 220,
              value: value,
              options: options,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _LanguageSelectRow extends ConsumerWidget {
  const _LanguageSelectRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(appLanguageProvider);
    final l10n = context.l10n;
    final sub = current == AppLanguage.system
        ? l10n.tr('settings_language_system_sub')
        : (current.nativeDisplayName == current.englishName
            ? current.englishName
            : '${current.nativeDisplayName} (${current.englishName})');
    return _BehaviourSelectRow(
      title: l10n.settingsLanguage,
      subtitle: sub,
      value: current.tag,
      options: AppLanguage.values.map((lang) {
        final label = lang == AppLanguage.system
            ? l10n.tr('settings_language_system')
            : (lang.nativeDisplayName == lang.englishName
                ? lang.englishName
                : '${lang.nativeDisplayName} — ${lang.englishName}');
        return WaveSelectOption(value: lang.tag, label: label);
      }).toList(),
      onChanged: (tag) =>
          ref.read(appLanguageProvider.notifier).setLanguage(AppLanguage.fromTag(tag)),
    );
  }
}

/// ListenBrainz and Libre.fm: each listen goes to every connected service,
/// with or without Last.fm. Server fields take self-hosted instances.
class _OtherScrobblers extends ConsumerStatefulWidget {
  const _OtherScrobblers();
  @override
  ConsumerState<_OtherScrobblers> createState() => _OtherScrobblersState();
}

class _OtherScrobblersState extends ConsumerState<_OtherScrobblers> {
  final _lbToken = TextEditingController();
  final _lbServer = TextEditingController();
  final _lfUser = TextEditingController();
  final _lfPass = TextEditingController();
  final _lfServer = TextEditingController();
  bool _busy = false;
  String? _lbError;
  String? _lfError;

  @override
  void dispose() {
    for (final c in [_lbToken, _lbServer, _lfUser, _lfPass, _lfServer]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } finally {
      if (mounted) setState(() => _busy = false);
      ref.read(extraScrobblersRevisionProvider.notifier).state++;
    }
  }

  Widget _connected(
    String name,
    String user,
    String server,
    VoidCallback onOff,
  ) {
    return Row(
      children: [
        Flexible(
          child: Text(
            '@$user${server.isEmpty ? '' : ' · $server'}',
            style: WaveType.trackTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        const _StatusPill('Connected'),
        const Spacer(),
        WaveButton(
          onPressed: _busy ? null : onOff,
          child: const Text('Disconnect'),
        ),
      ],
    );
  }

  Widget _error(String? message) => message == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            message,
            style: WaveType.meta.copyWith(color: WaveColors.danger),
          ),
        );

  @override
  Widget build(BuildContext context) {
    ref.watch(extraScrobblersRevisionProvider);
    final prefs = ref.watch(prefsProvider);
    final lb = ref.read(listenBrainzProvider);
    final lf = ref.read(libreFmProvider);
    return SettingsTarget(
      id: 'accounts.others',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: const Color(0xFFEB743B).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: Icon(
                    WaveIcons.radio,
                    size: 15,
                    color: Color(0xFFEB743B),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('ListenBrainz', style: WaveType.trackTitle),
                    Text(
                      'Open music database scrobbler by MetaBrainz',
                      style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (lb.connected)
            _connected(
              'ListenBrainz',
              lb.username,
              prefs.listenBrainzServer,
              () => _run(lb.disconnect),
            )
          else ...[
            Text(
              'Paste your user token from listenbrainz.org/settings. Leave the '
              'server empty unless you self-host (Maloja, Koito, …).',
              style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextBox(
                    controller: _lbToken,
                    placeholder: 'User token',
                    obscureText: true,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextBox(
                    controller: _lbServer,
                    placeholder: 'Server (optional)',
                  ),
                ),
                const SizedBox(width: 8),
                WaveFilledButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          final err = await lb.connect(
                            _lbToken.text,
                            server: _lbServer.text,
                          );
                          if (mounted) setState(() => _lbError = err);
                        }),
                  child: const Text('Connect'),
                ),
              ],
            ),
            _error(_lbError),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: const Color(0xFF0072B5).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: Icon(
                    WaveIcons.streamPath,
                    size: 15,
                    color: Color(0xFF0072B5),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Libre.fm', style: WaveType.trackTitle),
                    Text(
                      'Free and open source GNU FM scrobbler',
                      style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (lf.connected)
            _connected(
              'Libre.fm',
              lf.username,
              prefs.libreFmServer,
              () => _run(lf.disconnect),
            )
          else ...[
            Text(
              'Sign in with your Libre.fm account. The server field takes '
              'other GNU FM instances.',
              style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextBox(controller: _lfUser, placeholder: 'Username'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextBox(
                    controller: _lfPass,
                    placeholder: 'Password',
                    obscureText: true,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextBox(
                    controller: _lfServer,
                    placeholder: 'Server (optional)',
                  ),
                ),
                const SizedBox(width: 8),
                WaveFilledButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          final err = await lf.connect(
                            _lfUser.text,
                            _lfPass.text,
                            server: _lfServer.text,
                          );
                          if (err == null) _lfPass.clear();
                          if (mounted) setState(() => _lfError = err);
                        }),
                  child: const Text('Sign in'),
                ),
              ],
            ),
            _error(_lfError),
          ],
        ],
      ),
    );
  }
}
