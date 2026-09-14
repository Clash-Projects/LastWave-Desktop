import 'dart:ui';

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Editorial component system — single primary kit (Material-based).
///
/// Primary system: Material + Lw editorial primitives below, deeply
/// customized via [ObservatoryTheme]. fluent_ui is NOT used for
/// composition (retained in pubspec only if already installed, but no
/// shell/screen imports it). Native window materials come from
/// flutter_acrylic/window_manager; icons from lucide; animation from
/// flutter_animate; artwork from cached_network_image; lists from
/// super_sliver_list/scrollable_positioned_list; progress from
/// audio_video_progress_bar.
///
/// Rules:
/// - Translucency selective: [EdDock] + dialogs/sheets only.
/// - Content surfaces are flat; hierarchy comes from type/spacing/artwork.
/// - No boxed cards around every section. No nested backgrounds.
/// - Hover/press ≤120ms. Keyboard focus always visible.
Color lwAccent(BuildContext context) =>
    Theme.of(context).colorScheme.primary;

bool _isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

// -- Buttons ---------------------------------------------------------------

class LwButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final Widget? leading;
  final Widget? trailing;
  final bool primary;
  final bool danger;
  const LwButton({
    super.key,
    required this.child,
    this.onPressed,
    this.leading,
    this.trailing,
    this.primary = true,
    this.danger = false,
  });

  factory LwButton.outline({
    Key? key,
    required Widget child,
    VoidCallback? onPressed,
    Widget? leading,
    Widget? trailing,
  }) =>
      LwButton(
        key: key,
        onPressed: onPressed,
        leading: leading,
        trailing: trailing,
        primary: false,
        child: child,
      );

  static Widget ghost({
    Key? key,
    required Widget child,
    VoidCallback? onPressed,
    Widget? leading,
  }) =>
      _GhostButton(
          key: key,
          onPressed: onPressed,
          leading: leading,
          child: child);

  @override
  Widget build(BuildContext context) {
    final accent = lwAccent(context);
    final dark = _isDark(context);
    if (!primary) {
      return OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: dark
              ? LwColors.textPrimary
              : LwColors.lightTextPrimary,
          side: BorderSide(
              color: dark
                  ? LwColors.outline
                  : LwColors.lightOutline),
          shape: RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(LwRadius.sm)),
          padding: const EdgeInsets.symmetric(
              horizontal: LwSpacing.md, vertical: 9),
          textStyle: LwType.label,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: LwSpacing.xs)
            ],
            Flexible(child: child),
            if (trailing != null) ...[
              const SizedBox(width: LwSpacing.xs),
              trailing!
            ],
          ],
        ),
      );
    }
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor:
            danger ? LwColors.danger : accent,
        foregroundColor: danger
            ? Colors.white
            : (dark ? Colors.black : Colors.white),
        shape: RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(LwRadius.sm)),
        padding: const EdgeInsets.symmetric(
            horizontal: LwSpacing.md, vertical: 9),
        textStyle:
            LwType.label.copyWith(fontWeight: FontWeight.w700),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: LwSpacing.xs)
          ],
          Flexible(child: child),
        ],
      ),
    );
  }
}

class _GhostButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final Widget? leading;
  const _GhostButton(
      {super.key, required this.child, this.onPressed, this.leading});
  @override
  Widget build(BuildContext context) {
    final accent = lwAccent(context);
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context)
            .colorScheme
            .onSurface
            .withValues(alpha: 0.9),
        overlayColor: accent.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(LwRadius.sm)),
        padding: const EdgeInsets.symmetric(
            horizontal: LwSpacing.sm, vertical: 7),
        textStyle: LwType.label,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 6)
          ],
          Flexible(child: child),
        ],
      ),
    );
  }
}

/// Ghost icon button with tooltip + focus ring + 120ms hover.
class LwIconButton extends StatelessWidget {
  final Widget icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool selected;
  const LwIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = lwAccent(context);
    final dark = _isDark(context);
    final btn = IconButton(
      onPressed: onPressed,
      icon: icon,
      color: selected
          ? accent
          : (dark
              ? LwColors.textSecondary
              : LwColors.lightTextSecondary),
      hoverColor: selected
          ? accent.withValues(alpha: 0.14)
          : (dark
              ? Colors.white.withValues(alpha: 0.07)
              : Colors.black.withValues(alpha: 0.06)),
      focusColor: accent.withValues(alpha: 0.2),
      style: IconButton.styleFrom(
        shape: RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(LwRadius.sm)),
        padding: const EdgeInsets.all(8),
        minimumSize: const Size(32, 32),
      ),
    );
    if (tooltip == null) return btn;
    return LwTooltip(message: tooltip!, child: btn);
  }
}

