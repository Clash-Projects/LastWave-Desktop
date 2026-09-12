import 'package:flutter/material.dart';

/// LastWave icon set, backed by Material icons.
///
/// Replaces the unmaintained `lucide_icons` package (incompatible with
/// current Flutter: it subclasses the now-final `IconData`). All names
/// keep their Lucide meaning so call sites read the same.
abstract final class LwIcons {
  static const IconData arrowLeft = Icons.arrow_back;
  static const IconData atSign = Icons.alternate_email;
  static const IconData check = Icons.check;
  static const IconData chevronRight = Icons.chevron_right;
  static const IconData cloudOff = Icons.cloud_off;
  static const IconData disc3 = Icons.album;
  static const IconData download = Icons.download;
  static const IconData globe = Icons.public;
  static const IconData heart = Icons.favorite;
  static const IconData history = Icons.history;
  static const IconData home = Icons.home;
  static const IconData library = Icons.library_music;
  static const IconData listMusic = Icons.queue_music;
  static const IconData listPlus = Icons.playlist_add;
  static const IconData listVideo = Icons.video_library;
  static const IconData maximize2 = Icons.open_in_full;
  static const IconData mic = Icons.mic;
  static const IconData minus = Icons.remove;
  static const IconData moreHorizontal = Icons.more_horiz;
  static const IconData music = Icons.music_note;
  static const IconData panelLeft = Icons.menu;
  static const IconData pause = Icons.pause;
  static const IconData pencil = Icons.edit;
  static const IconData pin = Icons.push_pin;
  static const IconData pinOff = Icons.push_pin_outlined;
  static const IconData play = Icons.play_arrow;
  static const IconData plus = Icons.add;
  static const IconData refreshCw = Icons.refresh;
  static const IconData repeat = Icons.repeat;
  static const IconData repeat1 = Icons.repeat_one;
  static const IconData search = Icons.search;
  static const IconData searchX = Icons.search_off;
  static const IconData settings = Icons.settings;
  static const IconData shuffle = Icons.shuffle;
  static const IconData skipBack = Icons.skip_previous;
  static const IconData skipForward = Icons.skip_next;
  static const IconData sparkles = Icons.auto_awesome;
  static const IconData square = Icons.crop_square;
  static const IconData timer = Icons.timer;
  static const IconData trash2 = Icons.delete_outline;
  static const IconData trendingUp = Icons.trending_up;
  static const IconData user = Icons.person;
  static const IconData users = Icons.people;
  static const IconData volume2 = Icons.volume_up;
  static const IconData wand2 = Icons.auto_fix_high;
  static const IconData x = Icons.close;
  static const IconData youtube = Icons.music_video;
}
