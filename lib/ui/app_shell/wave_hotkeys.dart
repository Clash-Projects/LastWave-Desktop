import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

/// App-wide keyboard shortcuts that work regardless of which widget has
/// focus (the "global in-app" layer).
///
/// Why this exists: `CallbackShortcuts` + `Focus(onKeyEvent)` only fire via
/// focus-bubbling, so any focused button/list that returns `handled` for
/// Space/Enter/arrows eats the key before the shell sees it (Space would
/// "click" the focused button instead of toggling playback). A
/// [HardwareKeyboard] handler runs *before* focus dispatch, so returning
/// `true` here swallows the key and the focused control never activates.
///
/// Policy:
/// - Space toggles playback globally, everywhere except text fields.
///   (Same as Spotify: Space never activates the focused button;
///   Enter is the keyboard activation for buttons.)
/// - Left/Right seek (5s, Shift 15s) globally whenever not typing.
/// - Up/Down change volume (5%, Shift 15%) globally, EXCEPT inside a
///   [WaveKeyNavScope] (track tables, menus), where they navigate the
///   list instead — again the Spotify convention: arrows are contextual,
///   Space is global.
/// - Typing (text fields) always wins for Space/arrows/Ctrl+L; only
///   Ctrl+K / Ctrl+F / Ctrl+Alt+P/N/B / Esc reach the shell while typing.
/// - Hardware media keys are NOT handled here (MPRIS owns them on
///   Linux, SMTC on Windows — see `isSystemMediaKey`). Returning false
///   (not swallowing) keeps that single-owner contract so a focused
///   press can never double-fire through both paths.
class WaveHotkeyActions {
  WaveHotkeyActions({
    required this.isTyping,
    required this.hasTrack,
    required this.togglePlay,
    required this.next,
    required this.previous,
    required this.openPalette,
    required this.focusSearch,
    required this.toggleLyrics,
    required this.goBack,
    required this.goForward,
    required this.handleEscape,
    required this.seekBySeconds,
    required this.volumeByDelta,
  });

  final bool Function() isTyping;
  final bool Function() hasTrack;
  final void Function() togglePlay;
  final void Function() next;
  final void Function() previous;
  final void Function() openPalette;
  final void Function() focusSearch;
  final void Function() toggleLyrics;
  final void Function() goBack;
  final void Function() goForward;

  /// Shell Esc chain (search-unfocus → close panels → collapse rail →
  /// pop /now). Returns true when something was closed.
  final bool Function() handleEscape;
  final void Function(int secondsDelta) seekBySeconds;
  final void Function(double delta) volumeByDelta;
}

/// Seek/volume steps shared by the global handler and the dock tooltips.
class WaveHotkeySteps {
  static const int seek = 5;
  static const int seekShift = 15;
  static const double volume = 0.05;
  static const double volumeShift = 0.15;
}

/// Returns true when keyboard focus is inside a text input. Centralized so
/// the global handler and any fallback widgets agree on "typing".
bool waveIsTypingFocused(FocusNode searchFocus) {
  if (searchFocus.hasFocus) return true;
  final focus = FocusManager.instance.primaryFocus;
  if (focus == null) return false;
  final ctx = focus.context;
  if (ctx == null) return false;
  if (ctx.widget is EditableText) return true;
  if (ctx.findAncestorWidgetOfExactType<EditableText>() != null) return true;
  if (ctx.findAncestorStateOfType<EditableTextState>() != null) return true;
  if (ctx.findAncestorWidgetOfExactType<TextBox>() != null) return true;
  final debugLabel = focus.debugLabel;
  if (debugLabel != null && debugLabel.contains('EditableText')) return true;
  return false;
}

bool _has(Set<LogicalKeyboardKey> keys, LogicalKeyboardKey a,
    LogicalKeyboardKey b) {
  return keys.contains(a) || keys.contains(b);
}

/// Marks a subtree with its own Up/Down keyboard navigation (track
/// tables, menus). The global [handleWaveHotkey] dispatcher yields
/// Up/Down when focus is inside the scope, so they move within the
/// list instead of changing volume. Everything else (Space, Left/Right,
/// Ctrl+combos, Esc) is unaffected.
///
/// Text fields don't need this scope — typing already yields all keys
/// except the Ctrl+combos and Esc.
class WaveKeyNavScope extends StatelessWidget {
  const WaveKeyNavScope({
    super.key,
    this.consumeUpDown = false,
    required this.child,
  });

  final bool consumeUpDown;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Nearest nav scope above the currently focused widget, if any.
WaveKeyNavScope? _navScope() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return null;
  return ctx.findAncestorWidgetOfExactType<WaveKeyNavScope>();
}

