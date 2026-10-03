import 'dart:io';

import 'package:flutter/services.dart';

/// Linux-only guard for WebView windows.
///
/// Backed by `lastwave/yt_webview`, registered in `linux/runner`
/// (`yt_webview_guard.cc`): finds windows by title, hides/shows them,
/// and converts their X buttons into hides (upstream
/// `desktop_webview_window` 0.3.0 implements no visibility API on
/// Linux and segfaults on destroy, so no WebView window must ever die).
class YtWebviewGuard {
  YtWebviewGuard._();

  static const _channel = MethodChannel('lastwave/yt_webview');

  static bool get isSupported => Platform.isLinux;

  /// Hide the sign-in window. False when unsupported or not found
  /// (e.g. never created) — callers fall back to the plugin call.
  static Future<bool> hide() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('hide') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Show (and present) the sign-in window. False when missing — the
  /// caller should create a fresh window instead of reusing the cache.
  static Future<bool> show() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('show') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Hide the BotGuard poToken window (`LastWave BotGuard`). False when
  /// unsupported or not found. Called right after create (the plugin
  /// hide call is a no-op on Linux) and instead of `close()` — the
  /// window is reused for app lifetime, never destroyed.
  static Future<bool> hideBotGuard() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('hideBotGuard') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Show the BotGuard window (diagnostics only — never used in
  /// normal playback).
  static Future<bool> showBotGuard() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('showBotGuard') ?? false;
    } catch (_) {
      return false;
    }
  }
}
