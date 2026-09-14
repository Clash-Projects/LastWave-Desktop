import 'package:fluent_ui/fluent_ui.dart';

import '../../../ui/theme/tokens.dart';

/// Strict viewport contract — every screen derives its workspace from the
/// window, never from arbitrary fixed heights that happen to fit 1080p.
///
/// ```
/// availableContentHeight = windowHeight - titleBar - playerDock
/// ```
///
/// The shell (`WaveShell`) already reserves title (44px) + dock (80px) via
/// `Column[Title, Expanded(content), Dock]` so content NEVER renders behind
/// the player. These helpers let panes size artwork/rows from the ACTUAL
/// constraints instead of hardcoding one size for every resolution.
class LwViewport {
  LwViewport._();

  static double availableHeight(BuildContext context) {
    final window = MediaQuery.sizeOf(context).height;
    return (window - WaveDensity.titleBar - WaveDensity.dock)
        .clamp(320, double.infinity);
  }

  /// Responsive page gutters — content never touches edges/nav/dock/bar.
  /// small 16–20 · normal 24–28 · wide 32.
  static double pageGutter(double windowWidth) {
    if (windowWidth < 900) return 16;
    if (windowWidth < 1300) return 24;
    return 32;
  }

  static EdgeInsets pagePadding(double windowWidth,
      {double top = 22, double bottom = 24}) {
    final side = pageGutter(windowWidth);
    return EdgeInsets.fromLTRB(side, top, side, bottom);
  }

  /// Centered content constraint — ultrawide never stretches past 1280.
  /// Use as `Center(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: LwViewport.contentMax), child: ...))`.
  static const double contentMax = 1280;

  /// Content width from constraints (already rail-aware). Prefer this over
  /// `MediaQuery.sizeOf(context).width` which overestimates by the rail.
  static double contentWidth(BoxConstraints c) => c.maxWidth;

  /// Clamp an overlay panel (queue) so it never covers >90% of content.
  static double panelWidth(double contentWidth,
      {double desired = 360, double min = 280}) {
    final budget = contentWidth * 0.9;
    // Tiny windows: respect the 90% budget even if below min (no overflow).
    if (budget < min) return budget.clamp(180.0, contentWidth);
    return desired.clamp(min, budget);
  }

  /// Cover-art sizing from constraints — never scrolls away, never clips,
  /// never forces horizontal scroll, never absurdly huge/microscopic.
  ///
  /// wide ~380–500 · medium ~300–400 · small ~220–320, derived from the
  /// actual available height/width minus [reservedForMetadata].
  static double artworkFor({
    required double availableHeight,
    required double availableWidth,
    required double reservedForMetadata,
    double desired = 400,
    double min = 220,
    double max = 500,
    double widthRatio = 0.42,
  }) {
    final fromHeight = availableHeight - reservedForMetadata;
    final fromWidth = availableWidth * widthRatio;
    return desired
        .clamp(min, max)
        .clamp(min, fromHeight.clamp(min, max))
        .clamp(min, fromWidth.clamp(min, max));
  }
}