// -- Tooltip -----------------------------------------------------------------

class LwTooltip extends StatelessWidget {
  final String message;
  final Widget child;
  const LwTooltip(
      {super.key, required this.message, required this.child});
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      waitDuration: const Duration(milliseconds: 400),
      preferBelow: true,
      child: child,
    );
  }
}

// -- Inputs ------------------------------------------------------------------

class LwTextField extends StatelessWidget {
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final Widget? prefix;
  const LwTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.hint,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.prefix,
  });
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: LwType.body.copyWith(
          color: Theme.of(context).colorScheme.onSurface),
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: prefix,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: LwSpacing.sm, vertical: 10),
      ),
    );
  }
}

class LwSlider extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  const LwSlider({
    super.key,
    required this.value,
    this.min = 0,
    this.max = 1,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 4,
        thumbShape:
            const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape:
            const RoundSliderOverlayShape(overlayRadius: 12),
      ),
      child: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: onChanged,
      ),
    );
  }
}

class LwSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const LwSwitch(
      {super.key, required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return Switch(value: value, onChanged: onChanged);
  }
}

class LwSelect<T> extends StatelessWidget {
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T?> onChanged;
  const LwSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      onChanged: onChanged,
      items: [
        for (final o in options)
          DropdownMenuItem(value: o.$1, child: Text(o.$2)),
      ],
    );
  }
}

// -- Editorial primitives ----------------------------------------------------
/// Flat separator.
class LwSeparator extends StatelessWidget {
  final bool vertical;
  const LwSeparator.horizontal({super.key}) : vertical = false;
  const LwSeparator.vertical({super.key}) : vertical = true;
  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    final color =
        dark ? LwColors.outlineSoft : LwColors.lightOutlineSoft;
    if (vertical) return Container(width: 1, color: color);
    return Container(height: 1, color: color);
  }
}

/// Uppercase kicker labelling hierarchy (sections, ledger headers).
class EdKicker extends StatelessWidget {
  final String text;
  const EdKicker(this.text, {super.key});
  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    return Text(
      text.toUpperCase(),
      style: LwType.micro.copyWith(
        color: dark
            ? LwColors.textTertiary
            : LwColors.lightTextTertiary,
      ),
    );
  }
}

/// Page container: centers content to [LwDensity.contentMax], flat
/// background, editorial rhythm. Replaces boxed dashboard padding.
class EdPage extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  const EdPage({
    super.key,
    required this.child,
    this.maxWidth = LwDensity.contentMax,
  });
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// Editorial section header: kicker + title + lede + text action link.
/// Structurally distinct from old boxed SectionHeader: no container,
/// left-aligned ledger, action is a text link not a row of buttons.
class EdSectionHeader extends StatelessWidget {
  final String? kicker;
  final String title;
  final String? lede;
  final String? actionLabel;
  final VoidCallback? onAction;
  const EdSectionHeader({
    super.key,
    this.kicker,
    required this.title,
    this.lede,
    this.actionLabel,
    this.onAction,
  });
  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (kicker != null) ...[
                EdKicker(kicker!),
                const SizedBox(height: 4),
              ],
              Text(title,
                  style: LwType.headline.copyWith(fontSize: 17)),
              if (lede != null) ...[
                const SizedBox(height: 2),
                Text(lede!,
                    style: LwType.caption.copyWith(
                        color: dark
                            ? LwColors.textSecondary
                            : LwColors.lightTextSecondary)),
              ],
            ],
          ),
        ),
        if (actionLabel != null)
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              foregroundColor: lwAccent(context),
              textStyle: LwType.label,
              padding: const EdgeInsets.symmetric(
                  horizontal: LwSpacing.sm, vertical: 6),
            ),
            child: Text(actionLabel!),
          ),
      ],
    );
  }
}

