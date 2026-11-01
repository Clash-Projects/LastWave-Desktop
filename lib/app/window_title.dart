import '../core/audio/stream_models.dart';

/// The OS window title for the current track: desktop players are
/// identified by what is playing, and the taskbar button already carries
/// the app icon. Falls back to the app name when nothing is playing.
String windowTitleFor(PlayableTrack? track) {
  final title = track?.title.trim() ?? '';
  if (title.isEmpty) return 'LastWave';
  final artist = track!.artist.trim();
  return artist.isEmpty ? title : '$title \u2014 $artist';
}
