// ignore_for_file: camel_case_types
/// Retired shim — maps previous shadcn-style call sites onto the single
/// editorial component system (`components.dart`, Material-based).
///
/// New code must import `components.dart` directly. This file remains only
/// so any lingering imports keep compiling during migration; it introduces
/// no second UI kit and no Fluent dependency.
import 'package:flutter/material.dart';

import 'components.dart';
import 'tokens.dart';

export 'components.dart'
    show
        LwButton,
        LwIconButton,
        LwTooltip,
        LwTextField,
        LwSlider,
        LwSwitch,
        LwSelect,
        LwSeparator,
        LwToastHost,
        showToast,
        showLwDialog,
        showLwSheet,
        LwMenuItem,
        LwContextMenuRegion,
        LwFlyoutMenu,
        LwSkeleton,
        LwEmptyState,
        LwBadge,
        EdKicker,
        EdPage,
        EdSectionHeader,
        EdSegmented,
        EdLedgerHeader,
        EdDock;
export 'icons.dart';

enum ShadButtonSize { sm, regular, lg, icon }

// -- Theme ---------------------------------------------------------------

class _ShadColorScheme {
  final Color primary;
  const _ShadColorScheme(this.primary);
}

class _ShadThemeData {
  final _ShadColorScheme colorScheme;
  const _ShadThemeData(this.colorScheme);
}

class ShadTheme {
  static _ShadThemeData of(BuildContext context) {
    return _ShadThemeData(_ShadColorScheme(
        Theme.of(context).colorScheme.primary));
  }
}

// -- Buttons (delegate to Lw) ----------------------------------------------

class ShadButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final Widget? leading;
  final ShadButtonSize? size;
  final bool? enabled;
  final int _kind;
  const ShadButton({
    super.key,
    required this.child,
    this.onPressed,
    this.leading,
    this.size,
    this.enabled,
  }) : _kind = 0;
  const ShadButton.outline({
    super.key,
    required this.child,
    this.onPressed,
    this.leading,
    this.size,
    this.enabled,
  }) : _kind = 1;
  const ShadButton.ghost({
    super.key,
    required this.child,
    this.onPressed,
    this.leading,
    this.size,
    this.enabled,
  }) : _kind = 2;
  const ShadButton.secondary({
    super.key,
    required this.child,
    this.onPressed,
    this.leading,
    this.size,
    this.enabled,
  }) : _kind = 3;
  const ShadButton.destructive({
    super.key,
    required this.child,
    this.onPressed,
    this.leading,
    this.size,
    this.enabled,
  }) : _kind = 4;

  @override
  Widget build(BuildContext context) {
    final onTap = (enabled == false) ? null : onPressed;
    switch (_kind) {
      case 1:
        return LwButton.outline(
            onPressed: onTap, leading: leading, child: child);
      case 2:
        return LwButton.ghost(
            onPressed: onTap, leading: leading, child: child);
      case 3:
        return LwButton.outline(
            onPressed: onTap, leading: leading, child: child);
      case 4:
        return LwButton(
            onPressed: onTap,
            leading: leading,
            danger: true,
            child: child);
      default:
        return LwButton(
            onPressed: onTap, leading: leading, child: child);
    }
  }
}

class ShadIconButton extends StatelessWidget {
  final Widget icon;
  final VoidCallback? onPressed;
  final Color? backgroundColor;
  final Color? hoverBackgroundColor;
  const ShadIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.backgroundColor,
    this.hoverBackgroundColor,
  });
  const ShadIconButton.ghost({
    super.key,
    required this.icon,
    this.onPressed,
    this.backgroundColor,
    this.hoverBackgroundColor,
  });
  const ShadIconButton.outline({
    super.key,
    required this.icon,
    this.onPressed,
    this.backgroundColor,
    this.hoverBackgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    if (backgroundColor != null) {
      return Container(
        decoration: BoxDecoration(
          color: backgroundColor,
          shape: BoxShape.circle,
        ),
        child: LwIconButton(icon: icon, onPressed: onPressed),
      );
    }
    return LwIconButton(icon: icon, onPressed: onPressed);
  }
}

