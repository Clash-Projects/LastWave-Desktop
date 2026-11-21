import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

/// Screen-reader plumbing shared by the whole app.
///
/// Flutter only builds its semantics tree while the engine reports an
/// assistive technology. On Windows that report is driven by UIA queries and
/// can drop while the window is in the background (minimized, tray-hidden,
/// or just deactivated by Alt+Tab), after which NVDA finds an empty tree on
/// return and the app reads as "completely unusable" until restart. Holding
/// a permanent [SemanticsHandle] keeps the tree built for the whole session,
/// so whatever the screen reader asks for after a return is already there.
///
/// The second half is focus: returning to the window must land keyboard
/// focus on a real control, otherwise NVDA announces only the window title
/// and Tab starts from nowhere. [AppFocusMemory] remembers the last focused
/// control and puts focus back on it (or the first focusable control on the
/// page when it is gone) every time the window is activated again.
class AppAccessibility {
  AppAccessibility._();

  static SemanticsHandle? _handle;

  /// Call once after `WidgetsFlutterBinding.ensureInitialized()`.
  static void enable() {
    _handle ??= SemanticsBinding.instance.ensureSemantics();
    AppFocusMemory.instance.start();
  }

  /// Speaks [message] through the active screen reader without moving focus.
  static void announce(BuildContext context, String message) {
    if (message.isEmpty) return;
    final view = View.maybeOf(context);
    if (view == null) return;
    SemanticsService.sendAnnouncement(view, message, TextDirection.ltr);
  }
}

/// Remembers the last focused control so window re-activation can restore it.
class AppFocusMemory {
  AppFocusMemory._();
  static final AppFocusMemory instance = AppFocusMemory._();

  bool _started = false;
  FocusNode? _last;
  bool _restoreQueued = false;

  void start() {
    if (_started) return;
    _started = true;
    FocusManager.instance.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    final node = FocusManager.instance.primaryFocus;
    if (_isControl(node)) _last = node;
  }

  /// A node a person can actually act on: attached, focusable, and not just a
  /// scope (scopes hold focus for their children, nothing to announce).
  static bool _isControl(FocusNode? node) =>
      node != null &&
      node is! FocusScopeNode &&
      node.context != null &&
      // Still in the focus tree: a node swapped out of a reused widget keeps
      // its old context but has no parent, and focusing it does nothing.
      node.parent != null &&
      node.canRequestFocus &&
      !node.skipTraversal;

  /// Puts keyboard focus back on a real control after the window returns.
  ///
  /// Focus is cleared and re-applied on the next frame even when the node
  /// still holds it: the screen reader only speaks on a focus *change*, so
  /// re-requesting an already-focused node would leave it silent.
  void restore() {
    if (_restoreQueued) return;
    _restoreQueued = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _restoreQueued = false;
      final target = _isControl(_last) ? _last! : null;
      if (target != null) {
        if (target.hasPrimaryFocus) {
          target.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (_isControl(target)) target.requestFocus();
          });
        } else {
          target.requestFocus();
        }
        return;
      }
      _focusFirstControl();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _focusFirstControl() {
    final current = FocusManager.instance.primaryFocus;
    if (_isControl(current)) return;
    // Innermost scope first (the open page or dialog), then wider ones, so
    // focus never jumps behind a dialog to the page under it.
    for (FocusNode? scope = current?.nearestScope ?? FocusManager.instance.rootScope;
        scope != null;
        scope = scope.parent?.nearestScope) {
      final context = scope.context;
      // The page's own traversal policy picks the first stop, so this is
      // exactly where a Tab press would have landed.
      final policy = context == null
          ? null
          : FocusTraversalGroup.maybeOf(context);
      final first = policy?.findFirstFocus(scope, ignoreCurrentFocus: true);
      if (_isControl(first)) {
        first!.requestFocus();
        return;
      }
      if (scope == FocusManager.instance.rootScope) return;
    }
  }
}
