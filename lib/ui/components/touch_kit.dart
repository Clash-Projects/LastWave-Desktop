import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../theme/haze.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Shared touch primitives for the iPhone / iPad presentation layer.
///
/// Everything touch-first in LastWave composes these four pieces — a pressed
/// state, a floating material, an icon button and the play disc — so the tab
/// bar, mini-player, Now Playing tray and secondary UI behave and look like
/// one product. Sizes come from [WaveTouch], colours from the existing Wave
/// surface helpers; nothing here introduces a new palette.

/// Pressable wrapper: the one place that defines how a touch target responds.
///
/// Pressed state is a quick scale dip ([WaveMotion.fast], collapsed by the
/// OS reduce-motion switch through [waveMotion]) with optional selection
/// haptics. Not enabled (no `onTap` / `onLongPress`) it renders its child
/// untouched.
class WavePressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;
  final bool haptic;

  const WavePressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.95,
    this.haptic = false,
  });

  @override
  State<WavePressable> createState() => _WavePressableState();
}

class _WavePressableState extends State<WavePressable> {
  bool _down = false;

  void _setDown(bool value) {
    if (_down != value && mounted) setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _setDown(true) : null,
      onTapUp: enabled ? (_) => _setDown(false) : null,
      onTapCancel: enabled ? () => _setDown(false) : null,
      onTap: widget.onTap == null
          ? null
          : () {
              if (widget.haptic) HapticFeedback.selectionClick();
              widget.onTap!();
            },
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? widget.pressedScale : 1.0,
        duration: waveMotion(context, WaveMotion.fast),
        curve: WaveMotion.standard,
        child: widget.child,
      ),
    );
  }
}

/// Floating glass material for chrome that hovers over the page: the tab
/// bar, the mini-player and the Now Playing control tray.
///
/// A thin wrapper over [WaveHaze] (so the user's Material / Intensity
/// settings still decide blur vs. solid) with the shared hairline, radius
/// ([WaveTouch.floatRadius]) and [WaveElevation.floating] shadow. Content
/// is clipped to the radius so edge-to-edge children (progress hairlines)
/// follow the corners.
class WaveFloatingSurface extends StatelessWidget {
  final Widget child;
  final Color? artworkTint;
  final Color? base;
  final BorderRadius? borderRadius;

  const WaveFloatingSurface({
    super.key,
    required this.child,
    this.artworkTint,
    this.base,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final radius =
        borderRadius ?? BorderRadius.circular(WaveTouch.floatRadius);
    // The shadow lives on an outer box: LwHaze clips its own subtree to the
    // radius when the blur is on, which would cut a shadow passed to it.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: WaveElevation.floating(dark),
      ),
      child: WaveHaze(
        level: LwHazeLevel.l2,
        base: base ?? waveSurface(context),
        artworkTint: artworkTint,
        borderRadius: radius,
        border: Border.all(
          color: (dark ? Colors.white : Colors.black)
              .withValues(alpha: dark ? 0.09 : 0.08),
        ),
        child: ClipRRect(borderRadius: radius, child: child),
      ),
    );
  }
}

/// Icon button for touch surfaces: a [WaveTouch.hit] square with the shared
/// pressed state, an accent well when [selected], and a dimmed glyph when
/// disabled (`onPressed == null`).
class WaveTouchIconButton extends StatelessWidget {
  final IconData icon;

  /// Accessibility label (VoiceOver). Touch UI has no hover tooltip.
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final double size;
  final double iconSize;

  /// Glyph colour override (e.g. fixed white on the Now Playing stage).
  final Color? color;

  const WaveTouchIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.size = WaveTouch.hit,
    this.iconSize = WaveTouch.iconSecondary,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final base = color ?? waveTextSecondary(context);
    final glyph = !enabled
        ? base.withValues(alpha: 0.35)
        : selected
            ? (color ?? waveTextPrimary(context))
            : base;
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: WavePressable(
        onTap: onPressed,
        haptic: true,
        child: AnimatedContainer(
          duration: waveMotion(context, WaveMotion.fast),
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: selected
                ? waveAccent(context).withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: WaveRadius.controlsRadius,
          ),
          child: Center(child: Icon(icon, size: iconSize, color: glyph)),
        ),
      ),
    );
  }
}

/// The circular play / pause control — one of the two shapes (with chips)
/// allowed to be a full circle. Filled with the theme accent so a custom
/// accent colours the play affordance everywhere it appears; the glyph uses
/// [waveOnAccent] so the off-white default accent never swallows it.
class WavePlayDisc extends StatelessWidget {
  final bool playing;
  final bool busy;
  final double size;
  final VoidCallback? onPressed;

  const WavePlayDisc({
    super.key,
    required this.playing,
    required this.onPressed,
    this.busy = false,
    this.size = WaveTouch.playDisc,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: playing ? 'Pause' : 'Play',
      excludeSemantics: true,
      child: WavePressable(
        onTap: onPressed,
        haptic: true,
        pressedScale: 0.92,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: waveAccent(context)
                .withValues(alpha: onPressed == null ? 0.4 : 1.0),
            shape: BoxShape.circle,
            boxShadow: WaveElevation.transport(dark),
          ),
          child: Center(
            child: Icon(
              busy
                  ? WaveIcons.music
                  : playing
                      ? WaveIcons.pause
                      : WaveIcons.play,
              size: size * 0.4,
              color: waveOnAccent(context),
            ),
          ),
        ),
      ),
    );
  }
}
