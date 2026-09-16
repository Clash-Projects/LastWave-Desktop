import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Fluent-native buttons with LastWave density.
///
/// - 38px hit areas, 16-20px glyphs, optical alignment.
/// - Native hover / pressed / disabled / focus via Fluent ButtonStyle.
/// - Smooth spring / cubic micro-interactions.
/// - Tooltips on every icon-only control.
class WaveIconButton extends StatefulWidget {
  final String tooltip;
  final Widget icon;
  final VoidCallback? onPressed;
  final bool selected;
  final bool filled;
  const WaveIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
    this.filled = false,
  });

  @override
  State<WaveIconButton> createState() => _WaveIconButtonState();
}

class _WaveIconButtonState extends State<WaveIconButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final accent = waveAccent(context);
    final dark = waveIsDark(context);
    final disabled = widget.onPressed == null;

    final style = ButtonStyle(
      padding: const WidgetStatePropertyAll(
        EdgeInsets.all(9),
      ),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.isDisabled) return Colors.transparent;
        if (widget.filled && widget.selected) {
          return accent.withValues(alpha: 0.22);
        }
        if (states.isPressed) {
          return (dark ? Colors.white : Colors.black)
              .withValues(alpha: WaveState.pressedAlpha);
        }
        if (states.isHovered) {
          return (dark ? Colors.white : Colors.black)
              .withValues(alpha: WaveState.hoverAlpha);
        }
        if (widget.selected) return accent.withValues(alpha: 0.14);
        return Colors.transparent;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.isDisabled) {
          return (dark
                  ? WaveColors.textTertiary
                  : WaveColors.lightTextTertiary)
              .withValues(alpha: 0.5);
        }
        if (widget.selected) return accent;
        return dark
            ? WaveColors.textSecondary
            : WaveColors.lightTextSecondary;
      }),
      shape: const WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius:
              BorderRadius.all(Radius.circular(WaveRadius.controls)),
        ),
      ),
    );

    final button = MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: Listener(
        onPointerDown: disabled ? null : (_) => setState(() => _pressed = true),
        onPointerUp: disabled ? null : (_) => setState(() => _pressed = false),
        onPointerCancel: disabled ? null : (_) => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: disabled ? 1.0 : (_pressed ? 0.93 : (_hover ? 1.05 : 1.0)),
          duration: WaveMotion.fast,
          curve: Curves.easeOutCubic,
          child: SizedBox(
            width: WaveDensity.hitArea,
            height: WaveDensity.hitArea,
            child: IconButton(
              icon: widget.icon,
              onPressed: widget.onPressed,
              style: style,
            ),
          ),
        ),
      ),
    );

    return LWTooltip(
      message: widget.tooltip,
      child: button,
    );
  }
}

/// Large circular transport button (play/pause only).
class WavePlayButton extends StatefulWidget {
  final bool playing;
  final bool buffering;
  final bool large;
  final VoidCallback? onPressed;
  final String tooltip;
  const WavePlayButton({
    super.key,
    required this.playing,
    this.buffering = false,
    this.large = false,
    required this.onPressed,
    this.tooltip = 'Play',
  });

  @override
  State<WavePlayButton> createState() => _WavePlayButtonState();
}

class _WavePlayButtonState extends State<WavePlayButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final accent = waveAccent(context);
    final dark = waveIsDark(context);
    // Black glyph on light (off-white) accents, white on dark ones.
    final onAccent =
        accent.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    final size = widget.large ? 48.0 : 40.0;
    final glyphSize = widget.large ? 22.0 : 19.0;
    final disabled = widget.onPressed == null;

    final button = MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: Listener(
        onPointerDown: disabled ? null : (_) => setState(() => _pressed = true),
        onPointerUp: disabled ? null : (_) => setState(() => _pressed = false),
        onPointerCancel: disabled ? null : (_) => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: disabled ? 1.0 : (_pressed ? 0.92 : (_hover ? 1.06 : 1.0)),
          duration: WaveMotion.fast,
          curve: Curves.easeOutCubic,
          child: SizedBox(
            width: size,
            height: size,
            child: FilledButton(
              onPressed: widget.onPressed,
              style: ButtonStyle(
                padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                backgroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.isDisabled) {
                    return (dark ? Colors.white : Colors.black)
                        .withValues(alpha: 0.08);
                  }
                  if (states.isPressed) return accent.withValues(alpha: 0.85);
                  if (states.isHovered) return accent.withValues(alpha: 0.92);
                  return accent;
                }),
                foregroundColor: WidgetStatePropertyAll(onAccent),
                shape: const WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(999)),
                  ),
                ),
              ),
              child: Center(
                child: widget.buffering
                    ? SizedBox(
                        width: glyphSize,
                        height: glyphSize,
                        child: ProgressRing(
                          strokeWidth: 2.5,
                          activeColor: onAccent,
                          backgroundColor:
                              onAccent.withValues(alpha: 0.25),
                        ),
                      )
                    : AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        transitionBuilder: (child, animation) =>
                            ScaleTransition(
                          scale: CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOutBack,
                          ),
                          child: FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                        ),
                        child: Icon(
                          widget.playing ? WaveIcons.pause : WaveIcons.play,
                          key: ValueKey(widget.playing),
                          size: glyphSize,
                          color: onAccent,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );

    return LWTooltip(
      message: widget.playing ? 'Pause' : 'Play',
      child: button,
    );
  }
}

class WavePrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  const WavePrimaryButton({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15),
            const SizedBox(width: 6),
          ],
          Text(label, style: WaveType.label),
        ],
      ),
    );
  }
}

class WaveGhostButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  const WaveGhostButton({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Button(
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15),
            const SizedBox(width: 6),
          ],
          Text(label, style: WaveType.label),
        ],
      ),
    );
  }
}

/// Small quality / meta chip (codec, bitrate, source).
class WaveChip extends StatelessWidget {
  final String label;
  final bool highlight;
  const WaveChip({super.key, required this.label, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: highlight
            ? accent.withValues(alpha: 0.16)
            : (dark ? Colors.white : Colors.black)
                .withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: highlight
              ? accent.withValues(alpha: 0.45)
              : (dark
                  ? WaveColors.outlineSoft
                  : WaveColors.lightOutline),
        ),
      ),
      child: Text(
        label,
        style: WaveType.overline.copyWith(
          fontSize: 9.5,
          color: highlight
              ? accent
              : (dark
                  ? WaveColors.textSecondary
                  : WaveColors.lightTextSecondary),
        ),
      ),
    );
  }
}

/// Canonical tooltip wrapper: 400ms hover wait per [WaveState.tooltipDelay].
///
/// Use for every icon-only control instead of raw [Tooltip].
class LWTooltip extends StatelessWidget {
  final String message;
  final Widget child;
  const LWTooltip({
    super.key,
    required this.message,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      style: const TooltipThemeData(
        waitDuration: WaveState.tooltipDelay,
      ),
      child: child,
    );
  }
}

/// Canonical 40px circular transport button.
///
/// Prefer [WavePlayButton] for new code — this alias is kept for
/// existing callers and renders identically (off-white fill, black
/// glyph). Pointer cursor on hover.
@Deprecated('Use WavePlayButton instead')
class LWPlaybackButton extends StatelessWidget {
  final bool playing;
  final bool primary;
  final VoidCallback? onPressed;
  final String? tooltip;
  const LWPlaybackButton({
    super.key,
    required this.playing,
    this.primary = true,
    required this.onPressed,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    const size = 40.0;
    final filled = primary;
    final bg = filled
        ? WaveColors.defaultAccent
        : Colors.transparent;
    final fg = filled
        ? Colors.black
        : (dark
            ? WaveColors.textSecondary
            : WaveColors.lightTextSecondary);
    final button = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: SizedBox(
        width: size,
        height: size,
        child: Button(
          onPressed: onPressed,
          style: ButtonStyle(
            padding:
                const WidgetStatePropertyAll(EdgeInsets.zero),
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.isDisabled) {
                return (dark ? Colors.white : Colors.black)
                    .withValues(alpha: 0.08);
              }
              if (states.isPressed && filled) {
                return bg.withValues(alpha: 0.82);
              }
              if (states.isHovered && filled) {
                return bg.withValues(alpha: 0.92);
              }
              if (states.isPressed) {
                return (dark ? Colors.white : Colors.black)
                    .withValues(alpha: WaveState.pressedAlpha);
              }
              if (states.isHovered) {
                return (dark ? Colors.white : Colors.black)
                    .withValues(alpha: WaveState.hoverAlpha);
              }
              return bg;
            }),
            foregroundColor: WidgetStatePropertyAll(fg),
            shape: const WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.all(Radius.circular(999)),
              ),
            ),
          ),
          child: Center(
            child: Icon(
              playing ? WaveIcons.pause : WaveIcons.play,
              size: WaveDensity.iconPrimary,
              color: fg,
            ),
          ),
        ),
      ),
    );
    final label = tooltip ?? (playing ? 'Pause' : 'Play');
    return LWTooltip(message: label, child: button);
  }
}

