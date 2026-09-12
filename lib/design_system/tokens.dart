import 'package:flutter/material.dart';

/// LastWave desktop design tokens: single source of truth for colour,
/// type, spacing, radius and motion. No arbitrary values in features.
class LwColors {
  LwColors._();

  // Base dark surfaces (sophisticated, controlled colour).
  static const background = Color(0xFF0B0D12);
  static const surface = Color(0xFF12151C);
  static const surfaceRaised = Color(0xFF171B24);
  static const surfaceOverlay = Color(0xFF1E2330);
  static const outline = Color(0xFF262C3B);
  static const outlineSoft = Color(0xFF1B2130);

  static const textPrimary = Color(0xFFF2F4F9);
  static const textSecondary = Color(0xFFA7AEC0);
  static const textTertiary = Color(0xFF6B7386);

  static const defaultAccent = Color(0xFFE03030);
  static const hiRes = Color(0xFF00E5FF);
  static const losslessGreen = Color(0xFFC6F100);
  static const warn = Color(0xFFE0A030);
  static const danger = Color(0xFFE0506A);

  static const List<Color> accentChoices = [
    Color(0xFFE03030), // crimson
    Color(0xFF7C4DFF), // violet
    Color(0xFF2196C6), // ocean
    Color(0xFF6B9E6B), // sage
    Color(0xFFE0A030), // amber
    Color(0xFFE0507A), // rose
  ];
}

class LwSpacing {
  LwSpacing._();
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

class LwRadius {
  LwRadius._();
  static const double xs = 6;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 28;
  static const double pill = 999;
}

class LwMotion {
  LwMotion._();
  static const fast = Duration(milliseconds: 120);
  static const normal = Duration(milliseconds: 200);
  static const slow = Duration(milliseconds: 320);
  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeInOutCubic;
}

class LwType {
  LwType._();

  static const display = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    height: 1.15,
  );
  static const headline = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    height: 1.2,
  );
  static const title = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );
  static const body = TextStyle(fontSize: 13.5, height: 1.45);
  static const label = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.4,
  );
  static const caption = TextStyle(fontSize: 11.5, height: 1.4);
  static const micro = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
  );
}

/// Desktop breakpoints: compact → medium → wide.
enum LwBreakpoint { compact, medium, wide }

LwBreakpoint breakpointFor(double width) {
  if (width >= 1400) return LwBreakpoint.wide;
  if (width >= 1024) return LwBreakpoint.medium;
  return LwBreakpoint.compact;
}
