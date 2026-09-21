import 'dart:io';

import 'package:flutter/services.dart';

/// Linux-only guard for the YouTube sign-in WebView window.
///
/// Backed by `lastwave/yt_webview`, registered in `linux/runner`
/// (`yt_webview_guard.cc`): finds the window by title, hides/shows it,
/// and converts its X button into a hide (upstream
/// `desktop_webview_window` 0.3.0 implements no visibility API on
/// Linux and segfaults on destroy, so the window must never die).
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
}
