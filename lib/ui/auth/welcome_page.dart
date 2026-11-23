import 'dart:io' show Platform;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/lastfm/auth_repository.dart';
import '../components/buttons.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

const _githubUrl = 'https://github.com/Clash-Projects/LastWave-Desktop';

/// Clean, modern first-launch onboarding screen.
///
/// Rendered outside the main shell when the app is first launched.
/// Offers direct continuation into the player with no forced login or account,
/// alongside a GitHub repository link for community support.
class WaveWelcomePage extends ConsumerStatefulWidget {
  const WaveWelcomePage({super.key});

  @override
  ConsumerState<WaveWelcomePage> createState() => _WaveWelcomePageState();
}

class _WaveWelcomePageState extends ConsumerState<WaveWelcomePage> {
  bool _busy = false;
  String? _error;

  Future<void> _continue() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider.notifier).enterGuestMode();
      // AuthGate automatically redirects to /home upon entering the app.
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not start LastWave. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openGitHub() async {
    final uri = Uri.parse(_githubUrl);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
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
                  radius: 0.95,
                  colors: [
                    accent.withValues(alpha: dark ? 0.14 : 0.09),
                    Colors.transparent,
                  ],
                ),
              ),
              child: _CenterScroll(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 24,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const _WelcomeLogo(),
                          const SizedBox(height: 20),
                          Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: accent.withValues(alpha: 0.28),
                                ),
                              ),
                              child: Text(
                                'High-Resolution Audio Player',
                                style: WaveType.meta.copyWith(
                                  color: accent,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 11.5,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'LastWave',
                            textAlign: TextAlign.center,
                            style: WaveType.pageTitle.copyWith(
                              fontSize: 38,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.8,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Stream YouTube Music and lossless FLAC with synced lyrics, offline downloads, and zero clutter.',
                            textAlign: TextAlign.center,
                            style: WaveType.body.copyWith(
                              color: dark
                                  ? WaveColors.textSecondary
                                  : WaveColors.lightTextSecondary,
                              height: 1.4,
                              fontSize: 13.5,
                            ),
                          ),
                          const SizedBox(height: 24),
                          // Feature highlights
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 16,
                            ),
                            decoration: BoxDecoration(
                              color: dark
                                  ? Colors.white.withValues(alpha: 0.035)
                                  : Colors.black.withValues(alpha: 0.025),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: dark
                                    ? Colors.white.withValues(alpha: 0.07)
                                    : Colors.black.withValues(alpha: 0.06),
                              ),
                            ),
                            child: const Column(
                              children: [
                                _FeatureHighlight(
                                  icon: FluentIcons.equalizer,
                                  title: 'Lossless & Hi-Res Streaming',
                                  description:
                                      'Studio-grade audio up to 24-bit / 192 kHz with pure hardware decoding.',
                                ),
                                SizedBox(height: 14),
                                _FeatureHighlight(
                                  icon: FluentIcons.microphone,
                                  title: 'Dynamic Synced Lyrics',
                                  description:
                                      'Syllable and line-accurate karaoke animations with fluid text glow.',
                                ),
                                SizedBox(height: 14),
                                _FeatureHighlight(
                                  icon: FluentIcons.download,
                                  title: 'Fast & Offline Ready',
                                  description:
                                      'Save full tracks for offline listening with an integrated download manager.',
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          if (_error != null) ...[
                            InfoBar(
                              title: const Text('Error'),
                              content: Text(_error!),
                              severity: InfoBarSeverity.error,
                            ),
                            const SizedBox(height: 14),
                          ],
                          // Primary Continue Action
                          WaveFilledButton(
                            autofocus: true,
                            onPressed: _busy ? null : _continue,
                            style: const ButtonStyle(
                              padding: WidgetStatePropertyAll(
                                EdgeInsets.symmetric(vertical: 13),
                              ),
                            ),
                            child: _busy
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
                                : const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Continue',
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      SizedBox(width: 8),
                                      Icon(FluentIcons.chevron_right, size: 12),
                                    ],
                                  ),
                          ),
                          const SizedBox(height: 10),
                          // GitHub Star Action
                          WaveButton(
                            onPressed: _openGitHub,
                            style: const ButtonStyle(
                              padding: WidgetStatePropertyAll(
                                EdgeInsets.symmetric(vertical: 11),
                              ),
                            ),
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  FluentIcons.favorite_star,
                                  size: 14,
                                  color: Color(0xFFF59E0B),
                                ),
                                SizedBox(width: 8),
                                Text(
                                  'Star us on GitHub',
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 22),
                          const ExcludeSemantics(child: _EqualizerRow()),
                          const SizedBox(height: 14),
                          Text(
                            'Free & Open Source • No account required',
                            textAlign: TextAlign.center,
                            style: WaveType.meta.copyWith(
                              color: dark
                                  ? WaveColors.textTertiary
                                  : WaveColors.lightTextTertiary,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
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

class _FeatureHighlight extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _FeatureHighlight({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: dark ? 0.16 : 0.10),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: accent.withValues(alpha: dark ? 0.28 : 0.18),
            ),
          ),
          child: Icon(icon, size: 17, color: accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: WaveType.body.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 13.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: WaveType.meta.copyWith(
                  color: dark
                      ? WaveColors.textSecondary
                      : WaveColors.lightTextSecondary,
                  height: 1.35,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Scroll container that keeps centered content centered without overflow.
class _CenterScroll extends StatelessWidget {
  final Widget child;
  const _CenterScroll({required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: child,
        ),
      ),
    );
  }
}

/// Native window chrome for the chromeless window: drag region +
/// minimize / maximize / close controls.
class _WelcomeChrome extends StatelessWidget {
  const _WelcomeChrome();

  @override
  Widget build(BuildContext context) {
    return DragToMoveArea(
      child: SizedBox(
        height: WaveDensity.titleBar,
        child: Row(
          children: [
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

/// Equalizer motif bars — identity graphic.
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
    return SizedBox(
      height: 48,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (var i = 0; i < heights.length; i++)
            Container(
              width: 4.5,
              height: heights[i] * 0.62,
              decoration: BoxDecoration(
                borderRadius: WaveRadius.tinyRadius,
                color: i % 5 == 2
                    ? accent
                    : accent.withValues(alpha: 0.20 + (i % 5) * 0.12),
              ),
            ),
        ],
      ),
    );
  }
}

/// App logo above the title with soft ambient lighting.
class _WelcomeLogo extends StatelessWidget {
  const _WelcomeLogo();

  @override
  Widget build(BuildContext context) {
    final accent = waveAccent(context);
    final dark = waveIsDark(context);
    return Center(
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: dark ? 0.30 : 0.20),
              blurRadius: 36,
              spreadRadius: 2,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: Image.asset(
            'assets/brand/lastwave-logo.png',
            width: 84,
            height: 84,
            filterQuality: FilterQuality.medium,
            semanticLabel: 'LastWave logo',
          ),
        ),
      ),
    );
  }
}
