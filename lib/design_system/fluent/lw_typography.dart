import '../../../ui/theme/tokens.dart';

/// Typography — re-exports canonical Wave type with semantic aliases.
///
/// Artwork + type carry hierarchy, not boxes:
/// - pageTitle 22/700/-0.4 · sectionTitle 15/700 · trackTitle 13.5/600
/// - body 13 · meta 12 · label 12/600/0.2 · overline 10.5/700/1.0
/// - numeral tabular · lyricActive 21/700 · lyricIdle 16/500
class LwTypography {
  LwTypography._();

  static const pageTitle = WaveType.pageTitle;
  static const sectionTitle = WaveType.sectionTitle;
  static const trackTitle = WaveType.trackTitle;
  static const body = WaveType.body;
  static const meta = WaveType.meta;
  static const label = WaveType.label;
  static const overline = WaveType.overline;
  static const numeral = WaveType.numeral;
  static const lyricActive = WaveType.lyricActive;
  static const lyricIdle = WaveType.lyricIdle;
}