/// Underline segmented control (Lyrics | Up next, periods, mix sizes).
/// Replaces chip-row tabs: single line, selected underline, no boxes.
class EdSegmented<T> extends StatelessWidget {
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;
  const EdSegmented({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    final accent = lwAccent(context);
    final dark = _isDark(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: LwSpacing.md),
          GestureDetector(
            onTap: () => onChanged(options[i].$1),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  options[i].$2,
                  style: LwType.label.copyWith(
                    color: options[i].$1 == value
                        ? (dark
                            ? LwColors.textPrimary
                            : LwColors.lightTextPrimary)
                        : (dark
                            ? LwColors.textTertiary
                            : LwColors.lightTextTertiary),
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  height: 2,
                  width: 28,
                  decoration: BoxDecoration(
                    color: options[i].$1 == value
                        ? accent
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Column header for ledger track lists: aligned # / Title / Meta / ⋯.
/// Gives collections a newspaper ledger feel vs old borderless rows.
class EdLedgerHeader extends StatelessWidget {
  final String metaLabel;
  final bool showIndex;
  const EdLedgerHeader({
    super.key,
    this.metaLabel = '',
    this.showIndex = true,
  });
  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    final style = LwType.micro.copyWith(
      color: dark
          ? LwColors.textTertiary
          : LwColors.lightTextTertiary,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: LwSpacing.sm, vertical: LwSpacing.xs),
      child: Row(
        children: [
          if (showIndex)
            SizedBox(width: 28, child: Text('#', style: style)),
          const SizedBox(width: 48),
          Expanded(child: Text('Title'.toUpperCase(), style: style)),
          if (metaLabel.isNotEmpty)
            SizedBox(
              width: 88,
              child: Text(metaLabel.toUpperCase(),
                  style: style, textAlign: TextAlign.right),
            ),
          const SizedBox(width: 64),
        ],
      ),
    );
  }
}

/// Floating inset dock: the ONLY blurred full-time surface besides
/// dialogs. Inset 12px, 14px radius, single top luminous edge.
class EdDock extends StatelessWidget {
  final Widget child;
  const EdDock({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    final reduceT = !LwMotionScope.transparencyOK(context);
    final bg = dark
        ? (reduceT ? LwColors.surface : LwColors.dockTranslucent)
        : (reduceT
            ? LwColors.lightSurface
            : LwColors.lightDockTranslucent);
    final border =
        dark ? LwColors.outlineSoft : LwColors.lightOutline;
    final inner = Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                  color: dark
                      ? LwColors.luminousEdge
                      : Colors.white),
            ),
          ),
          child: child,
        ),
      ),
    );
    if (reduceT) return inner;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(
            sigmaX: LwBlur.dock, sigmaY: LwBlur.dock),
        child: inner,
      ),
    );
  }
}

// -- Toasts ------------------------------------------------------------------

class LwToastHost extends StatefulWidget {
  final Widget child;
  const LwToastHost({super.key, required this.child});
  static LwToastHostState of(BuildContext context) {
    final s = context.findAncestorStateOfType<LwToastHostState>();
    assert(s != null, 'LwToastHost not found in tree');
    return s!;
  }

  @override
  State<LwToastHost> createState() => LwToastHostState();
}

class _ToastEntry {
  final String title;
  final String? description;
  _ToastEntry(this.title, this.description);
}

