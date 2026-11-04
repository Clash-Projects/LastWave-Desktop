import 'dart:io' show Platform;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/storage/prefs.dart';
import '../../features/home/home_providers.dart';
import '../../features/lastfm/auth_repository.dart';
import '../../app/accessibility.dart';
import '../components/buttons.dart';
import '../components/inputs.dart';
import 'lastfm_key_guide.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

const _githubUrl =
    'https://github.com/Clash-Projects/LastWave-Desktop';

/// Mandatory Last.fm entry screen.
///
/// Rendered OUTSIDE the main shell: when there is no valid stored
/// session, this is the entire application — no Home, no player, no
/// navigation behind it. Authentication is the only way in; the
/// GitHub star action is strictly optional and secondary.
class WaveWelcomePage extends ConsumerStatefulWidget {
  const WaveWelcomePage({super.key});

  @override
  ConsumerState<WaveWelcomePage> createState() =>
      _WaveWelcomePageState();
}

class _WaveWelcomePageState
    extends ConsumerState<WaveWelcomePage> {
  WebAuthHandshake? _handshake;
  bool _busy = false;
  String? _error;

  Future<void> _beginWebAuth() async {
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
      AppAccessibility.announce(
        context,
        'Opening Last.fm in your browser. Approve LastWave there, then '
        'come back and press "I\'ve approved - finish sign-in".',
      );
      final uri = Uri.parse(handshake.url);
      try {
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri,
              mode: LaunchMode.externalApplication);
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

  Future<void> _completeWebAuth() async {
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
      // Personalization loads lazily, but refresh anything already
      // resolved so Home opens with this account's taste.
      ref.invalidate(feedProvider);
      // No manual navigation: the auth gate redirect enters /home.
    } catch (e) {
      if (!mounted) return;
      setState(() => _error =
          'Not approved yet — approve LastWave in the browser, then retry.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enterGuest() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider.notifier).enterGuestMode();
      // No manual navigation: the auth gate redirect enters /home.
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not continue as guest. Retry.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openGitHub() async {
    final uri = Uri.parse(_githubUrl);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri,
            mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    return Mica(
      backgroundColor: waveBackground(context),
      child: Column(
        children: [
          const _WelcomeChrome(),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.35),
                  radius: 0.9,
                  colors: [
                    accent.withValues(alpha: dark ? 0.12 : 0.08),
                    Colors.transparent,
                  ],
                ),
              ),
              child: _CenterScroll(
                child: Center(
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxWidth: 460),
                    child: _AuthPanel(
                      handshake: _handshake,
                      busy: _busy,
                      error: _error,
                      onConnect: _beginWebAuth,
                      onFinish: _completeWebAuth,
                      onSkip: _enterGuest,
                      onGitHub: _openGitHub,
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

/// Scroll container that keeps centered content centered: on tall
/// windows the child fills the viewport (so `MainAxisAlignment.center`
/// works); on short windows it scrolls instead of overflowing. Used by
/// both halves of the wide welcome layout — the auth panel grows with
/// the API-keys form, error bar, and handshake rows, and the brand
/// column is itself ~590px tall.
class _CenterScroll extends StatelessWidget {
  final Widget child;
  const _CenterScroll({required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(minHeight: constraints.maxHeight),
          child: child,
        ),
      ),
    );
  }
}

/// Native window chrome for the chromeless window: drag region +
/// minimize / maximize / close. The main title bar lives in the shell,
/// which is never rendered here.
///
/// macOS is the exception: `TitleBarStyle.hidden` hides the title bar
/// but keeps the native traffic lights, so the custom buttons are
/// omitted there and the brand label is inset past them.
class _WelcomeChrome extends StatelessWidget {
  const _WelcomeChrome();

  @override
  Widget build(BuildContext context) {
    return DragToMoveArea(
      child: SizedBox(
        height: WaveDensity.titleBar,
        child: Row(
          children: [
            // macOS keeps the native traffic lights above the chromeless
            // window (`TitleBarStyle.hidden` hides the bar, not the
            // buttons), so reserve their corner instead of drawing a
            // second, non-native set of controls.
            SizedBox(width: Platform.isMacOS ? 84 : 16),
            Text(
              'LASTWAVE',
              style: WaveType.overline.copyWith(
                color: waveTextTertiary(context),
              ),
            ),
            const Spacer(),
            if (!Platform.isMacOS) ...[
              _ChromeBtn(
                tooltip: 'Minimize',
                icon: WaveIcons.minimize,
                onTap: () async {
                  try {
                    await windowManager.minimize();
                  } catch (_) {}
                },
              ),
              _ChromeBtn(
                tooltip: 'Maximize',
                icon: WaveIcons.maximize,
                iconSize: 12,
                onTap: () async {
                  try {
                    if (await windowManager.isMaximized()) {
                      await windowManager.unmaximize();
                    } else {
                      await windowManager.maximize();
                    }
                  } catch (_) {}
                },
              ),
              _ChromeBtn(
                tooltip: 'Close',
                icon: WaveIcons.close,
                danger: true,
                onTap: () async {
                  try {
                    await windowManager.close();
                  } catch (_) {}
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ChromeBtn extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final double iconSize;
  final bool danger;
  final VoidCallback onTap;
  const _ChromeBtn({
    required this.tooltip,
    required this.icon,
    this.iconSize = 14,
    this.danger = false,
    required this.onTap,
  });

  @override
  State<_ChromeBtn> createState() => _ChromeBtnState();
}

class _ChromeBtnState extends State<_ChromeBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return WaveA11yButton(
      label: widget.tooltip,
      onTap: widget.onTap,
      child: LWTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: waveMotion(context, WaveMotion.fast),
            width: 46,
            height: WaveDensity.titleBar,
            color: _hover
                ? (widget.danger
                    ? WaveColors.danger
                    : (dark
                        ? Colors.white.withValues(alpha: 0.07)
                        : Colors.black.withValues(alpha: 0.06)))
                : Colors.transparent,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: _hover && widget.danger
                  ? Colors.white
                  : (dark
                      ? WaveColors.textSecondary
                      : WaveColors.lightTextSecondary),
            ),
          ),
        ),
      ),
    ),
    );
  }
}

/// Static equalizer motif — identity, not a live visualizer.
class _EqualizerRow extends StatelessWidget {
  const _EqualizerRow();

  @override
  Widget build(BuildContext context) {
    const heights = [
      18.0, 34.0, 52.0, 28.0, 64.0, 44.0, 72.0, 36.0, 56.0,
      24.0, 48.0, 68.0, 40.0, 58.0, 30.0, 50.0, 22.0, 42.0,
      60.0, 32.0, 46.0, 20.0, 38.0, 54.0,
    ];
    final accent = waveAccent(context);
    // Bars share the full width evenly (flex gaps) so the motif lines
    // up with the buttons above and below it.
    return SizedBox(
      height: 72,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (var i = 0; i < heights.length; i++)
            Container(
              width: 5,
              height: heights[i],
              decoration: BoxDecoration(
                borderRadius: WaveRadius.tinyRadius,
                color: i % 5 == 2
                    ? accent
                    : accent.withValues(
                        alpha: 0.25 + (i % 5) * 0.1),
              ),
            ),
        ],
      ),
    );
  }
}

/// Centered auth column: mosaic, product name, tagline, a primary guest
/// entry, Last.fm as the optional secondary connect, and the optional
/// GitHub star action.
class _AuthPanel extends ConsumerStatefulWidget {
  final WebAuthHandshake? handshake;
  final bool busy;
  final String? error;
  final VoidCallback onConnect;
  final VoidCallback onFinish;
  final VoidCallback onSkip;
  final VoidCallback onGitHub;
  const _AuthPanel({
    required this.handshake,
    required this.busy,
    required this.error,
    required this.onConnect,
    required this.onFinish,
    required this.onSkip,
    required this.onGitHub,
  });

  @override
  ConsumerState<_AuthPanel> createState() => _AuthPanelState();
}

class _AuthPanelState extends ConsumerState<_AuthPanel> {
  /// Last.fm keys are only asked for once the user opts into connecting.
  bool _wantsLastFm = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final handshake = widget.handshake;
    final busy = widget.busy;
    final error = widget.error;
    final tertiary =
        dark ? WaveColors.textTertiary : WaveColors.lightTextTertiary;
    // Subscribe to auth transitions (signingIn -> signedOut on a
    // successful key save) so `configured` re-evaluates: Prefs itself
    // never notifies, and without this the panel stays stale forever.
    ref.watch(authRepositoryProvider.select((s) => s.status));
    final configured = ref.watch(prefsProvider).isLastFmConfigured;
    final showKeys = !configured && _wantsLastFm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 32, 36, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const _WelcomeLogo(),
          const SizedBox(height: 28),
          Text(
            'LastWave',
            textAlign: TextAlign.center,
            style: WaveType.pageTitle.copyWith(fontSize: 40),
          ),
          const SizedBox(height: 6),
          Text(
            'High-Resolution Lossless Music Player',
            textAlign: TextAlign.center,
            style: WaveType.body.copyWith(
              fontWeight: FontWeight.w600,
              color: accent,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Stream YouTube Music and lossless FLAC up to 24-bit / '
            '192 kHz, with synced lyrics and offline downloads.',
            textAlign: TextAlign.center,
            style: WaveType.body.copyWith(
              color: dark
                  ? WaveColors.textSecondary
                  : WaveColors.lightTextSecondary,
            ),
          ),
          const SizedBox(height: 28),
          if (error != null) ...[
            Semantics(
              liveRegion: true,
              container: true,
              label: 'Error: $error',
              child: ExcludeSemantics(
                child: InfoBar(
                  title: const Text('Could not connect'),
                  content: Text(error),
                  severity: InfoBarSeverity.error,
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          WaveFilledButton(
            // Something must hold focus on first paint, or a screen
            // reader opens on an empty window with nothing to read.
            autofocus: handshake == null && !_wantsLastFm,
            onPressed: busy ? null : widget.onSkip,
            style: const ButtonStyle(
              padding: WidgetStatePropertyAll(
                EdgeInsets.symmetric(vertical: 13),
              ),
            ),
            child: busy && handshake == null && !_wantsLastFm
                ? const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 15,
                        height: 15,
                        child: ProgressRing(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text('Getting ready...'),
                    ],
                  )
                : const Text('Continue as guest'),
          ),
          const SizedBox(height: 8),
          Text(
            'Browse, stream and download right away. You can connect '
            'Last.fm later in Settings.',
            textAlign: TextAlign.center,
            style: WaveType.meta.copyWith(color: tertiary),
          ),
          const SizedBox(height: 20),
          if (showKeys) ...[
            const _ApiKeyForm(),
            const SizedBox(height: 12),
          ],
          WaveButton(
            onPressed: busy
                ? null
                : (!configured && !_wantsLastFm)
                    ? () => setState(() => _wantsLastFm = true)
                    : (!configured ? null : widget.onConnect),
            style: const ButtonStyle(
              padding: WidgetStatePropertyAll(
                EdgeInsets.symmetric(vertical: 11),
              ),
            ),
            child: busy && handshake == null && _wantsLastFm
                ? const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 15,
                        height: 15,
                        child: ProgressRing(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text('Contacting Last.fm...'),
                    ],
                  )
                : Text(
                    handshake == null
                        ? 'Connect with Last.fm'
                        : 'Restart approval',
                  ),
          ),
          if (handshake != null) ...[
            const SizedBox(height: 10),
            WaveButton(
              // Mounts when the browser approval starts: focus lands here,
              // so coming back from the browser reads the next step.
              autofocus: true,
              onPressed: busy ? null : widget.onFinish,
              style: const ButtonStyle(
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(vertical: 11),
                ),
              ),
              child: busy
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 15,
                          height: 15,
                          child: ProgressRing(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text('Confirming...'),
                      ],
                    )
                  : const Text("I've approved - finish sign-in"),
            ),
            const SizedBox(height: 8),
            Text(
              'Approve LastWave in the browser tab that just opened, '
              'then finish sign-in here.',
              semanticsLabel: 'Approve LastWave in the browser tab that '
                  'just opened, then finish sign-in here.',
              style: WaveType.meta.copyWith(color: tertiary),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Scrobbling, stats and taste sync. Authentication opens '
            'through Last.fm, LastWave never asks for your password.',
            style: WaveType.meta.copyWith(color: tertiary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          const ExcludeSemantics(child: _EqualizerRow()),
          const SizedBox(height: 24),
          Container(height: 1, color: waveDivider(context)),
          const SizedBox(height: 14),
          WaveLink(
            onPressed: widget.onGitHub,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(FluentIcons.favorite_star, size: 14),
                SizedBox(width: 6),
                Text('Star LastWave on GitHub'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


/// BYOK form: the user's own Last.fm API key + shared secret.
///
/// Shown on the welcome screen until keys are saved (Settings holds
/// the same editor for later changes). Validated with a signed
/// `auth.getToken` call before persisting; the parent rebuilds into
/// the connect flow on success.
class _ApiKeyForm extends ConsumerStatefulWidget {
  const _ApiKeyForm();
  @override
  ConsumerState<_ApiKeyForm> createState() => _ApiKeyFormState();
}

class _ApiKeyFormState extends ConsumerState<_ApiKeyForm> {
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
        setState(() => _error =
            e.toString().replaceFirst('LastFmException(null): ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    // Same subscription as the parent panel: a successful save flips
    // auth state, which rebuilds us so the success state below shows.
    ref.watch(authRepositoryProvider.select((s) => s.status));
    final saved = ref.watch(prefsProvider).isLastFmConfigured;
    _key ??= TextEditingController(
        text: ref.read(prefsProvider).lastFmApiKey);
    _secret ??= TextEditingController(
        text: ref.read(prefsProvider).lastFmApiSecret);
    if (saved && !_busy) {
      return Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          borderRadius: WaveRadius.floatingRadius,
          border: Border.all(color: waveDivider(context)),
        ),
        child: Row(
          children: [
            const Icon(FluentIcons.check_mark, size: 14),
            const SizedBox(width: 8),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                'Keys validated — connect with Last.fm below.',
                style: WaveType.meta.copyWith(color: Colors.green),
              ),
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        borderRadius: WaveRadius.floatingRadius,
        border: Border.all(color: waveDivider(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Last.fm API keys', style: WaveType.label),
          const SizedBox(height: 2),
          const SizedBox(height: 4),
          const LastFmKeyGuide(),
          const SizedBox(height: 8),
          Semantics(
            label: 'Last.fm API key',
            textField: true,
            child: TextBox(
              decoration: waveInputDecoration(),
              controller: _key,
              placeholder: 'API key',
              autofocus: true,
            ),
          ),
          const SizedBox(height: 8),
          Semantics(
            label: 'Last.fm shared secret',
            textField: true,
            obscured: true,
            child: TextBox(
              decoration: waveInputDecoration(),
              controller: _secret,
              placeholder: 'Shared secret',
              obscureText: true,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: WaveType.meta.copyWith(color: Colors.red),
              ),
            ),
          ],
          const SizedBox(height: 10),
          WaveButton(
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
                : const Text('Save keys'),
          ),
          const SizedBox(height: 6),
          Text(
            'LastWave ships with no keys of its own — these stay on '
            'this device.',
            style: WaveType.meta.copyWith(
              color: dark
                  ? WaveColors.textTertiary
                  : WaveColors.lightTextTertiary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// App logo above the title. Bundled asset, so it never depends on
/// the network.
class _WelcomeLogo extends StatelessWidget {
  const _WelcomeLogo();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Image.asset(
        'assets/brand/lastwave-logo.png',
        width: 96,
        height: 96,
        filterQuality: FilterQuality.medium,
        semanticLabel: 'LastWave logo',
      ),
    );
  }
}
