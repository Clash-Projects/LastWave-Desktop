import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../features/about/contributors_provider.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip, WaveFilledButton;
import '../theme/tokens.dart';

/// Hero branding card matching Android LastWave.
class AboutHeroCard extends StatelessWidget {
  final String appVersion;
  final VoidCallback? onDownloadMobile;

  const AboutHeroCard({
    super.key,
    required this.appVersion,
    this.onDownloadMobile,
  });

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final stroke = theme.resources.cardStrokeColorDefault;
    final accent = waveAccent(context);
    final dark = waveIsDark(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      decoration: BoxDecoration(
        color: theme.resources.cardBackgroundFillColorDefault,
        borderRadius: BorderRadius.circular(WaveRadius.floating),
        border: Border.all(color: stroke),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Circular App Icon with subtle ambient glow
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dark ? const Color(0xFF141414) : const Color(0xFFF3F3F3),
              border: Border.all(
                color: waveDivider(context),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: dark ? 0.32 : 0.20),
                  blurRadius: 28,
                  spreadRadius: 2,
                ),
              ],
            ),
            padding: const EdgeInsets.all(12),
            child: ClipOval(
              child: Image.asset(
                'assets/brand/lastwave-logo.png',
                fit: BoxFit.contain,
                semanticLabel: 'LastWave logo',
              ),
            ),
          ),
          const SizedBox(height: 14),
          // App Title
          Text(
            'LastWave',
            style: WaveType.pageTitle.copyWith(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          // Version Badge Chip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: accent.withValues(alpha: 0.30),
              ),
            ),
            child: Text(
              'Version $appVersion',
              style: WaveType.meta.copyWith(
                color: accent,
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Creator text with India flag
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Made by LastWave Team',
                style: WaveType.meta.copyWith(
                  color: waveTextSecondary(context),
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 6),
              const IndiaFlag(),
            ],
          ),
          const SizedBox(height: 14),
          // Download Mobile App Pill Button
          WaveFilledButton(
            onPressed: onDownloadMobile,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(FluentIcons.download, size: 14),
                SizedBox(width: 8),
                Text('Download Mobile App'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Clean vector representation of the Indian flag (Tricolor + 24-spoke Ashoka Chakra).
/// Drawn with CustomPaint instead of emoji fonts to ensure pixel-perfect rendering
/// across all platforms (Linux, Windows, macOS) without missing glyphs.
class IndiaFlag extends StatelessWidget {
  final double width;
  final double height;

  const IndiaFlag({
    super.key,
    this.width = 20,
    this.height = 13.3,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Indian Flag',
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(2.0),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 2,
              offset: const Offset(0, 0.5),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(2.0),
          child: CustomPaint(
            size: Size(width, height),
            painter: const _IndiaFlagPainter(),
          ),
        ),
      ),
    );
  }
}

class _IndiaFlagPainter extends CustomPainter {
  const _IndiaFlagPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final bandH = h / 3.0;

    // Saffron top band
    final saffronPaint = Paint()..color = const Color(0xFFFF9933);
    canvas.drawRect(Rect.fromLTWH(0, 0, w, bandH), saffronPaint);

    // White middle band
    final whitePaint = Paint()..color = const Color(0xFFFFFFFF);
    canvas.drawRect(Rect.fromLTWH(0, bandH, w, bandH), whitePaint);

    // Green bottom band
    final greenPaint = Paint()..color = const Color(0xFF138808);
    canvas.drawRect(Rect.fromLTWH(0, bandH * 2, w, bandH), greenPaint);

    // Ashoka Chakra in center of white band
    final chakraCenter = Offset(w / 2.0, h / 2.0);
    final chakraRadius = (bandH / 2.0) * 0.82;
    const navy = Color(0xFF000080);

    final rimPaint = Paint()
      ..color = navy
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.65;
    canvas.drawCircle(chakraCenter, chakraRadius, rimPaint);