class LwToastHostState extends State<LwToastHost>
    with SingleTickerProviderStateMixin {
  final List<_ToastEntry> _items = [];

  void show(String title, {String? description}) {
    setState(() {
      _items.add(_ToastEntry(title, description));
      if (_items.length > 3) _items.removeAt(0);
    });
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() {
        if (_items.isNotEmpty) _items.removeAt(0);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    return Stack(
      children: [
        widget.child,
        Positioned(
          right: LwSpacing.md,
          bottom: LwSpacing.md,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final t in _items)
                Container(
                  constraints: const BoxConstraints(
                      maxWidth: 340, minWidth: 220),
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.symmetric(
                      horizontal: LwSpacing.md,
                      vertical: LwSpacing.sm),
                  decoration: BoxDecoration(
                    color: dark
                        ? LwColors.surfaceRaised
                        : LwColors.lightSurface,
                    borderRadius:
                        BorderRadius.circular(LwRadius.md),
                    border: Border.all(
                        color: dark
                            ? LwColors.outline
                            : LwColors.lightOutline),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                            alpha: dark ? 0.5 : 0.12),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(t.title, style: LwType.title),
                      if (t.description != null)
                        Padding(
                          padding:
                              const EdgeInsets.only(top: 2),
                          child: Text(t.description ?? '',
                              style:
                                  LwType.caption.copyWith(
                                      color: dark
                                          ? LwColors
                                              .textSecondary
                                          : LwColors
                                              .lightTextSecondary)),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

void showToast(BuildContext context, String title,
    {String? description}) {
  LwToastHost.of(context).show(title, description: description);
}

// -- Dialogs / sheets --------------------------------------------------------

Future<T?> showLwDialog<T>({
  required BuildContext context,
  required Widget Function(BuildContext) builder,
  String? title,
}) {
  return showDialog<T>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: LwDialogShell(
        title: title,
        child: Builder(builder: builder),
      ),
    ),
  );
}

class LwDialogShell extends StatelessWidget {
  final String? title;
  final Widget child;
  const LwDialogShell({super.key, this.title, required this.child});
  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    return ConstrainedBox(
      constraints:
          const BoxConstraints(maxWidth: 560, minWidth: 320),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(LwRadius.lg),
        child: BackdropFilter(
          filter: ImageFilter.blur(
              sigmaX: LwBlur.dialog, sigmaY: LwBlur.dialog),
          child: Container(
            padding: const EdgeInsets.all(LwSpacing.lg),
            decoration: BoxDecoration(
              color: dark
                  ? LwColors.surfaceRaised.withValues(alpha: 0.96)
                  : LwColors.lightSurface
                      .withValues(alpha: 0.98),
              borderRadius:
                  BorderRadius.circular(LwRadius.lg),
              border: Border.all(
                  color: dark
                      ? LwColors.outline
                      : LwColors.lightOutline),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null) ...[
                  Text(title!, style: LwType.headline),
                  const SizedBox(height: LwSpacing.sm),
                ],
                Flexible(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showLwSheet({
  required BuildContext context,
  required Widget child,
  String? title,
  double maxWidth = 420,
}) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    pageBuilder: (context, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        height: double.infinity,
        margin: const EdgeInsets.all(LwSpacing.sm),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(LwRadius.lg),
          child: Material(
            color: _isDark(context)
                ? LwColors.surface
                : LwColors.lightSurface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title case final String sheetTitle)
                  Padding(
                    padding: const EdgeInsets.all(LwSpacing.md),
                    child: Text(sheetTitle,
                        style: LwType.headline),
                  ),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

// -- Context menus (Material-backed, single system) ---------------------------

class LwMenuItem {
  final String label;
  final IconData icon;
  final bool destructive;
  final VoidCallback onSelected;
  const LwMenuItem({
    required this.label,
    required this.icon,
    this.destructive = false,
    required this.onSelected,
  });
}

class LwContextMenuRegion extends StatelessWidget {
  final List<LwMenuItem> items;
  final Widget child;
  const LwContextMenuRegion(
      {super.key, required this.items, required this.child});
  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return child;
    return GestureDetector(
      onSecondaryTapDown: (d) =>
          _show(context, d.globalPosition),
      onLongPressStart: (d) =>
          _show(context, d.globalPosition),
      child: child,
    );
  }

  void _show(BuildContext context, Offset at) {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final dark = _isDark(context);
    showMenu(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(at, at),
        Offset.zero & overlay.size,
      ),
      color:
          dark ? LwColors.surfaceRaised : LwColors.lightSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LwRadius.md),
        side: BorderSide(
            color: dark
                ? LwColors.outline
                : LwColors.lightOutline),
      ),
      items: [
        for (final item in items)
          PopupMenuItem(
            onTap: item.onSelected,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(item.icon,
                    size: 14,
                    color: item.destructive
                        ? LwColors.danger
                        : (dark
                            ? LwColors.textSecondary
                            : LwColors.lightTextSecondary)),
                const SizedBox(width: LwSpacing.sm),
                Text(item.label, style: LwType.body),
              ],
            ),
          ),
      ],
    );
  }
}

/// Material menu button (replaces Fluent Flyout). Single system.
class LwFlyoutMenu extends StatelessWidget {
  final List<LwMenuItem> items;
  final Widget icon;
  final String? tooltip;
  const LwFlyoutMenu({
    super.key,
    required this.items,
    required this.icon,
    this.tooltip,
  });
  @override
  Widget build(BuildContext context) {
    Future<void> open(Offset at) async {
      final overlay =
          Overlay.of(context).context.findRenderObject()
              as RenderBox;
      final dark = _isDark(context);
      final choice = await showMenu<int>(
        context: context,
        position: RelativeRect.fromRect(
          Rect.fromPoints(at, at),
          Offset.zero & overlay.size,
        ),
        color:
            dark ? LwColors.surfaceRaised : LwColors.lightSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LwRadius.md),
          side: BorderSide(
              color: dark
                  ? LwColors.outline
                  : LwColors.lightOutline),
        ),
        items: [
          for (var i = 0; i < items.length; i++)
            PopupMenuItem(
              value: i,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(items[i].icon,
                      size: 14,
                      color: items[i].destructive
                          ? LwColors.danger
                          : (dark
                              ? LwColors.textSecondary
                              : LwColors
                                  .lightTextSecondary)),
                  const SizedBox(width: LwSpacing.sm),
                  Text(items[i].label,
                      style: LwType.body),
                ],
              ),
            ),
        ],
      );
      if (choice != null) items[choice].onSelected();
    }

    final btn = Builder(
      builder: (context) => LwIconButton(
        icon: icon,
        tooltip: tooltip,
        onPressed: () {
          final box =
              context.findRenderObject() as RenderBox?;
          final at = box == null
              ? Offset.zero
              : box.localToGlobal(
                  Offset(0, box.size.height));
          open(at);
        },
      ),
    );
    return btn;
  }
}

// -- Skeletons / empty states / badges ---------------------------------------

class LwSkeleton extends StatefulWidget {
  final double width;
  final double height;
  final double radius;
  const LwSkeleton({
    super.key,
    required this.width,
    required this.height,
    this.radius = LwRadius.sm,
  });
  @override
  State<LwSkeleton> createState() => _LwSkeletonState();
}

class _LwSkeletonState extends State<LwSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    if (!LwMotionScope.motionOK(context)) {
      return Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: dark
              ? LwColors.surfaceOverlay
              : LwColors.lightSurfaceOverlay,
          borderRadius:
              BorderRadius.circular(widget.radius),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius:
              BorderRadius.circular(widget.radius),
          gradient: LinearGradient(
            begin: Alignment(-1 - _c.value, 0),
            end: Alignment(1 - _c.value, 0),
            colors: dark
                ? const [
                    LwColors.surfaceOverlay,
                    LwColors.surfaceRaised,
                    LwColors.surfaceOverlay,
                  ]
                : const [
                    LwColors.lightSurfaceOverlay,
                    LwColors.lightSurface,
                    LwColors.lightSurfaceOverlay,
                  ],
          ),
        ),
      ),
    );
  }
}

class LwEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  const LwEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });
  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(LwSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dark
                    ? LwColors.surfaceOverlay
                    : LwColors.lightSurfaceOverlay,
                border: Border.all(
                    color: dark
                        ? LwColors.outlineSoft
                        : LwColors.lightOutline),
              ),
              child: Icon(icon,
                  size: 22,
                  color: dark
                      ? LwColors.textTertiary
                      : LwColors.lightTextTertiary),
            ),
            const SizedBox(height: LwSpacing.md),
            Text(title, style: LwType.headline),
            const SizedBox(height: LwSpacing.xxs),
            Text(
              subtitle,
              style: LwType.caption.copyWith(
                  color: dark
                      ? LwColors.textSecondary
                      : LwColors.lightTextSecondary),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: LwSpacing.md),
              LwButton.outline(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class LwBadge extends StatelessWidget {
  final String label;
  const LwBadge({super.key, required this.label});
  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: dark
            ? Colors.white.withValues(alpha: 0.07)
            : Colors.black.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(LwRadius.pill),
        border: Border.all(
            color: dark
                ? LwColors.outlineSoft
                : LwColors.lightOutline),
      ),
      child: Text(
        label,
        style: LwType.micro.copyWith(
            fontSize: 9.5,
            color: dark
                ? LwColors.textSecondary
                : LwColors.lightTextSecondary),
      ),
    );
  }
}

// -- Retired observatory boxes ------------------------------------------------
///
/// Removed: LwPanelShell, LwDock (full-width), LwTabs (chip rows),
/// LwSectionHeader (boxed dashboard header). Screens now use [EdPage],
/// [EdSectionHeader], [EdSegmented], [EdDock], [EdLedgerHeader].
/// These aliases exist only to surface migration errors clearly.
