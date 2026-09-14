import '../../../ui/theme/tokens.dart';

/// Breakpoints (window width px):
/// compact <900 · normal 900–1300 · expanded 1300–1700 · ultrawide 1700+.
enum LwBreakpoint { compact, normal, expanded, ultrawide }

LwBreakpoint lwBreakpointFor(double width) {
  final w = waveBreakpointFor(width);
  return switch (w) {
    WaveBreakpoint.compact => LwBreakpoint.compact,
    WaveBreakpoint.normal => LwBreakpoint.normal,
    WaveBreakpoint.expanded => LwBreakpoint.expanded,
    WaveBreakpoint.ultrawide => LwBreakpoint.ultrawide,
  };
}

/// Density — desktop music player zones.
class LwDensity {
  LwDensity._();
  static const double railCollapsed = WaveDensity.railCollapsed; // 60
  static const double railExpanded = WaveDensity.railExpanded; // 200
  static const double titleBar = WaveDensity.titleBar; // 44
  static const double dock = WaveDensity.dock; // 80
  static const double trackRow = WaveDensity.trackRow; // 54
  static const double trackArt = WaveDensity.trackArt; // 40
  static const double contextPanel = WaveDensity.contextPanel; // 360
  static const double contextPanelWide = WaveDensity.contextPanelWide; // 380
  static const double contentMax = WaveDensity.contentMax; // 1280
  static const double lyricMax = WaveDensity.lyricMax; // 620
  static const double hitArea = WaveDensity.hitArea; // 36
  static const double iconPrimary = WaveDensity.iconPrimary; // 18
  static const double iconSecondary = WaveDensity.iconSecondary; // 15
}
