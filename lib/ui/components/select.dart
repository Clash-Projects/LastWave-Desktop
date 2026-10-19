import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';
import 'menus.dart';

/// One choice in a [WaveSelect].
class WaveSelectOption<T> {
  final T value;
  final String label;

  /// Optional muted trailing note (e.g. "default").
  final String? hint;

  const WaveSelectOption({
    required this.value,
    required this.label,
    this.hint,
  });
}

/// Rounded replacement for fluent's `ComboBox`.
///
/// WHY: `ComboBox` bakes `kComboBoxRadius = Radius.circular(4)` into its
/// popup painter, its `Acrylic` shape *and* its open-animation clipper —
/// none of which read `FluentThemeData`, so there is no theme hook to
/// reach them. The popup therefore stayed near-square while every other
/// menu in the app sits on `WaveRadius.menu`.
///
/// This is the same control (filled, bordered trigger + selected label +
/// chevron) drawn with our tokens, over [WaveFlyoutPanel] — the app's own
/// opaque `menuRadius` popup surface with keyboard-navigable rows — so a
/// select matches the ladder everywhere, including its trigger corners.
///
/// Values must be unique (same contract as `ComboBox`).
class WaveSelect<T> extends StatefulWidget {
  final T? value;
  final List<WaveSelectOption<T>> options;

  /// `null` renders the control disabled, exactly like `ComboBox`.
  final ValueChanged<T>? onChanged;
  final String? placeholder;

  /// Stretch to the parent's width (fluent's `isExpanded`).
  final bool expanded;

  /// Narrowest the popup may get; the trigger's own width and the widest
  /// option both win over it, so the list stays anchored under the field
  /// and no label has to ellipsise.
  final double minMenuWidth;

  /// Cap on option-driven growth (a very long device name shouldn't span
  /// the window). The trigger's own width always wins over it.
  final double menuMaxWidth;

  const WaveSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.placeholder,
    this.expanded = false,
    this.minMenuWidth = 200,
    this.menuMaxWidth = 360,
  });

  @override
  State<WaveSelect<T>> createState() => _WaveSelectState<T>();
}

class _WaveSelectState<T> extends State<WaveSelect<T>> {
  final _controller = FlyoutController();
  bool _hover = false;
  bool _focused = false;
  bool _open = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? get _selectedLabel {
    for (final option in widget.options) {
      if (option.value == widget.value) return option.label;
    }
    return null;
  }

  /// Popup width: never narrower than the field it hangs from, never
  /// narrower than its widest row (measured, so no option label has to
  /// ellipsise like a cut-off value), capped by [WaveSelect.menuMaxWidth].
  double _menuWidth() {
    final trigger = context.size?.width ?? 0;
    var content = 0.0;
    // Row chrome: WaveMenuRow's 12/10 padding, a 16px leading + 10px gap,
    // and the panel's own inset of 4 on both sides.
    const chrome = 12 + 10 + 16 + 10 + 8;
    for (final option in widget.options) {
      content = math.max(content, _textWidth(option.label) + chrome);
      final hint = option.hint;
      if (hint != null) {
        content = math.max(content, _textWidth(hint, fontSize: 12) + chrome);
      }
    }
    final upper = math.max(widget.menuMaxWidth, trigger);
    return math.min(
      math.max(math.max(content, trigger), widget.minMenuWidth),
      upper,
    );
  }

  double _textWidth(String text, {double fontSize = 14}) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize, letterSpacing: -0.15),
      ),
      textDirection: Directionality.of(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  Future<void> _show() async {
    final onChanged = widget.onChanged;
    if (onChanged == null || _open) return;
    final width = _menuWidth();
    setState(() => _open = true);
    await _controller.showFlyout<void>(
      barrierColor: Colors.transparent,
      dismissWithEsc: true,
      // Auto placement with a bottomLeft preference (the plugin's own
      // DropDownButton contract): a field near the window edge opens
      // upward instead of having its last rows cut off.
      autoModeConfiguration: FlyoutAutoConfiguration(
        preferredMode: FlyoutPlacementMode.bottomLeft,
      ),
      additionalOffset: 4,
      transitionDuration: const Duration(milliseconds: 90),
      transitionBuilder: fastFlyoutTransition,
      builder: (context) => WaveFlyoutPanel.items(
        maxWidth: width,
        entries: [
          for (final option in widget.options)
            WaveMenuAction(
              leading: option.value == widget.value
                  ? const Icon(FluentIcons.check_mark, size: 13)
                  : const SizedBox(width: 13),
              label: option.label,
              hint: option.hint,
              onPressed: () => onChanged(option.value),
            ),
        ],
      ),
    );
    if (mounted) setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final enabled = widget.onChanged != null;
    final text = _selectedLabel ?? widget.placeholder ?? '';
    final states = <WidgetState>{
      if (!enabled) WidgetState.disabled,
      if (_hover && !_open) WidgetState.hovered,
      if (_open) WidgetState.pressed,
    };

    final label = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: WaveType.body.copyWith(
        color: enabled
            ? waveTextPrimary(context)
            : theme.resources.textFillColorDisabled,
      ),
    );

    return FocusableActionDetector(
      enabled: enabled,
      mouseCursor:
          enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onShowHoverHighlight: (value) => setState(() => _hover = value),
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.arrowDown): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _show();
            return null;
          },
        ),
      },
      child: FlyoutTarget(
        controller: _controller,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? _show : null,
          child: AnimatedContainer(
            duration: waveMotion(context, WaveMotion.fast),
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: ButtonThemeData.buttonColor(
                context,
                states,
                transparentWhenNone: false,
              ),
              borderRadius: WaveRadius.controlsRadius,
              border: Border.all(
                width: 1,
                color: _focused
                    ? waveAccent(context)
                    : states.isDisabled || states.isPressed
                        ? theme.resources.controlStrokeColorDefault
                        : theme.resources.controlStrokeColorSecondary,
              ),
            ),
            // The label ellipsises instead of overflowing whenever the
            // caller's width is bounded (the plugin ComboBox would grow
            // past its parent and read as "cut").
            child: LayoutBuilder(
              builder: (context, constraints) {
                final fill = widget.expanded && constraints.hasBoundedWidth;
                final maxLabel = constraints.hasBoundedWidth
                    ? math.max(0.0, constraints.maxWidth - 18)
                    : double.infinity;
                final title = ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxLabel),
                  child: label,
                );
                return Row(
                  mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
                  children: [
                    if (fill) Expanded(child: title) else title,
                    const SizedBox(width: 8),
                    Icon(
                      FluentIcons.chevron_down,
                      size: 10,
                      color: enabled
                          ? waveTextSecondary(context)
                          : theme.resources.textFillColorDisabled,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
