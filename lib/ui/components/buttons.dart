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
          return wavePressedWash(context);
        }
        if (states.isHovered) {
          return waveHoverWash(context);
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
          duration: waveMotion(context, WaveMotion.fast),
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

/// Fluent's own push buttons resolve `MouseCursor.defer`, so they paint the
/// plain arrow — every Wave control sets the click cursor by hand, which made
/// "hover shows the pointer" true of some buttons and not others. These three
/// wrappers are that single rule for the plugin's buttons: use them instead of
/// a raw `Button` / `FilledButton` / `HyperlinkButton`. A disabled control
/// keeps the arrow, since there is nothing to click.
class WaveButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ButtonStyle? style;
  final bool autofocus;
  final FocusNode? focusNode;

  const WaveButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.onLongPress,
    this.style,
    this.autofocus = false,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: onPressed == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: Button(
          onPressed: onPressed,
          onLongPress: onLongPress,
          style: style,
          autofocus: autofocus,
          focusNode: focusNode,
          child: child,
        ),
      );
}

/// See [WaveButton] — the accent-filled variant.
class WaveFilledButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ButtonStyle? style;
  final bool autofocus;
  final FocusNode? focusNode;

  const WaveFilledButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.onLongPress,
    this.style,
    this.autofocus = false,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: onPressed == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: FilledButton(
          onPressed: onPressed,
          onLongPress: onLongPress,
          style: style,
          autofocus: autofocus,
          focusNode: focusNode,
          child: child,
        ),
      );
}

/// See [WaveButton] — the borderless text-link variant.
class WaveLink extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ButtonStyle? style;
  final bool autofocus;
  final FocusNode? focusNode;

  const WaveLink({
    super.key,
    required this.child,
    required this.onPressed,
    this.onLongPress,
    this.style,
    this.autofocus = false,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: onPressed == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: HyperlinkButton(
          onPressed: onPressed,
          onLongPress: onLongPress,
          style: style,
          autofocus: autofocus,
          focusNode: focusNode,
          child: child,
        ),
      );
}

/// Pointer feedback for a tappable surface that has no choreography of its
/// own: the pointer cursor and the house press dip.
///
/// Discover's rails each hand-rolled this before; this is the shared version.
/// It wraps whatever it is given, so a card keeps its own shape and a row dips
/// by a smaller amount — pass [pressedScale].
///
/// The dip is what makes the pointer-anchored route transition read as one
/// motion: the page grows out of a card that has already reacted under the
/// finger. A surface with its own hover choreography (a morphing artist cover,
/// a hero pill) should keep it rather than wrap here.
class WavePressable extends StatefulWidget {
  const WavePressable({
    super.key,
    required this.child,
    this.onTap,
    this.pressedScale = 0.97,
    this.cursor = SystemMouseCursors.click,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// Scale held while the pointer is down (the house dip is 0.97; a list row
  /// reads better at ~0.985 because it scales from its centre).
  final double pressedScale;

  final MouseCursor cursor;

  /// Opaque by default (the [WaveMediaCard] convention) so the gaps inside a
  /// card — between its cover and its title, say — still take the tap.
  final HitTestBehavior behavior;

  @override
  State<WavePressable> createState() => _WavePressableState();
}

class _WavePressableState extends State<WavePressable> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final live = widget.onTap != null;
    // Reduce motion: the dip is the only feedback, so keep the button
    // still rather than snapping it 3% smaller and back.
    final dip = widget.pressedScale;
    final reduce = waveReduceMotion(context);
    return MouseRegion(
      cursor: live ? widget.cursor : MouseCursor.defer,
      onExit: (_) {
        // A pointer that left mid-press will never deliver the up event here.
        if (_pressed) setState(() => _pressed = false);
      },
      child: GestureDetector(
        behavior: widget.behavior,
        onTapDown: live ? (_) => setState(() => _pressed = true) : null,
        onTapUp: live ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: live ? () => setState(() => _pressed = false) : null,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed && !reduce ? dip : 1.0,
          duration: waveMotion(context, WaveMotion.fast),
          curve: WaveMotion.standard,
          child: widget.child,
        ),
      ),
    );
  }
}

/// The hero's primary action: accent pill, contrast glyph, pressed dip.
///
/// Accent fill with a contrast glyph (`onAccentFor` — the accent can be
/// off-white, so a hardcoded white or black glyph would vanish on it), hover
/// 93%, pressed 82%. Home and Discover lead with the same pill.
class WavePlayPill extends StatefulWidget {
  final VoidCallback onTap;
  final String label;
  const WavePlayPill({super.key, required this.onTap, this.label = 'Play'});

  @override
  State<WavePlayPill> createState() => _WavePlayPillState();
}

class _WavePlayPillState extends State<WavePlayPill> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final onAccent = onAccentFor(accent);
    final bg = _pressed
        ? accent.withValues(alpha: 0.82)
        : _hover
            ? accent.withValues(alpha: 0.93)
            : accent;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1.0,
          duration: waveMotion(context, WaveMotion.fast),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: waveMotion(context, WaveMotion.fast),
            padding:
                const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(999),
              boxShadow: [
                BoxShadow(
                  color: Colors.black
                      .withValues(alpha: dark ? 0.45 : 0.18),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(WaveIcons.play, size: 14, color: onAccent),
                const SizedBox(width: 8),
                Text(widget.label,
                    style: WaveType.label.copyWith(color: onAccent)),
              ],
            ),
          ),
        ),
      ),
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
    final onAccent = onAccentFor(accent);
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
          duration: waveMotion(context, WaveMotion.fast),
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
                        duration: waveMotion(context, const Duration(milliseconds: 180)),
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
    return WaveFilledButton(
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
    return WaveButton(
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
///
/// The tooltip machinery (`Tooltip > RawTooltip > MouseRegion > Semantics
/// > Focus` + global pointer listeners + timers) mounts one frame late:
/// on first build only the bare child is emitted, then a post-frame
/// callback arms the real tooltip. ~20 of these mount on pages like Now
/// Playing, and eager mounting showed up in open-frame traces. Deferral
/// is invisible by construction — no tooltip can display before the
/// 400ms hover dwell, while arming lands ~16ms after mount.
class LWTooltip extends StatefulWidget {
  final String message;
  final Widget child;
  const LWTooltip({
    super.key,
    required this.message,
    required this.child,
  });

  @override
  State<LWTooltip> createState() => _LWTooltipState();
}

class _LWTooltipState extends State<LWTooltip> {
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _armed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_armed) return widget.child;
    return Tooltip(
      message: widget.message,
      style: const TooltipThemeData(
        waitDuration: WaveState.tooltipDelay,
      ),
      child: widget.child,
    );
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

/// Canonical volume slider: 3px track, configurable width (defaults to 84px),
/// 8px knob at rest growing to 10px on hover/drag/focus.
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
    final active = _hover || _dragging || _focus.hasFocus;
    // A level you cannot see is not a control: at 100% the fill is the whole
    // track, so a knob that only appeared on hover left a plain hairline
    // between two glyphs. Any non-zero value keeps its knob; hover grows it.
    final thumbSize = active ? 10.0 : 8.0;
    final showThumb = active || widget.value > 0.001;
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
                  final maxThumbLeft = (width - thumbSize)
                      .clamp(0.0, double.infinity)
                      .toDouble();
                  final thumbLeft = (fillWidth - thumbSize / 2)
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
                            child: AnimatedContainer(
                              duration:
                                  waveMotion(context, WaveMotion.fast),
                              curve: Curves.easeOutCubic,
                              width: thumbSize,
                              height: thumbSize,
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