/// Canonical progress slider: 3px track, white fill, 10px thumb visible
/// on hover/drag only. Expands to available width.
class LWProgressSlider extends StatelessWidget {
  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  const LWProgressSlider({
    super.key,
    required this.value,
    this.onChanged,
    this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    return _WaveSliderBase(
      value: value,
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
    );
  }
}

/// Canonical volume slider: 3px track, configurable width (defaults to 84px), 10px thumb on hover only.
class LWVolumeSlider extends StatelessWidget {
  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final double width;
  const LWVolumeSlider({
    super.key,
    required this.value,
    this.onChanged,
    this.onChangeEnd,
    this.width = 84,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: _WaveSliderBase(
        value: value,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
      ),
    );
  }
}

class _WaveSliderBase extends StatefulWidget {
  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  const _WaveSliderBase({
    required this.value,
    this.onChanged,
    this.onChangeEnd,
  });

  @override
  State<_WaveSliderBase> createState() => _WaveSliderBaseState();
}

class _WaveSliderBaseState extends State<_WaveSliderBase> {
  bool _hover = false;
  bool _dragging = false;
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  double _fractionFor(double dx, double width) {
    if (width <= 0) return widget.value.clamp(0.0, 1.0);
    return (dx / width).clamp(0.0, 1.0).toDouble();
  }

  void _step(double delta) {
    final next = (widget.value + delta).clamp(0.0, 1.0).toDouble();
    widget.onChanged?.call(next);
    widget.onChangeEnd?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final base = dark ? Colors.white : Colors.black;
    final fill =
        dark ? WaveColors.textPrimary : WaveColors.lightTextPrimary;
    final showThumb = _hover || _dragging || _focus.hasFocus;
    final slider = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) {
          _focus.requestFocus();
          final box = context.findRenderObject() as RenderBox?;
          if (box == null || widget.onChanged == null) return;
          final local = box.globalToLocal(details.globalPosition);
          widget.onChanged!(_fractionFor(local.dx, box.size.width));
        },
        onHorizontalDragStart: (_) =>
            setState(() => _dragging = true),
        onHorizontalDragUpdate: (details) {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null || widget.onChanged == null) return;
          final local = box.globalToLocal(details.globalPosition);
          widget.onChanged!(_fractionFor(local.dx, box.size.width));
        },
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onChangeEnd?.call(widget.value.clamp(0.0, 1.0));
        },
        child: Focus(
          focusNode: _focus,
          onFocusChange: (_) => setState(() {}),
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
                event.logicalKey == LogicalKeyboardKey.arrowUp) {
              _step(0.05);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                event.logicalKey == LogicalKeyboardKey.arrowDown) {
              _step(-0.05);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.home) {
              _step(-widget.value);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.end) {
              _step(1.0 - widget.value);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: SizedBox(
            height: 16,
            child: Center(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final fraction =
                      widget.value.clamp(0.0, 1.0).toDouble();
                  final width = constraints.maxWidth;
                  final fillWidth = width * fraction;
                  final maxThumbLeft =
                      (width - 10).clamp(0.0, double.infinity).toDouble();
                  final thumbLeft = (fillWidth - 5)
                      .clamp(0.0, maxThumbLeft)
                      .toDouble();
                  return SizedBox(
                    height: 10,
                    child: Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        Container(
                          height: 3,
                          width: width,
                          decoration: BoxDecoration(
                            color: base.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(
                                WaveRadius.tiny),
                          ),
                        ),
                        Container(
                          height: 3,
                          width: fillWidth,
                          decoration: BoxDecoration(
                            color: fill,
                            borderRadius: BorderRadius.circular(
                                WaveRadius.tiny),
                          ),
                        ),
                        if (showThumb)
                          Positioned(
                            left: thumbLeft,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: fill,
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    return slider;
  }
}