class ShadTooltip extends StatelessWidget {
  final Widget Function(BuildContext) builder;
  final Widget child;
  const ShadTooltip(
      {super.key, required this.builder, required this.child});
  @override
  Widget build(BuildContext context) {
    String message = '';
    try {
      final w = builder(context);
      if (w is Text) message = w.data ?? '';
    } catch (_) {}
    if (message.isEmpty) return child;
    return LwTooltip(message: message, child: child);
  }
}

// -- Inputs ------------------------------------------------------------------

class ShadInput extends StatelessWidget {
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final bool autofocus;
  final Widget? placeholder;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final int? maxLines;
  const ShadInput({
    super.key,
    this.controller,
    this.focusNode,
    this.autofocus = false,
    this.placeholder,
    this.onChanged,
    this.onSubmitted,
    this.maxLines,
  });
  @override
  Widget build(BuildContext context) {
    String? hint;
    if (placeholder is Text) hint = (placeholder as Text).data;
    if (maxLines != null && maxLines! > 1) {
      return TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        maxLines: maxLines,
        style: LwType.body.copyWith(
            color: Theme.of(context).colorScheme.onSurface),
        decoration: InputDecoration(hintText: hint, isDense: true),
      );
    }
    return LwTextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      hint: hint,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
    );
  }
}

class ShadSlider extends StatefulWidget {
  final double initialValue;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  const ShadSlider({
    super.key,
    required this.initialValue,
    this.min = 0,
    this.max = 1,
    required this.onChanged,
  });
  @override
  State<ShadSlider> createState() => _ShadSliderState();
}

class _ShadSliderState extends State<ShadSlider> {
  late double _v;
  @override
  void initState() {
    super.initState();
    _v = widget.initialValue;
  }

  @override
  Widget build(BuildContext context) {
    return LwSlider(
      value: _v,
      min: widget.min,
      max: widget.max,
      onChanged: (v) {
        setState(() => _v = v);
        widget.onChanged(v);
      },
    );
  }
}

class ShadSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final Widget? label;
  final Widget? sublabel;
  const ShadSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.sublabel,
  });
  @override
  Widget build(BuildContext context) {
    final sw = LwSwitch(value: value, onChanged: onChanged);
    if (label == null && sublabel == null) return sw;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding:
          const EdgeInsets.symmetric(vertical: LwSpacing.xxs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (label != null)
                  DefaultTextStyle(
                      style: LwType.title, child: label!),
                if (sublabel != null)
                  DefaultTextStyle(
                      style: LwType.caption.copyWith(
                          color: dark
                              ? LwColors.textSecondary
                              : LwColors
                                  .lightTextSecondary),
                      child: sublabel!),
              ],
            ),
          ),
          const SizedBox(width: LwSpacing.sm),
          sw,
        ],
      ),
    );
  }
}

class ShadOption<T> {
  final T value;
  final Widget child;
  const ShadOption({required this.value, required this.child});
}

class ShadSelect<T> extends StatelessWidget {
  final Widget? placeholder;
  final Widget Function(BuildContext, T)? selectedOptionBuilder;
  final ValueChanged<T?> onChanged;
  final List<ShadOption<T>> options;
  final T? initialValue;
  const ShadSelect({
    super.key,
    this.placeholder,
    this.selectedOptionBuilder,
    required this.onChanged,
    required this.options,
  }) : initialValue = null;
  @override
  Widget build(BuildContext context) {
    return DropdownButton<T>(
      value: null,
      hint: placeholder,
      onChanged: onChanged,
      items: [
        for (final o in options)
          DropdownMenuItem(
              value: o.value,
              child: DefaultTextStyle(
                  style: LwType.body, child: o.child)),
      ],
    );
  }
}

// -- Surfaces: flat editorial fallbacks (no nested boxes) ---------------------

