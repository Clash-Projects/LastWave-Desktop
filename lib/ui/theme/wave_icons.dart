import 'package:fluent_ui/fluent_ui.dart';

/// Canonical LastWave icon set.
///
/// All presentation code must use [WaveIcons] instead of importing
/// `lucide_icons_flutter`, Material or Cupertino icons directly.
///
/// Two Microsoft glyph fonts ship with fluent_ui and both are used here:
/// - [WindowsIcons] (Segoe Fluent Icons, the Windows 11 set) for
///   navigation and content. It has the real shuffle glyph, a right-handed
///   magnifier, a vinyl-in-square album and a list-with-note playlist.
///   These are the shapes people know from Windows 11 and Apple Music.
/// - [FluentIcons] (the older Fabric MDL2 set) for transport
///   (previous/next/play/pause/repeat), window chrome and the remaining
///   utility glyphs, whose shapes already read correctly.
/// Both fonts are drawn on the same 16px grid with a ~1px stroke, so they
/// sit together without a weight jump.
///
/// The Now Playing visualizer toggle uses sound bars rather than music
/// notes, so it can't be confused with the lyrics toggle next to it.
class WaveIcons {
  WaveIcons._();

  // Navigation
  static const IconData home = WindowsIcons.home;
  static const IconData discover = WindowsIcons.globe;
  static const IconData stats = FluentIcons.bar_chart_vertical;
  static const IconData search = WindowsIcons.search;
  static const IconData library = WindowsIcons.library;
  static const IconData liked = WindowsIcons.heart;
  static const IconData likedFill = WindowsIcons.heart_fill;
  static const IconData albums = WindowsIcons.music_album;
  static const IconData artists = WindowsIcons.microphone;
  static const IconData playlists = WindowsIcons.music_info;
  static const IconData downloads = WindowsIcons.download;
  static const IconData friends = WindowsIcons.people;
  static const IconData settings = WindowsIcons.settings;
  static const IconData history = WindowsIcons.history;
  static const IconData mixes = WindowsIcons.audio;
  static const IconData podcasts = FluentIcons.headset;
  static const IconData genres = WindowsIcons.tag;

  // Transport
  static const IconData play = FluentIcons.play_solid;
  static const IconData pause = FluentIcons.pause;
  static const IconData previous = FluentIcons.previous;
  static const IconData next = FluentIcons.next;
  static const IconData shuffle = WindowsIcons.shuffle;
  static const IconData repeat = FluentIcons.repeat_all;
  static const IconData repeatOne = FluentIcons.repeat_one;

  // Content
  static const IconData music = FluentIcons.music_note;
  static const IconData musicCollection = WindowsIcons.audio;
  static const IconData lyrics = FluentIcons.music_note;
  static const IconData queue = WindowsIcons.bulleted_list;
  static const IconData radio = FluentIcons.radio_btn_on;
  static const IconData speaker = FluentIcons.speakers;
  static const IconData canvas = FluentIcons.video;
  static const IconData volume = FluentIcons.volume2;
  static const IconData volumeMute = FluentIcons.volume_disabled;

  // Actions
  static const IconData more = FluentIcons.more;
  static const IconData add = FluentIcons.add;
  static const IconData addTo = FluentIcons.add_to;
  static const IconData playNext = FluentIcons.add;
  static const IconData downloadAction = WindowsIcons.download;
  static const IconData pin = FluentIcons.pin;
  static const IconData edit = FluentIcons.edit;
  static const IconData delete = FluentIcons.delete;
  static const IconData close = FluentIcons.chrome_close;
  static const IconData minimize = FluentIcons.chrome_minimize;
  static const IconData maximize = FluentIcons.checkbox;
  static const IconData back = FluentIcons.chevron_left;
  static const IconData forward = FluentIcons.chevron_right;
  static const IconData chevronRight = FluentIcons.chevron_right;
  static const IconData command = FluentIcons.command_prompt;
  static const IconData panelLeft = FluentIcons.global_nav_button;
  static const IconData sortUp = FluentIcons.sort_up;
  static const IconData sortDown = FluentIcons.sort_down;
  static const IconData clock = FluentIcons.clock;
  static const IconData gauge = FluentIcons.speed_high;
  static const IconData expand = FluentIcons.full_screen;
  static const IconData exitFullscreen = FluentIcons.back_to_window;
  static const IconData miniPlayer = FluentIcons.mini_expand;
  static const IconData device = FluentIcons.speakers;
  static const IconData check = FluentIcons.check_mark;
  static const IconData info = FluentIcons.info;
  static const IconData streamPath = FluentIcons.flow;
  static const IconData equalizer = FluentIcons.equalizer;
  static const IconData visualizer = WindowsIcons.volume_bars;
  static const IconData theme = WindowsIcons.color;

  // Community — DO NOT use these generic fallbacks for UI.
  // Use TelegramIcon / DiscordIcon from brand_icons.dart (official marks).
  // Kept only for legacy compat.
  // ignore: provide_deprecation_message
  @deprecated
  static const IconData telegram = FluentIcons.send;
  // ignore: provide_deprecation_message
  @deprecated
  static const IconData discord = FluentIcons.chat;
}
