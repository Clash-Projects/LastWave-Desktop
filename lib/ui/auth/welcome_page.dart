import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/home/home_providers.dart';
import '../../features/lastfm/auth_repository.dart';
import '../components/buttons.dart' show LWTooltip;
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
    final wide = MediaQuery.sizeOf(context).width >= 860;
    return Mica(
      backgroundColor: dark
          ? WaveColors.background
          : WaveColors.lightBackground,
      child: Column(
        children: [
          const _WelcomeChrome(),
          Expanded(
            child: wide
                ? Row(
                    crossAxisAlignment:
                        CrossAxisAlignment.stretch,
                    children: [
                      const Expanded(
                        flex: 11,
                        child: _BrandVisual(),
                      ),
                      Container(
                        width: 1,
                        color: waveDivider(context),
                      ),
                      SizedBox(
                        width: 420,
                        child: _AuthPanel(
                          handshake: _handshake,
                          busy: _busy,
                          error: _error,
                          onConnect: _beginWebAuth,
                          onFinish: _completeWebAuth,
                          onGitHub: _openGitHub,
                        ),
                      ),
                    ],
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(
                        24, 8, 24, 32),
                    child: Column(
                      children: [
                        const _BrandVisualCompact(),
                        const SizedBox(height: 20),
                        _AuthPanel(
                          handshake: _handshake,
                          busy: _busy,
                          error: _error,
                          onConnect: _beginWebAuth,
                          onFinish: _completeWebAuth,
                          onGitHub: _openGitHub,
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Native window chrome for the chromeless window: drag region +
/// minimize / maximize / close. The main title bar lives in the shell,
/// which is never rendered here.
class _WelcomeChrome extends StatelessWidget {
  const _WelcomeChrome();

  @override
  Widget build(BuildContext context) {
    return DragToMoveArea(
      child: SizedBox(
        height: WaveDensity.titleBar,
        child: Row(
          children: [
            const SizedBox(width: 16),
            Text(
              'LASTWAVE',
              style: WaveType.overline.copyWith(
                color: waveTextTertiary(context),
              ),
            ),
            const Spacer(),
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
    return LWTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: WaveMotion.fast,
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
    );
  }
}

/// Left / primary visual area: branding + music composition.
class _BrandVisual extends StatelessWidget {
  const _BrandVisual();

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: dark ? 0.14 : 0.10),
            Colors.transparent,
            accent.withValues(alpha: dark ? 0.05 : 0.04),
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(56, 48, 56, 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: accent.withValues(alpha: 0.14),
                border: Border.all(
                  color: accent.withValues(alpha: 0.4),
                ),
              ),
              child: Icon(
                WaveIcons.music,
                size: 28,
                color: accent,
              ),
            ),
            const SizedBox(height: 28),
            Text(
              'LASTWAVE',
              style: WaveType.overline.copyWith(
                color: accent,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Hear everything\nabout you.',
              style: WaveType.pageTitle.copyWith(
                fontSize: 44,
                height: 1.05,
                color: dark
                    ? WaveColors.textPrimary
                    : WaveColors.lightTextPrimary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Your Last.fm, in full fidelity.',
              style: WaveType.body.copyWith(
                fontSize: 14,
                color: dark
                    ? WaveColors.textSecondary
                    : WaveColors.lightTextSecondary,
              ),
            ),
            const SizedBox(height: 28),
            const _WelcomeFeature(
              icon: WaveIcons.history,
              title: 'Scrobble-accurate',
              subtitle:
                  'Every play counts, precisely matched.',
            ),
            const SizedBox(height: 12),
            const _WelcomeFeature(
              icon: WaveIcons.albums,
              title: 'Lossless-first',
              subtitle: 'FLAC up to 24-bit / 192 kHz.',
            ),
            const SizedBox(height: 12),
            const _WelcomeFeature(
              icon: WaveIcons.device,
              title: 'Desktop-native',
              subtitle: 'Mica, media keys, offline cache.',
            ),
            const SizedBox(height: 32),
            const _EqualizerRow(),
          ],
        ),
      ),
    );
  }
}

/// Compact brand header for narrow windows.
class _BrandVisualCompact extends StatelessWidget {
  const _BrandVisualCompact();

  @override
  Widget build(BuildContext context) {
    final accent = waveAccent(context);
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: accent.withValues(alpha: 0.14),
            border: Border.all(
              color: accent.withValues(alpha: 0.4),
            ),
          ),
          child: Icon(
            WaveIcons.music,
            size: 22,
            color: accent,
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'LASTWAVE',
              style: WaveType.overline.copyWith(color: accent),
            ),
            const Text(
              'Hear everything about you.',
              style: WaveType.sectionTitle,
            ),
          ],
        ),
      ],
    );
  }
}

/// Feature bullet: 32px lucide glyph tile + title + one-line lede.
class _WelcomeFeature extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _WelcomeFeature({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            color: accent.withValues(alpha: 0.12),
            border: Border.all(
              color: waveDivider(context),
            ),
          ),
          child: Icon(icon, size: 16, color: accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: WaveType.label),
              const SizedBox(height: 1),
              Text(
                subtitle,
                style: WaveType.meta.copyWith(
                  color: dark
                      ? WaveColors.textSecondary
                      : WaveColors.lightTextSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
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
    return SizedBox(
      height: 72,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < heights.length; i++)
            Container(
              width: 5,
              height: heights[i],
              margin: const EdgeInsets.only(right: 7),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
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

/// Right / auth area: product name, why Last.fm, primary connect,
///
/// supporting text, and the optional GitHub star action.
class _AuthPanel extends StatelessWidget {
  final WebAuthHandshake? handshake;
  final bool busy;
  final String? error;
  final VoidCallback onConnect;
  final VoidCallback onFinish;
  final VoidCallback onGitHub;
  const _AuthPanel({
    required this.handshake,
    required this.busy,
    required this.error,
    required this.onConnect,
    required this.onFinish,
    required this.onGitHub,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 40, 36, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const _WelcomeMosaic(),
          const SizedBox(height: 20),
          Text(
            'LastWave',
            style: WaveType.pageTitle.copyWith(fontSize: 26),
          ),
          const SizedBox(height: 2),
          Text(
            'High-Resolution Lossless Music Player',
            style: WaveType.body.copyWith(
              fontWeight: FontWeight.w600,
              color: accent,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Connect Last.fm to personalize your music experience, '
            'sync your listening activity, recommendations and '
            'profile across LastWave.',
            style: WaveType.body.copyWith(
              color: dark
                  ? WaveColors.textSecondary
                  : WaveColors.lightTextSecondary,
            ),
          ),
          const SizedBox(height: 24),
          if (error != null) ...[
            InfoBar(
              title: const Text('Could not connect'),
              content: Text(error!),
              severity: InfoBarSeverity.error,
            ),
            const SizedBox(height: 12),
          ],
          FilledButton(
            onPressed: busy ? null : onConnect,
            style: ButtonStyle(
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(vertical: 13),
              ),
            ),
            child: busy && handshake == null
                ? const Row(
                    mainAxisAlignment:
                        MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 15,
                        height: 15,
                        child: ProgressRing(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text('Contacting Last.fm…'),
                    ],
                  )
                : Row(
                    mainAxisAlignment:
                        MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        FluentIcons.check_mark,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        handshake == null
                            ? 'Connect with Last.fm'
                            : 'Restart approval',
                      ),
                    ],
                  ),
          ),
          if (handshake != null) ...[
            const SizedBox(height: 10),
            Button(
              onPressed: busy ? null : onFinish,
              style: const ButtonStyle(
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(vertical: 11),
                ),
              ),
              child: busy
                  ? const Row(
                      mainAxisAlignment:
                          MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 15,
                          height: 15,
                          child:
                              ProgressRing(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text('Confirming…'),
                      ],
                    )
                  : const Text(
                      "I've approved — finish sign-in"),
            ),
            const SizedBox(height: 8),
            Text(
              'Approve LastWave in the browser tab that just opened, '
              'then finish sign-in here.',
              style: WaveType.meta.copyWith(
                color: dark
                    ? WaveColors.textTertiary
                    : WaveColors.lightTextTertiary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 10),
          Text(
            'Authentication opens through Last.fm — LastWave never asks '
            'for your Last.fm password.',
            style: WaveType.meta.copyWith(
              color: dark
                  ? WaveColors.textTertiary
                  : WaveColors.lightTextTertiary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          Container(
            height: 1,
            color: waveDivider(context),
          ),
          const SizedBox(height: 14),
          HyperlinkButton(
            onPressed: onGitHub,
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

/// Artwork mosaic strip above the connect action: six
/// chart-flavoured tiles with gradient fallbacks. Purely
/// decorative — signing in never depends on it loading.
class _WelcomeMosaic extends StatelessWidget {
  const _WelcomeMosaic();

  static const _seeds = [
    'lastwave-vinyl',
    'lastwave-stage',
    'lastwave-neon',
    'lastwave-studio',
    'lastwave-crowd',
    'lastwave-tape',
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < _seeds.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedNetworkImage(
                  imageUrl:
                      'https://picsum.photos/seed/${_seeds[i]}/160/160',
                  fit: BoxFit.cover,
                  fadeInDuration: WaveMotion.fast,
                  placeholder: (context, _) =>
                      _MosaicFallback(index: i),
                  errorWidget: (context, _, _) =>
                      _MosaicFallback(index: i),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _MosaicFallback extends StatelessWidget {
  final int index;
  const _MosaicFallback({required this.index});

  static const _tints = [
    Color(0xFF8A5A3B),
    Color(0xFF3B6E8A),
    Color(0xFF6E3B8A),
    Color(0xFF3B8A5A),
    Color(0xFF8A3B4E),
    Color(0xFF4E5A8A),
  ];

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final tint = _tints[index % _tints.length];
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            tint.withValues(alpha: dark ? 0.85 : 0.7),
            dark
                ? WaveColors.surfaceRaised
                : WaveColors.lightOverlay,
          ],
        ),
      ),
      child: Icon(
        WaveIcons.music,
        size: 20,
        color: Colors.white.withValues(alpha: 0.8),
      ),
    );
  }
}