    final hubPaint = Paint()
      ..color = navy
      ..style = PaintingStyle.fill;
    canvas.drawCircle(chakraCenter, chakraRadius * 0.22, hubPaint);

    // 24 spokes
    final spokePaint = Paint()
      ..color = navy
      ..strokeWidth = 0.45;
    for (int i = 0; i < 24; i++) {
      final angle = (i * 2.0 * math.pi) / 24.0;
      final dx = math.cos(angle);
      final dy = math.sin(angle);
      final start = Offset(
        chakraCenter.dx + dx * (chakraRadius * 0.2),
        chakraCenter.dy + dy * (chakraRadius * 0.2),
      );
      final end = Offset(
        chakraCenter.dx + dx * chakraRadius,
        chakraCenter.dy + dy * chakraRadius,
      );
      canvas.drawLine(start, end, spokePaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Styled interactive action tile for the About section.
class AboutActionTile extends StatefulWidget {
  final Widget icon;
  final Color? iconContainer;
  final Color? iconTint;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const AboutActionTile({
    super.key,
    required this.icon,
    this.iconContainer,
    this.iconTint,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  State<AboutActionTile> createState() => _AboutActionTileState();
}

class _AboutActionTileState extends State<AboutActionTile> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);

    final containerColor = widget.iconContainer ??
        (dark
            ? accent.withValues(alpha: 0.18)
            : accent.withValues(alpha: 0.12));
    final iconColor = widget.iconTint ?? (dark ? Colors.white : accent);

    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.99 : 1.0,
          duration: waveMotion(context, WaveMotion.fast),
          curve: Curves.easeOutCubic,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: _pressed
                  ? wavePressedWash(context)
                  : _hover
                      ? waveHoverWash(context)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(WaveRadius.controls),
            ),
            child: Row(
              children: [
                // Icon Badge
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: containerColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: IconTheme(
                      data: IconThemeData(size: 16, color: iconColor),
                      child: widget.icon,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                // Text Column
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.title,
                        style: WaveType.body.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.subtitle,
                        style: WaveType.meta.copyWith(
                          color: waveTextSecondary(context),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                // Trailing Action / Chevron
                widget.trailing ??
                    Icon(
                      FluentIcons.chevron_right,
                      size: 11,
                      color: waveTextTertiary(context),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Unified container card grouping action tiles with dividers.
class AboutCardGroup extends StatelessWidget {
  final List<Widget> children;

  const AboutCardGroup({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final stroke = theme.resources.cardStrokeColorDefault;
    final dividerColor = waveDivider(context);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.resources.cardBackgroundFillColorDefault,
        borderRadius: BorderRadius.circular(WaveRadius.floating),
        border: Border.all(color: stroke),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1)
              Divider(
                style: DividerThemeData(
                  decoration: BoxDecoration(color: dividerColor),
                  horizontalMargin: const EdgeInsets.symmetric(horizontal: 16),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Collapsible Contributors & Team expander card.
class ContributorsExpander extends ConsumerStatefulWidget {
  const ContributorsExpander({super.key});

  @override
  ConsumerState<ContributorsExpander> createState() =>
      _ContributorsExpanderState();
}

class _ContributorsExpanderState extends ConsumerState<ContributorsExpander> {
  bool _expanded = false;
  bool _hover = false;

  Future<void> _open(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final stroke = theme.resources.cardStrokeColorDefault;

    final contributorsAsync = ref.watch(contributorsProvider);
    final list = contributorsAsync.valueOrNull ?? bundledContributors;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.resources.cardBackgroundFillColorDefault,
        borderRadius: BorderRadius.circular(WaveRadius.floating),
        border: Border.all(color: stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header Bar (Clickable)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _expanded = !_expanded),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                color: _hover ? waveHoverWash(context) : Colors.transparent,
                child: Row(
                  children: [
                    // Heart Badge
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF5252).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Center(
                        child: Icon(
                          FluentIcons.heart_fill,
                          size: 16,
                          color: Color(0xFFFF5252),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    // Title and subtitle
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Contributors & Developers',
                            style: WaveType.body.copyWith(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Made with ❤️ by Clash-Projects contributors (${list.length})',
                            style: WaveType.meta.copyWith(
                              color: waveTextSecondary(context),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Overlapping avatar cluster preview
                    _buildAvatarCluster(context, list),
                    const SizedBox(width: 10),
                    // Animated Arrow
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0.0,
                      duration: waveMotion(context, WaveMotion.fast),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        FluentIcons.chevron_down,
                        size: 12,
                        color: waveTextSecondary(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Expanded Content Area
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity, height: 0),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Divider(
                    style: DividerThemeData(
                      decoration: BoxDecoration(color: waveDivider(context)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final c in list) _buildContributorChip(context, c),
                    ],
                  ),
                ],
              ),
            ),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: waveMotion(context, WaveMotion.fast),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatarCluster(BuildContext context, List<Contributor> list) {
    final previewCount = math.min(4, list.length);
    final remaining = list.length - previewCount;

    return SizedBox(
      height: 26,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: (previewCount * 18.0) + 8.0,
            height: 26,
            child: Stack(
              children: [
                for (var i = 0; i < previewCount; i++)
                  Positioned(
                    left: i * 18.0,
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: waveBackground(context),
                          width: 1.5,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: WaveArtwork.circle(
                        url: list[i].avatarUrl,
                        size: 26,
                        upgrade: false,
                        label: list[i].displayName,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (remaining > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: waveSurfaceRaised(context),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: waveDivider(context)),
              ),
              child: Text(
                '+$remaining',
                style: WaveType.meta.copyWith(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: waveTextSecondary(context),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildContributorChip(BuildContext context, Contributor c) {
    final isMaintainer = c.role.toLowerCase().contains('maintainer') ||
        c.role.toLowerCase().contains('founder');

    return _ContributorChipCard(
      contributor: c,
      isMaintainer: isMaintainer,
      onTap: () => _open(c.profileUrl),
    );
  }
}

class _ContributorChipCard extends StatefulWidget {
  final Contributor contributor;
  final bool isMaintainer;
  final VoidCallback onTap;

  const _ContributorChipCard({
    required this.contributor,
    required this.isMaintainer,
    required this.onTap,
  });

  @override
  State<_ContributorChipCard> createState() => _ContributorChipCardState();
}

class _ContributorChipCardState extends State<_ContributorChipCard> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final c = widget.contributor;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.95 : (_hover ? 1.03 : 1.0),
          duration: waveMotion(context, WaveMotion.fast),
          curve: Curves.easeOutCubic,
          child: LWTooltip(
            message: 'View ${c.displayName} on GitHub',
            child: Container(
              constraints: const BoxConstraints(minWidth: 160, maxWidth: 230),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: _pressed
                    ? wavePressedWash(context)
                    : _hover
                        ? waveHoverWash(context)
                        : (dark
                            ? waveSurfaceRaised(context)
                            : waveSurfaceOverlay(context)),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _hover
                      ? accent.withValues(alpha: 0.5)
                      : (widget.isMaintainer
                          ? accent.withValues(alpha: 0.3)
                          : waveDivider(context)),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Avatar
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: widget.isMaintainer
                            ? accent.withValues(alpha: 0.6)
                            : waveDivider(context),
                        width: 1,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: WaveArtwork.circle(
                      url: c.avatarUrl,
                      size: 34,
                      upgrade: false,
                      label: c.displayName,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Name and role
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          c.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WaveType.body.copyWith(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          c.role,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WaveType.meta.copyWith(
                            fontSize: 10.5,
                            color: widget.isMaintainer
                                ? accent
                                : waveTextSecondary(context),
                            fontWeight: widget.isMaintainer
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

