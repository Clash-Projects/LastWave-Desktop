/// Shared matching vocabulary for the two YouTube/addon matchers.
///
/// The Android companion (`TextMatch` + `LosslessMusicApi`) learned this
/// list the hard way: every version word missing here is a remix/lived/
/// slowed variant the scorer equates with the original. Both
/// `InnerTubeMusicApi` (penalty + variant-preference) and `AddonApi`
/// (faithful-version gate) read these sets, so a word added once is
/// honored on every path.
///
/// Safety note: these words only ever *demote* a candidate that carries
/// them unasked (penalty, pool exclusion, faithful-version veto). A
/// request that names the word itself ("Live Forever", "Stereo Hearts",
/// "Part of Me", "Tribute") always matches itself exactly, so genuine
/// titles containing these words are unaffected.
class MatchVocab {
  /// Version billing: any of these in a candidate title (bracketed, bare
  /// tail, or mid-title) marks a different recording from a request
  /// that doesn't name it. Union of the desktop matcher set and
  /// Android's `VERSION_WORDS` + identity-variant names.
  static const Set<String> versionWords = {
    // Core versions (both matchers already had these).
    'live', 'remix', 'karaoke', 'cover', 'instrumental', 'slowed',
    'sped', 'nightcore', 'acoustic', 'demo', 'edit', 'remaster',
    'remastered', 'mono', 'stereo', 'version', 'deluxe', 'bonus',
    'mix', 'extended', 'radio', 'clean', 'explicit', 'original',
    'orchestral', 'unplugged', 'rerecorded', 'anniversary', 'edition',
    // Android VERSION_WORDS + identity variants desktop lacked.
    'remixes', 'rmx', 'refix', 'flip', 'bootleg', 'mashup', 'medley',
    'concert', 'vocals', 'vocal', 'acapella', 'acappella', 'backing',
    'stems', 'stem', 'reprise', 'remake', 'rework', 'reverb', 'lofi',
    'symphonic', 'part', 'pt', 'chapter', 'atmos', 'dolby', 'spatial',
    'tribute', 'chopped', 'screwed', 'boosted', '8d', 'session',
    'unreleased',
  };

  /// Label filler that never distinguishes recordings: parental tags,
  /// upload/packaging labels and the bare feat keywords left over after
  /// the credit itself is removed. Real version billing is NOT here.
  static const Set<String> neutralWords = {
    'explicit', 'clean', 'official', 'audio', 'video', 'visualizer',
    'lyrics', 'lyric', 'lyrical', 'hd', 'hq', '4k', 'track', 'music',
    'song', 'songs', 'full', 'mv', 'ost', 'soundtrack', 'feat', 'ft',
  };
}
