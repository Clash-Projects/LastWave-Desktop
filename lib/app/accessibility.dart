import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

bool _isActiveContext(BuildContext? context) {
  if (context == null || !context.mounted) return false;
  var active = true;
  assert(() {
    // Inherited lookups (e.g. FocusTraversalGroup.maybeOf / Directionality)
    // assert Element._lifecycleState == _ElementLifecycle.active, which can be
    // false for inactive elements in _inactiveElements even when mounted is true.
    active = context is! Element || context.debugIsActive;
    return true;
  }());
  return active;
}

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
    if (message.isEmpty || !_isActiveContext(context)) return;
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
      _isActiveContext(node.context) &&
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

  static bool _hasOnlyActiveTraversalMembers(FocusScopeNode scope) {
    for (final child in scope.children) {
      if (!_nodeSubtreeContextsActive(child)) return false;
    }
    return true;
  }

  static bool _nodeSubtreeContextsActive(FocusNode node) {
    if (node.canRequestFocus &&
        !node.skipTraversal &&
        !_isActiveContext(node.context)) {
      return false;
    }
    if (node is FocusScopeNode) return true;
    for (final child in node.children) {
      if (!_nodeSubtreeContextsActive(child)) return false;
    }
    return true;
  }

  static FocusNode? _firstActiveControlInScope(FocusScopeNode scope) {
    FocusNode? walk(FocusNode node) {
      for (final child in node.children) {
        if (_isControl(child)) return child;
        if (child is! FocusScopeNode) {
          final found = walk(child);
          if (found != null) return found;
        }
      }
      return null;
    }

    return walk(scope);
  }

  static FocusScopeNode? _activeChildScope(FocusScopeNode scope) =>
      scope.children
          .whereType<FocusScopeNode>()
          .where((n) => _isActiveContext(n.context))
          .lastOrNull;

  static FocusScopeNode? _deepestActiveScope(FocusScopeNode start) {
    var scope = start;
    for (var i = 0; i < 16; i++) {
      final focused = scope.focusedChild;
      if (focused is FocusScopeNode &&
          focused != scope &&
          _isActiveContext(focused.context)) {
        scope = focused;
        continue;
      }
      // Wrapper scopes (e.g. WidgetsApp) hold child route/page FocusScopes
      // without any direct controls of their own.
      final childScope = _activeChildScope(scope);
      if (childScope != null && _firstActiveControlInScope(scope) == null) {
        scope = childScope;
        continue;
      }
      break;
    }
    return _isActiveContext(scope.context) ? scope : null;
  }

  FocusNode? _findPolicyFirstControl(FocusScopeNode scope) {
    final context = scope.context;
    if (!_isActiveContext(context)) return null;
    // The page's own traversal policy picks the first stop, so this is
    // exactly where a Tab press would have landed. Prefer maybeOfNode to avoid
    // ancestor lookups on context, and verify member contexts remain active
    // because ReadingOrderTraversalPolicy calls Directionality.maybeOf.
    final policy = FocusTraversalGroup.maybeOfNode(scope) ??
        FocusTraversalGroup.maybeOf(context!);
    return (policy != null && _hasOnlyActiveTraversalMembers(scope))
        ? policy.findFirstFocus(scope, ignoreCurrentFocus: true)
        : _firstActiveControlInScope(scope);
  }

  FocusNode? _pickFirstControl(FocusScopeNode scope) {
    final first = _findPolicyFirstControl(scope);
    if (_isControl(first)) return first;
    if (first is FocusScopeNode &&
        first != scope &&
        _isActiveContext(first.context)) {
      final nested = _deepestActiveScope(first);
      if (nested != null && nested != scope) {
        final nestedFirst = _findPolicyFirstControl(nested);
        if (_isControl(nestedFirst)) return nestedFirst;
      }
    }
    return _firstActiveControlInScope(scope);
  }

  void _focusFirstControl() {
    final current = FocusManager.instance.primaryFocus;
    if (_isControl(current)) return;
    final rootScope = FocusManager.instance.rootScope;
    // Innermost active scope first (the open page or dialog), then wider ones,
    // so focus never jumps behind a dialog to the page under it or reads a
    // deactivated FocusScope's ancestor.
    final FocusScopeNode? startScope =
        (current != null &&
                current.parent != null &&
                _isActiveContext(current.context))
            ? current.nearestScope
            : _deepestActiveScope(rootScope);

    for (FocusScopeNode? scope = startScope ?? rootScope;
        scope != null;
        scope = scope.parent?.nearestScope) {
      final first = _pickFirstControl(scope);
      if (_isControl(first)) {
        first!.requestFocus();
        return;
      }
      if (scope == rootScope) return;
    }
  }
}