class ShadCard extends StatelessWidget {
  final EdgeInsetsGeometry? padding;
  final Widget? title;
  final Widget? description;
  final Widget? footer;
  final Widget? trailing;
  final Widget child;
  const ShadCard({
    super.key,
    this.padding,
    this.title,
    this.description,
    this.footer,
    this.trailing,
    this.child = const SizedBox.shrink(),
  });
  @override
  Widget build(BuildContext context) {
    // Flat fallback: no smoked panel, single divider below.
    final hasHeader =
        title != null || description != null || trailing != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasHeader) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (title != null)
                      DefaultTextStyle(
                          style: LwType.headline, child: title!),
                    if (description != null) ...[
                      const SizedBox(height: 4),
                      DefaultTextStyle(
                          style: LwType.caption.copyWith(
                              color: Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? LwColors.textSecondary
                                  : LwColors
                                      .lightTextSecondary),
                          child: description!),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: LwSpacing.sm),
                trailing!,
              ],
            ],
          ),
          const SizedBox(height: LwSpacing.sm),
        ],
        child,
        if (footer != null) ...[
          const SizedBox(height: LwSpacing.sm),
          footer!,
        ],
        const SizedBox(height: LwSpacing.sm),
        const LwSeparator.horizontal(),
      ],
    );
  }
}

class ShadBadge extends StatelessWidget {
  final Color? backgroundColor;
  final Color? foregroundColor;
  final ShapeBorder? shape;
  final EdgeInsetsGeometry? padding;
  final Widget child;
  const ShadBadge({
    super.key,
    this.backgroundColor,
    this.foregroundColor,
    this.shape,
    this.padding,
    required this.child,
  });
  @override
  Widget build(BuildContext context) {
    return LwBadge(
        label: child is Text
            ? ((child as Text).data ?? '')
            : '');
  }
}

class ShadSeparator extends StatelessWidget {
  final bool _vertical;
  const ShadSeparator.horizontal({super.key}) : _vertical = false;
  const ShadSeparator.vertical({super.key}) : _vertical = true;
  @override
  Widget build(BuildContext context) {
    return _vertical
        ? const LwSeparator.vertical()
        : const LwSeparator.horizontal();
  }
}

class ShadAvatar extends StatelessWidget {
  final String imageUrl;
  final Widget? placeholder;
  final Size size;
  const ShadAvatar(
    this.imageUrl, {
    super.key,
    this.placeholder,
    this.size = const Size(40, 40),
  });
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final r = size.width / 2;
    if (imageUrl.isEmpty) {
      return CircleAvatar(
        radius: r,
        backgroundColor: dark
            ? LwColors.surfaceOverlay
            : LwColors.lightSurfaceOverlay,
        child: DefaultTextStyle(
          style: LwType.title,
          child: placeholder ?? const SizedBox.shrink(),
        ),
      );
    }
    return CircleAvatar(
      radius: r,
      backgroundColor: dark
          ? LwColors.surfaceOverlay
          : LwColors.lightSurfaceOverlay,
      backgroundImage: NetworkImage(imageUrl),
    );
  }
}

class ShadAlert extends StatelessWidget {
  final Widget? icon;
  final Widget? title;
  final Widget? description;
  final bool _destructive;
  const ShadAlert({
    super.key,
    this.icon,
    this.title,
    this.description,
  }) : _destructive = false;
  const ShadAlert.destructive({
    super.key,
    this.icon,
    this.title,
    this.description,
  }) : _destructive = true;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color =
        _destructive ? LwColors.danger : LwColors.hiRes;
    return Container(
      padding: const EdgeInsets.all(LwSpacing.sm),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(LwRadius.sm),
        border:
            Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            IconTheme(
                data: IconThemeData(color: color, size: 15),
                child: icon!),
            const SizedBox(width: LwSpacing.xs),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title != null)
                  DefaultTextStyle(
                      style: LwType.title
                          .copyWith(color: color),
                      child: title!),
                if (description != null)
                  DefaultTextStyle(
                      style: LwType.caption.copyWith(
                          color: dark
                              ? LwColors.textSecondary
                              : LwColors
                                  .lightTextSecondary),
                      child: description!),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// -- Tabs: underline editorial (replaces chip rows) ----------------------------

class ShadTab<T> {
  final T value;
  final Widget child;
  final Widget? content;
  const ShadTab({required this.value, required this.child, this.content});
}

class ShadTabsController<T> extends ChangeNotifier {
  T value;
  ShadTabsController({required T initialValue}) : value = initialValue;
  ShadTabsController.withValue(this.value);
  void select(T v) {
    if (v == value) return;
    value = v;
    notifyListeners();
  }