/// True for OS-level media/volume keys. SMTC (Windows) and MPRIS
/// (Linux) own these — the in-app dispatcher must never swallow them,
/// or a focused press would fire through both the OS path and this one.
bool isSystemMediaKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.mediaPlayPause ||
    k == LogicalKeyboardKey.mediaPlay ||
    k == LogicalKeyboardKey.mediaPause ||
    k == LogicalKeyboardKey.mediaStop ||
    k == LogicalKeyboardKey.mediaTrackNext ||
    k == LogicalKeyboardKey.mediaTrackPrevious ||
    k == LogicalKeyboardKey.audioVolumeMute ||
    k == LogicalKeyboardKey.audioVolumeUp ||
    k == LogicalKeyboardKey.audioVolumeDown;

/// Global key dispatcher. Attach via `HardwareKeyboard.instance.addHandler`
/// and detach on dispose. Returns true = swallowed (focused widget never
/// sees the key).
bool handleWaveHotkey(KeyEvent event, WaveHotkeyActions a) {
  final isDown = event is KeyDownEvent;
  final isRepeat = event is KeyRepeatEvent;
  if (!isDown && !isRepeat) return false;

  // System media keys belong to SMTC/MPRIS — never swallow, never act.
  if (isSystemMediaKey(event.logicalKey)) return false;

  final keys = HardwareKeyboard.instance.logicalKeysPressed;
  final ctrl = _has(keys, LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.controlRight);
  final alt =
      _has(keys, LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight);
  final meta = _has(keys, LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.metaRight);
  final shift = _has(keys, LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.shiftRight);
  final k = event.logicalKey;
  final typing = a.isTyping();

  // --- Ctrl+Alt transport: works even while typing (not a text key). ---
  if (ctrl && alt && !meta) {
    if (k == LogicalKeyboardKey.keyP) {
      if (isDown) a.togglePlay();
      return true;
    }
    if (k == LogicalKeyboardKey.keyN) {
      if (isDown) a.next();
      return true;
    }
    if (k == LogicalKeyboardKey.keyB) {
      if (isDown) a.previous();
      return true;
    }
  }

  // --- Palette + search focus: work while typing. Strict SingleActivator
  // parity (no Alt/Meta/Shift stragglers). ---
  if (ctrl && !alt && !meta && !shift && isDown) {
    if (k == LogicalKeyboardKey.keyK) {
      a.openPalette();
      return true;
    }
    if (k == LogicalKeyboardKey.keyF) {
      a.focusSearch();
      return true;
    }
  }

  // --- Esc: shell chain (unfocus search → close panels → rail → /now).
  // Runs while typing too. Returns false when nothing handled so other
  // Esc handlers (palette, suggestions) still work. ---
  if (k == LogicalKeyboardKey.escape && !ctrl && !alt && !meta && isDown) {
    return a.handleEscape();
  }

  // Everything below is disabled while typing so text entry is untouched.
  if (typing) return false;

  // --- Ctrl+L lyrics (needs a track). ---
  if (ctrl && !alt && !meta && !shift && isDown) {
    if (k == LogicalKeyboardKey.keyL) {
      if (a.hasTrack()) {
        a.toggleLyrics();
        return true;
      }
      return false;
    }
  }

  // --- Alt+Left/Right nav (strict: no Ctrl/Meta/Shift, like SingleActivator). ---
  if (alt && !ctrl && !meta && !shift && isDown) {
    if (k == LogicalKeyboardKey.arrowLeft) {
      a.goBack();
      return true;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      a.goForward();
      return true;
    }
  }

  // --- Space: toggles playback globally (swallows focused-button
  // activation). No modifiers; key-repeat ignored so holding space
  // doesn't strobe. ---
  if (k == LogicalKeyboardKey.space &&
      !ctrl &&
      !alt &&
      !meta &&
      isDown) {
    if (a.hasTrack()) {
      a.togglePlay();
      return true;
    }
    return false;
  }

  // --- Arrows: global seek / volume (repeat allowed for holding).
  // Left/Right are always global when not typing (tables and menus
  // don't use them). Up/Down yield to nav scopes (tables, menus)
  // where they move within the list instead of changing volume. ---
  if (!ctrl && !alt && !meta) {
    if (!a.hasTrack()) return false;
    final step = shift ? WaveHotkeySteps.seekShift : WaveHotkeySteps.seek;
    if (k == LogicalKeyboardKey.arrowRight) {
      a.seekBySeconds(step);
      return true;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      a.seekBySeconds(-step);
      return true;
    }
    if (_navScope()?.consumeUpDown == true) return false;
    final vStep =
        shift ? WaveHotkeySteps.volumeShift : WaveHotkeySteps.volume;
    if (k == LogicalKeyboardKey.arrowUp) {
      a.volumeByDelta(vStep);
      return true;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      a.volumeByDelta(-vStep);
      return true;
    }
  }

  return false;
}
