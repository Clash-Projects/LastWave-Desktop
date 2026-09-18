import 'package:fluent_ui/fluent_ui.dart';

/// Canonical LastWave icon set — ONE coherent Fluent family.
///
/// All presentation code must use [WaveIcons] instead of importing
/// `lucide_icons_flutter`, Material or Cupertino icons directly. The
/// mapping below uses Segoe MDL2 / Fluent glyphs exclusively so stroke
/// weight and geometry stay consistent across rail, command bars,
/// tables, dock and dialogs.
///
/// Notes on transport mapping (Segoe MDL2 has no dedicated shuffle
/// glyph): shuffle → [FluentIcons.switcher_start_end] (crossed swap
/// arrows, the closest Windows-native shuffle metaphor), previous →
/// [FluentIcons.previous], next → [FluentIcons.next], repeat →
/// [FluentIcons.repeat_all], repeat-one → [FluentIcons.repeat_one].
/// Lyrics → [FluentIcons.microphone], queue → [FluentIcons.list_mirrored].
class WaveIcons {
  WaveIcons._();

  // Navigation
  static const IconData home = FluentIcons.home;
  static const IconData discover = FluentIcons.globe;
  static const IconData search = FluentIcons.search;
  static const IconData library = FluentIcons.library;
  static const IconData liked = FluentIcons.heart;
  static const IconData likedFill = FluentIcons.heart_fill;
  static const IconData albums = FluentIcons.album;
  static const IconData artists = FluentIcons.microphone;
  static const IconData playlists = FluentIcons.list_mirrored;
  static const IconData downloads = FluentIcons.download;
  static const IconData friends = FluentIcons.people;
  static const IconData settings = FluentIcons.settings;
  static const IconData history = FluentIcons.history;
  static const IconData mixes = FluentIcons.music_in_collection;

  // Transport
  static const IconData play = FluentIcons.play_solid;
  static const IconData pause = FluentIcons.pause;
  static const IconData previous = FluentIcons.previous;
  static const IconData next = FluentIcons.next;
  static const IconData shuffle = FluentIcons.switcher_start_end;
  static const IconData repeat = FluentIcons.repeat_all;
  static const IconData repeatOne = FluentIcons.repeat_one;

  // Content
  static const IconData music = FluentIcons.music_note;
  static const IconData musicCollection = FluentIcons.music_in_collection;
  static const IconData lyrics = FluentIcons.music_note;
  static const IconData queue = FluentIcons.list_mirrored;
  static const IconData radio = FluentIcons.radio_btn_on;
  static const IconData speaker = FluentIcons.speakers;
  static const IconData volume = FluentIcons.volume2;
  static const IconData volumeMute = FluentIcons.volume_disabled;

  // Actions
  static const IconData more = FluentIcons.more;
  static const IconData add = FluentIcons.add;
  static const IconData addTo = FluentIcons.add_to;
  static const IconData playNext = FluentIcons.add;
  static const IconData downloadAction = FluentIcons.download;
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
  static const IconData miniPlayer = FluentIcons.mini_expand;
  static const IconData device = FluentIcons.speakers;
  static const IconData streamPath = FluentIcons.equalizer;
}