  @override
  void dispose() {
    super.dispose();
  }
}

class ShadTabs<T> extends StatelessWidget {
  final T? value;
  final ValueChanged<T>? onChanged;
  final List<ShadTab<T>> tabs;
  final ShadTabsController<T>? controller;
  const ShadTabs({
    super.key,
    this.value,
    this.onChanged,
    required this.tabs,
    this.controller,
  });
  String _labelOf(Widget w) {
    if (w is Text) return w.data ?? '';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final current =
        controller?.value ?? value ?? tabs.first.value;
    return EdSegmented<T>(
      value: current,
      options: [for (final t in tabs) (t.value, _labelOf(t.child))],
      onChanged: (v) {
        controller?.select(v);
        onChanged?.call(v);
      },
    );
  }
}

// -- Dialogs / sheets ----------------------------------------------------------

class ShadDialog extends StatelessWidget {
  final Widget? title;
  final Widget? description;
  final Widget? child;
  final List<Widget>? actions;
  final EdgeInsetsGeometry? padding;
  const ShadDialog({
    super.key,
    this.title,
    this.description,
    this.child,
    this.actions,
    this.padding,
  });
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null)
          DefaultTextStyle(
              style: LwType.headline, child: title!),
        if (description != null) ...[
          const SizedBox(height: 4),
          DefaultTextStyle(
              style: LwType.caption.copyWith(
                  color: Theme.of(context).brightness ==
                          Brightness.dark
                      ? LwColors.textSecondary
                      : LwColors.lightTextSecondary),
              child: description!),
        ],
        if (child != null) ...[
          const SizedBox(height: LwSpacing.sm),
          Flexible(child: child!),
        ],
        if (actions != null && actions!.isNotEmpty) ...[
          const SizedBox(height: LwSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              for (var i = 0; i < actions!.length; i++) ...[
                if (i > 0)
                  const SizedBox(width: LwSpacing.xs),
                actions![i],
              ],
            ],
          ),
        ],
      ],
    );
  }
}

Future<T?> showShadDialog<T>({
  required BuildContext context,
  required Widget Function(BuildContext) builder,
}) {
  return showLwDialog<T>(context: context, builder: builder);
}

enum ShadSheetSide { left, right, top, bottom }

class ShadSheet extends StatelessWidget {
  final Widget? title;
  final BoxConstraints? constraints;
  final Widget child;
  const ShadSheet({
    super.key,
    this.title,
    this.constraints,
    required this.child,
  });
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null)
          DefaultTextStyle(
              style: LwType.headline, child: title!),
        Flexible(child: child),
      ],
    );
  }
}

Future<void> showShadSheet({
  required BuildContext context,
  ShadSheetSide side = ShadSheetSide.right,
  required Widget Function(BuildContext) builder,
}) {
  return showLwSheet(context: context, child: Builder(builder: builder));
}

// -- Context menus ---------------------------------------------------------------

class ShadContextMenuController {
  void show() {}
  void dispose() {}
}

class ShadContextMenuItem {
  final Widget? leading;
  final VoidCallback? onPressed;
  final List<ShadContextMenuItem> items;
  final Widget child;
  const ShadContextMenuItem({
    this.leading,
    this.onPressed,
    this.items = const [],
    required this.child,
  });
}

class ShadContextMenuRegion extends StatelessWidget {
  final ShadContextMenuController? controller;
  final List<ShadContextMenuItem> items;
  final Widget child;
  const ShadContextMenuRegion({
    super.key,
    this.controller,
    required this.items,
    required this.child,
  });
  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return child;
    return LwContextMenuRegion(
      items: [
        for (final i in items)
          LwMenuItem(
            label: i.child is Text
                ? ((i.child as Text).data ?? 'Action')
                : 'Action',
            icon: Icons.chevron_right,
            onSelected: i.onPressed ?? () {},
          ),
      ],
      child: child,
    );
  }
}
