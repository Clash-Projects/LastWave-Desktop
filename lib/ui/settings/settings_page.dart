import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/window.dart';
import '../../app/auth_gate.dart';
import '../../core/audio/stream_models.dart';
import '../../core/env/app_env.dart';
import '../../core/storage/prefs.dart';
import '../../features/addons/addon_api.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/innertube/yt_library_providers.dart';
import '../../features/innertube/yt_web_login.dart';
import '../components/artwork.dart';
import 'yt_profile_chooser.dart';
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
  ('sources', 'Sources', FluentIcons.cloud),
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
    // Reactive mirror — the API singleton never changes identity, so
    // watching innerTubeProvider alone would never rebuild this row.
    final connection = ref.watch(ytConnectionProvider);
    final account =
        ref.watch(ytAccountProvider).valueOrNull;
    return _Group(
      title: 'YouTube Music',
      subtitle: 'Personal library, history and uploads',
      child: connection.connected
          ? _connectedRow(context, ref, connection, account)
          : Row(
              children: [
                const Icon(FluentIcons.video, size: 18),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Not connected',
                    style: WaveType.trackTitle,
                  ),
                ),
                FilledButton(
                  onPressed: () =>
                      _ytConnect(context, ref),
                  child: const Text('Connect'),
                ),
              ],
            ),
    );
  }

  Widget _connectedRow(
    BuildContext context,
    WidgetRef ref,
    YtConnection connection,
    YtAccount? account,
  ) {
    final name = account?.name ?? '';
    // Same @-gate as the chooser: fresh parses never emit junk, but
    // this keeps every path honest if a shape ever surprises us.
    final handle = (account?.handle ?? '').startsWith('@')
        ? account!.handle
        : '';
    final email = account?.email ?? '';
    final idLine = handle.isNotEmpty
        ? handle
        : ytDisplayEmail(email);
    final since = DateTime.fromMillisecondsSinceEpoch(
      connection.connectedAtMillis,
      isUtc: false,
    );
    final sinceText =
        connection.connectedAtMillis > 0 ? ' · since ${since.year}-'
            '${since.month.toString().padLeft(2, '0')}-'
            '${since.day.toString().padLeft(2, '0')}' : '';
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
            crossAxisAlignment:
                CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name.isNotEmpty ? name : 'Connected',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.trackTitle,
              ),
              Text(
                name.isNotEmpty
                    ? sub
                    : 'Connected$sinceText',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.meta.copyWith(
                    color:
                        waveTextSecondary(context)),
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
  Future<void> _ytConnect(
    BuildContext context,
    WidgetRef ref,
  ) async {
    var cancelled = false;
    // Non-blocking wait dialog — Cancel just stops listening; the
    // user closes the browser window via the native guard (hide).
    // NOTE: popped via the dialog's OWN context. A rootNavigator pop
    // here would eat the settings page under the go_router ShellRoute.
    BuildContext? waitDialogContext;
    unawaited(showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        waitDialogContext = dialogContext;
        return ContentDialog(
          title: const Text('Sign in with Google'),
          content: const Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: ProgressRing(),
              ),
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
          actions: [
            Button(
              onPressed: () {
                cancelled = true;
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    ));
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
          'YtWebSignIn: flow returned header=${header == null ? 'null' : '${header.length} chars'} cancelled=$cancelled');
    }
    // Dismiss the wait dialog if it is still up.
    final waitCtx = waitDialogContext;
    if (waitCtx != null && waitCtx.mounted) {
      Navigator.of(waitCtx).maybePop();
    }
    if (cancelled || header == null || header.isEmpty) {
      if (!cancelled && context.mounted) {
        await showDialog(
          context: context,
          builder: (dialogContext) => ContentDialog(
            title: const Text('Sign-in incomplete'),
            content: const Text(
                'No session was captured. Please try again — if Google '
                'refuses the embedded browser, make sure you complete '
                'the sign-in fully before closing the window.'),
            actions: [
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
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

/// Card buttons: Switch (multi-channel roster), Add (account/channel),
/// Disconnect. Extracted so the row rebuilds cheaply.
class _CardActions extends ConsumerWidget {
  const _CardActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var channels = 0;
    for (final p in ref.watch(ytProfilesProvider)) {
      channels +=
          p.channels.isEmpty ? 1 : p.channels.length;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (channels >= 2)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Button(
              onPressed: () =>
                  _ytSwitch(context, ref),
              child: const Text('Switch'),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Button(
            onPressed: () =>
                _ytAddMenu(context, ref),
            child: const Text('Add'),
          ),
        ),
        Button(
          onPressed: () async {
            final tube = ref.read(innerTubeProvider);
            await tube.signOut();
            ref
                .read(ytConnectionProvider.notifier)
                .state = tube.connection;
          },
          child: const Text('Disconnect'),
        ),
      ],
    );
  }

  static Future<void> _ytSwitch(
    BuildContext context,
    WidgetRef ref,
  ) async {
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
    if (target.email == conn.profileEmail &&
        sel.pageId == conn.activePageId) {
      return; // already active
    }
    try {
      await switchYtIdentity(ref,
          profile: target, pageId: sel.pageId);
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

  static Future<void> _ytAddMenu(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final mode = await showDialog<String>(
      context: context,
      builder: (dialogContext) => ContentDialog(
        title: const Text('Add to YouTube Music'),
        content: const Text(
          'Add another Google login, or a brand channel on the '
          'current login.',
          style: TextStyle(fontSize: 12),
        ),
        actions: [
          Button(
            onPressed: () =>
                Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          Button(
            onPressed: () =>
                Navigator.of(dialogContext).pop('channel'),
            child: const Text('Brand channel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop('account'),
            child: const Text('Google account'),
          ),
        ],
      ),
    );
    if (mode == null || !context.mounted) return;
    if (mode == 'account') {
      await _ytAddAccount(context, ref);
    } else {
      await _ytAddChannel(context, ref);
    }
  }

  /// Add another Google login: clean-room sign-in (logout URL first,
  /// same window, never destroyed), then the shared capture tail.
  static Future<void> _ytAddAccount(
    BuildContext context,
    WidgetRef ref,
  ) async {
    var cancelled = false;
    BuildContext? waitCtx;
    unawaited(showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        waitCtx = dialogContext;
        return ContentDialog(
          title: const Text('Add Google account'),
          content: const Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: ProgressRing(),
              ),
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
          actions: [
            Button(
              onPressed: () {
                cancelled = true;
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    ));
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
        await _showYtFail(context,
            'No session was captured. Please try again.');
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
  static Future<void> _ytAddChannel(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final w = await YtWebLogin.ensureWindow();
    if (w == null) {
      if (context.mounted) {
        await _showYtFail(
            context, 'No system WebView available.');
      }
      return;
    }
    if (!context.mounted) return;
    try {
      w.launch('https://music.youtube.com/');
    } catch (_) {}
    var cancelled = false;
    var done = false;
    BuildContext? waitCtx;
    unawaited(showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        waitCtx = dialogContext;
        return ContentDialog(
          title: const Text('Add brand channel'),
          content: const Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: ProgressRing(),
              ),
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
            Button(
              onPressed: () {
                cancelled = true;
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                done = true;
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Done'),
            ),
          ],
        );
      },
    ));
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
          await Future<void>.delayed(
              const Duration(milliseconds: 300));
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
        await _showYtFail(context,
            'No session was captured. Please try again.');
      }
      return;
    }
    if (!context.mounted) return;
    final pageId =
        await YtWebLogin.readDelegatedPageId(w) ?? '';
    if (kDebugMode) {
      debugPrint(
          'YtChannel: Done with pageId=${pageId.isEmpty ? 'main' : '${pageId.length} digits'}');
    }
    if (!context.mounted) return;
    await _ytConnectCaptured(
      context,
      ref,
      header: header,
      pageId: pageId,
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
  final profile = await upsertYtCapture(
    ref,
    cookies: header,
    pageId: pageId,
  );
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
    await _YtmStaticFallback.finish(
        context, ref, header, profile, pageId);
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
    await _showYtFail(
        context, 'Profile vanished — please try again.');
    return;
  }
  try {
    await switchYtIdentity(ref,
        profile: target, pageId: sel.pageId);
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
      ref.read(ytConnectionProvider.notifier).state =
          tube.connection;
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

Future<void> _showYtOk(
    BuildContext context, String title, String message) {
  return showDialog(
    context: context,
    builder: (dialogContext) => ContentDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        FilledButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(),
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
        FilledButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
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
          if (AppEnv.addonClientSecret.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'This build has no addon app key — addon calls will fail. '
                'Rebuild with ADDON_CLIENT_SECRET set.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          for (final u in urls)
            _AddonRow(
              url: u,
              quota: quotas[u],
              onRemove: () async {
                await onUpdate((p) => p.setAddonUrls(
                    urls.where((e) => e != u).toList()));
                ref.invalidate(losslessApiProvider);
              },
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: () =>
                  _addAddonDialog(context, ref, urls, onUpdate),
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
          controller: controller,
          placeholder: 'https://…/a/<token>/',
          maxLines: 2,
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
                'Expected something like https://host/a/<token>/.'),
            actions: [
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(),
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
      manifest =
          await AddonApi([parsed.root]).manifestFor(parsed.root);
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
              'or wrong URL. Nothing was saved.'),
          actions: [
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    final root = parsed.root;
    final next = [
      ...urls.where((e) => e != root),
      root,
    ];
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
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  manifest?.name ?? host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.trackTitle,
                ),
                Text(
                  manifest == null
                      ? '$host · unreachable'
                      : host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.meta.copyWith(
                      color:
                          waveTextSecondary(context)),
                ),
              ],
            ),
          ),
          Button(
            onPressed: () => onRemove(),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
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
            value: prefs.autoplaySimilar,
            onChanged: (v) =>
                onUpdate((p) => p.setAutoplaySimilar(v)),
            title: 'Autoplay similar',
            subtitle:
                'Keep playing related tracks after a queue ends',
          ),
          const SizedBox(height: 8),
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






