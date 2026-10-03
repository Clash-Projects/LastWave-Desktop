import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum AppShortcut {
  playPause,
  next,
  previous,
  like,
  fullscreen,
  download,
  queue,
  search,
  downloads,
  sleepTimer,
  playlists,
  lyrics,
  commandPalette,
  back,
}

class AppShortcuts {
  static SingleActivator _ctrl(LogicalKeyboardKey key, {bool shift = false}) {
    if (Platform.isMacOS) {
      return SingleActivator(key, meta: true, shift: shift);
    }
    return SingleActivator(key, control: true, shift: shift);
  }

  static final Map<AppShortcut, SingleActivator> bindings = {
    AppShortcut.playPause: const SingleActivator(LogicalKeyboardKey.space),
    AppShortcut.next: const SingleActivator(LogicalKeyboardKey.keyN),
    AppShortcut.previous: const SingleActivator(LogicalKeyboardKey.keyP),
    AppShortcut.like: const SingleActivator(LogicalKeyboardKey.keyL),
    AppShortcut.fullscreen: const SingleActivator(LogicalKeyboardKey.keyF),
    AppShortcut.download: const SingleActivator(LogicalKeyboardKey.keyD),
    AppShortcut.queue: const SingleActivator(LogicalKeyboardKey.keyQ),
    AppShortcut.search: const SingleActivator(LogicalKeyboardKey.slash),
    AppShortcut.downloads: _ctrl(LogicalKeyboardKey.keyD),
    AppShortcut.sleepTimer: _ctrl(LogicalKeyboardKey.keyS),
    AppShortcut.playlists: _ctrl(LogicalKeyboardKey.keyP),
    AppShortcut.lyrics: _ctrl(LogicalKeyboardKey.keyL),
    AppShortcut.commandPalette: _ctrl(LogicalKeyboardKey.keyP, shift: true),
    AppShortcut.back: const SingleActivator(LogicalKeyboardKey.escape),
  };

  static SingleActivator activator(AppShortcut action) => bindings[action]!;

  static String tooltip(String base, AppShortcut action) {
    return '$base · ${label(action)}';
  }

  static String label(AppShortcut action) {
    final act = bindings[action]!;
    final isMac = Platform.isMacOS;

    final parts = <String>[];
    if (isMac) {
      if (act.control) parts.add('⌃');
      if (act.alt) parts.add('⌥');
      if (act.shift) parts.add('⇧');
      if (act.meta) parts.add('⌘');
    } else {
      if (act.control) parts.add('Ctrl');
      if (act.alt) parts.add('Alt');
      if (act.shift) parts.add('Shift');
      if (act.meta) parts.add('Win');
    }

    String keyName;
    if (act.trigger == LogicalKeyboardKey.space) {
      keyName = 'Space';
    } else if (act.trigger == LogicalKeyboardKey.slash) {
      keyName = '/';
    } else if (act.trigger == LogicalKeyboardKey.escape) {
      keyName = 'Esc';
    } else {
      keyName = act.trigger.keyLabel.toUpperCase();
    }
    
    parts.add(keyName);

    if (isMac) {
      return parts.join('');
    } else {
      return parts.join('+');
    }
  }
}

class PlayPauseIntent extends Intent { const PlayPauseIntent(); }
class NextTrackIntent extends Intent { const NextTrackIntent(); }
class PreviousTrackIntent extends Intent { const PreviousTrackIntent(); }
class LikeTrackIntent extends Intent { const LikeTrackIntent(); }
class FullscreenIntent extends Intent { const FullscreenIntent(); }
class DownloadTrackIntent extends Intent { const DownloadTrackIntent(); }
class QueueIntent extends Intent { const QueueIntent(); }
class SearchIntent extends Intent { const SearchIntent(); }
class DownloadsIntent extends Intent { const DownloadsIntent(); }
class SleepTimerIntent extends Intent { const SleepTimerIntent(); }
class PlaylistsIntent extends Intent { const PlaylistsIntent(); }
class LyricsIntent extends Intent { const LyricsIntent(); }
class CommandPaletteIntent extends Intent { const CommandPaletteIntent(); }
