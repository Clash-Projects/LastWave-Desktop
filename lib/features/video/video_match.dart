import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../core/audio/stream_models.dart';

/// Text helpers and the "is this search result really the song's video"
/// gate, ported from LastWave-Native (`TextMatch`, `VideoCandidateMatch`,
/// `SyncedVideoRepository.scoreVideoCandidate`). A wrong video is worse
/// than no video, so every rule here only ever rejects or demotes.
class VideoTextMatch {
  VideoTextMatch._();

  static final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}\p{M}]+', unicode: true);
  static final RegExp _multiSpace = RegExp(r'\s+');

  /// Combining marks after a Latin base (Café → cafe). Marks in other
  /// scripts are integral letters (Hindi matras), so they stay.
  static final RegExp _latinDiacritics = RegExp(
    r'(?<=[A-Za-z])\p{M}+',
    unicode: true,
  );

  static const Set<String> matchNoiseWords = {
    'official',
    'audio',
    'video',
    'visualizer',
    'lyrics',
    'lyric',
    'hd',
    'hq',
    '4k',
    'track',
    'music',
    'ost',
    'soundtrack',
    'lyrical',
    'full',
  };

  static final RegExp _featuringClause = RegExp(
    r'[(\[]\s*(feat(?:uring)?|ft)\.?\s+.*?[)\]]',
    caseSensitive: false,
  );
  static final RegExp _soundtrackClause = RegExp(
    r'''[(\[]\s*(from\s+["']?|ost\b|original\s+(?:motion\s+picture\s+)?soundtrack)[^)\]]*[)\]]''',
    caseSensitive: false,
  );
  static final RegExp _versionOrLabelClause = RegExp(
    r'[(\[][^)\]]*(official|music\s*video|audio|video|visualizer|lyrics?|hd|hq|4k|live|remix|acoustic|demo|edit|remaster(?:ed)?|mono|stereo|deluxe|bonus|version|mix)[^)\]]*[)\]]',
    caseSensitive: false,
  );

  static String normalize(String value) {
    final lower = value.toLowerCase();
    final stripped = unorm.nfd(lower).replaceAll(_latinDiacritics, '');
    final composed = unorm.nfkc(stripped);
    return _foldArabic(composed)
        .replaceAll(_nonWord, ' ')
        .trim()
        .replaceAll(_multiSpace, ' ');
  }

  static String _foldArabic(String value) => value
      .replaceAll(RegExp('[أإآٱ]'), 'ا')
      .replaceAll('ؤ', 'و')
      .replaceAll('ئ', 'ي')
      .replaceAll('ة', 'ه')
      .replaceAll('ى', 'ي')
      .replaceAll(RegExp('[ً-ٰٕ]'), '');

  static Set<String> tokens(String value) =>
      normalize(value)
          .split(' ')
          .where((t) => t.isNotEmpty && !matchNoiseWords.contains(t))
          .toSet();

  static String baseTitle(String value) {
    var v = value;
    final pipe = v.indexOf(' | ');
    if (pipe >= 0) v = v.substring(0, pipe);
    final slashes = v.indexOf(' // ');
    if (slashes >= 0) v = v.substring(0, slashes);
    return v
        .replaceAll(_featuringClause, ' ')
        .replaceAll(_soundtrackClause, ' ')
        .replaceAll(_versionOrLabelClause, ' ');
  }
}

const int _sameLengthToleranceSeconds = 20;

/// Shorter artist words ("DJ", "The") appear in too many unrelated titles.
const int _minArtistWordLength = 4;

/// Whether a search result is really this song. The result must carry the
/// full song title as whole words, and must also name the artist or run
/// about as long as the song (labels upload under their own channel).
bool isSameSongVideo({
  required String candidateTitle,
  required String candidateChannel,
  required int? candidateSeconds,
  required String songTitle,
  required String songArtist,
  required int? songDurationMs,
}) {
  final wantedTitle = VideoTextMatch.normalize(songTitle);
  if (wantedTitle.isEmpty) return false;
  final title = VideoTextMatch.normalize(candidateTitle);
  if (!' $title '.contains(' $wantedTitle ')) return false;

  final candidateWords = {
    ...title.split(' '),
    ...VideoTextMatch.normalize(candidateChannel).split(' '),
  };
  final namesArtist = VideoTextMatch.normalize(songArtist)
      .split(' ')
      .any(
        (w) => w.length >= _minArtistWordLength && candidateWords.contains(w),
      );
  if (namesArtist) return true;

  // Stage names with symbols ("KR$NA", "Ke$ha") fall apart into short
  // words once punctuation is stripped, so also compare each credited
  // artist as one squashed word against the squashed title and channel.
  final squashed =
      title.replaceAll(' ', '') +
      VideoTextMatch.normalize(candidateChannel).replaceAll(' ', '');
  for (final part in songArtist.split(_artistSeparator)) {
    final compact = VideoTextMatch.normalize(part).replaceAll(' ', '');
    if (compact.length >= _minArtistWordLength && squashed.contains(compact)) {
      return true;
    }
  }

  if (candidateSeconds == null ||
      candidateSeconds <= 0 ||
      songDurationMs == null ||
      songDurationMs <= 0) {
    return false;
  }
  return (candidateSeconds - songDurationMs ~/ 1000).abs() <=
      _sameLengthToleranceSeconds;
}

const int minVideoCandidateScore = 60;

const Set<String> _unrelatedUploadWords = {
  'bgmi',
  'pubg',
  'freefire',
  'gameplay',
  'gaming',
  'montage',
  'fortnite',
  'minecraft',
  'valorant',
  'gta',
  'amv',
  'fmv',
  'edit',
  'edits',
  'status',
  'tiktok',
  'reels',
};

/// Labels often upload a song under their own channel, without the artist.
const List<String> _labelChannels = [
  'tseries',
  'tips',
  'saregama',
  'sonymusic',
  'zeemusic',
  'yrf',
  'records',
  'entertainment',
];

final RegExp _artistSeparator = RegExp(
  r'\s*(?:,|&|/|\bfeat\.?\b|\bft\.?\b|\bx\b|\band\b)\s*',
  caseSensitive: false,
);

/// Scores a search result as the video for a track, or null when it is not
/// that track at all. The title has to match and a known artist has to
/// appear: "official video" alone only proves it is somebody's video.
int? scoreVideoCandidate({
  required String candidateTitle,
  required String candidateArtist,
  required int? candidateDurationSec,
  required String wantedTitle,
  required String wantedArtist,
  required int? expectedDurationMs,
}) {
  var wantedTokens = VideoTextMatch.tokens(
    VideoTextMatch.baseTitle(wantedTitle),
  );
  if (wantedTokens.isEmpty) {
    wantedTokens = VideoTextMatch.normalize(wantedTitle)
        .split(' ')
        .where((t) => t.isNotEmpty)
        .toSet();
  }
  final title = VideoTextMatch.normalize(candidateTitle);
  final words = title.split(' ').toSet();
  if (wantedTokens.isEmpty || !words.containsAll(wantedTokens)) return null;

  final wantedWords = VideoTextMatch.normalize(wantedTitle).split(' ').toSet();
  if (_unrelatedUploadWords.any(
        (w) => words.contains(w) && !wantedWords.contains(w),
      ) ||
      title.contains('free fire')) {
    return null;
  }

  String compact(String value) =>
      VideoTextMatch.normalize(value).replaceAll(' ', '');
  final channel = compact(candidateArtist);
  if (channel.contains('gaming') || channel.contains('gamer')) return null;
  final compactTitle = title.replaceAll(' ', '');
  final fromLabel = _labelChannels.any(channel.contains);
  var artistOwnsChannel = false;
  if (wantedArtist.trim().isNotEmpty) {
    final artists = wantedArtist
        .split(_artistSeparator)
        .map(compact)
        .where((a) => a.length >= 2)
        .toList();
    artistOwnsChannel =
        artists.any(channel.contains) ||
        (channel.length >= 2 && compact(wantedArtist).contains(channel));
    if (!artistOwnsChannel &&
        !fromLabel &&
        !artists.any(compactTitle.contains)) {
      return null;
    }
  }

  final padded = ' $title ';
  final claimsToBeTheVideo =
      title.contains('official music video') ||
      title.contains('official video') ||
      title.contains('music video') ||
      title.contains('official visualizer') ||
      title.contains('video song') ||
      title.contains('full video') ||
      words.contains('mv') ||
      padded.contains(' m v ') ||
      channel.contains('vevo');
  if (!artistOwnsChannel && !fromLabel && !claimsToBeTheVideo) return null;

  bool unwanted(List<String> variants) =>
      variants.any((v) => words.contains(v) && !wantedWords.contains(v));

  var score = 40;
  if (artistOwnsChannel) {
    score += 30;
  } else if (wantedArtist.trim().isNotEmpty) {
    score += 15;
  }
  if (title.contains('official music video') ||
      title.contains('official video')) {
    score += 50;
  } else if (title.contains('music video') ||
      title.contains('official visualizer') ||
      title.contains('video song') ||
      title.contains('full video')) {
    score += 30;
  }
  if (words.contains('mv') || padded.contains(' m v ')) score += 25;
  if (channel.contains('vevo')) score += 35;
  if (fromLabel) {
    score += 20;
  } else if (channel.contains('official')) {
    score += 15;
  }

  if (words.contains('lyric') || words.contains('lyrics')) score -= 30;
  if (words.contains('audio') ||
      words.contains('topic') ||
      candidateArtist.endsWith('- Topic')) {
    score -= 40;
  }
  if (unwanted(const ['live'])) score -= 50;
  if (unwanted(const ['remix'])) score -= 70;
  if (unwanted(const ['cover', 'karaoke', 'reaction'])) score -= 80;
  if (unwanted(const ['mashup', 'parody', 'tribute'])) score -= 90;
  if (unwanted(const ['slowed', 'reverb', 'sped', '8d'])) score -= 80;
  if (unwanted(const [
    'teaser',
    'trailer',
    'preview',
    'bts',
    'short',
    'shorts',
  ])) {
    score -= 100;
  }

  if (expectedDurationMs != null &&
      expectedDurationMs > 30000 &&
      candidateDurationSec != null &&
      candidateDurationSec > 0) {
    final expectedSec = expectedDurationMs ~/ 1000;
    final delta = (candidateDurationSec - expectedSec).abs();
    if (delta <= 15) {
      score += 35;
    } else if (delta <= 45) {
      score += 15;
    } else if (delta > 120) {
      score -= 80;
    } else if (delta > 60) {
      score -= 40;
    }
    if (candidateDurationSec < 60 && expectedSec > 90) score -= 120;
  }
  return score;
}

/// Strips credits and upload labels from a track title before searching.
/// Version clauses stay: they mean another rendition.
String cleanTrackTitleForVideo(String title) {
  final patterns = <RegExp>[
    RegExp(r'\s*\(feat\..*?\)', caseSensitive: false),
    RegExp(r'\s*\(with.*?\)', caseSensitive: false),
    RegExp(r'\s*[(\[]\s*from\s+[^)\]]*[)\]]', caseSensitive: false),
    RegExp(r'\s*\[feat\..*?\]', caseSensitive: false),
    RegExp(r'\s*-\s*remaster(?:ed)?(?:\s*\d{4})?', caseSensitive: false),
    RegExp(r'\s*\(official\s*(?:music\s*)?video\)', caseSensitive: false),
    RegExp(r'\s*\[official\s*(?:music\s*)?video\]', caseSensitive: false),
    RegExp(r'\s*\(official\s*audio\)', caseSensitive: false),
    RegExp(r'\s*\[official\s*audio\]', caseSensitive: false),
    RegExp(r'\s*\(visualizer\)', caseSensitive: false),
    RegExp(r'\s*\[visualizer\]', caseSensitive: false),
  ];
  var out = title;
  for (final p in patterns) {
    out = out.replaceAll(p, '');
  }
  return out.trim();
}

int _codecRank(MusicVideoStream s) {
  final c = s.codec.toLowerCase();
  // H.264 decodes in hardware nearly everywhere, VP9 widely, AV1 often only
  // in software; a heavy decoder shows up as dropped frames.
  if (c.startsWith('avc')) return 0;
  if (c.startsWith('vp9') || c.startsWith('vp09')) return 1;
  if (c.startsWith('av01')) return 2;
  return 3;
}

/// Every candidate in the order to try them. Auto (0) aims for the picture
/// that fits the display ([autoHeight], see [autoVideoHeightFor]); a fixed
/// height aims for that height. Candidates at or below the target come first,
/// tallest first; anything taller only follows as a last resort. At the
/// same height: lighter codec first, then video-only over the progressive
/// file, then ≤30 fps over 60 (half the decode work for a backdrop), then
/// the higher bitrate.
List<MusicVideoStream> rankVideoStreams(
  List<MusicVideoStream> streams,
  int preferredHeight, {
  int autoHeight = 1080,
}) {
  final cap = preferredHeight <= 0 ? autoHeight : preferredHeight;
  final ranked = [...streams];
  ranked.sort((a, b) {
    final aOver = a.height > cap ? 1 : 0;
    final bOver = b.height > cap ? 1 : 0;
    if (aOver != bOver) return aOver.compareTo(bOver);
    if (a.height != b.height) {
      return aOver == 0
          ? b.height.compareTo(a.height)
          : a.height.compareTo(b.height);
    }
    final codec = _codecRank(a).compareTo(_codecRank(b));
    if (codec != 0) return codec;
    if (a.muxed != b.muxed) return a.muxed ? 1 : -1;
    final aFast = a.fps > 30 ? 1 : 0;
    final bFast = b.fps > 30 ? 1 : 0;
    if (aFast != bFast) return aFast.compareTo(bFast);
    return b.bitrate.compareTo(a.bitrate);
  });
  return ranked;
}

/// What Auto aims for: the smallest standard height that still fills a
/// display [physicalHeightPx] pixels tall (a little slack allowed), so a
/// 1080p screen gets 1080p and a 4K screen gets 2160p. Never below 720p.
int autoVideoHeightFor(double physicalHeightPx) {
  for (final step in const [720, 1080, 1440]) {
    if (physicalHeightPx <= step / 0.9) return step;
  }
  return 2160;
}

/// The best candidate for [preferredHeight], or null when there is none.
MusicVideoStream? pickVideoStreamForQuality(
  List<MusicVideoStream> streams,
  int preferredHeight, {
  int autoHeight = 1080,
}) {
  final ranked = rankVideoStreams(
    streams,
    preferredHeight,
    autoHeight: autoHeight,
  );
  return ranked.isEmpty ? null : ranked.first;
}

/// A YouTube Music song row, reduced to what matching needs.
typedef SongAudioCandidate = ({
  String id,
  String title,
  String artist,
  int seconds,
});

const Set<String> _otherRenditionWords = {
  'live',
  'remix',
  'cover',
  'karaoke',
  'slowed',
  'sped',
  'reverb',
  'instrumental',
  'acoustic',
  'mashup',
  'lofi',
  'nightcore',
  '8d',
  'edit',
};

/// Which search result is this song's own studio audio on YouTube, or null.
///
/// That audio is a stand-in for the recording the user is playing when the
/// timing of a video has to be measured against it: the playing source can
/// be a local proxy or a file that cannot be read a second time. It must be
/// the same recording, so the title must match whole, the artist (or the
/// length) must agree, a known length must be within 8 s, and live / remix /
/// slowed renditions are skipped unless the song itself is one.
String? pickSongAudioCandidate(
  List<SongAudioCandidate> results, {
  required String title,
  required String artist,
  required int? durationMs,
  String? excludeId,
}) {
  final wanted = VideoTextMatch.normalize(title);
  final wantedWords = wanted.split(' ').toSet();
  String? exact;
  String? first;
  for (final c in results) {
    if (c.id.isEmpty || c.id == excludeId) continue;
    final seconds = c.seconds > 0 ? c.seconds : null;
    // A song row always names its artist, so the artist must agree: a
    // same-titled song of the same length by someone else (a cover) is not
    // the recording. Only with no artist known does length stand in.
    final artistKnown = artist.trim().isNotEmpty;
    if (!isSameSongVideo(
      candidateTitle: c.title,
      candidateChannel: c.artist,
      candidateSeconds: artistKnown ? null : seconds,
      songTitle: title,
      songArtist: artist,
      songDurationMs: artistKnown ? null : durationMs,
    )) {
      continue;
    }
    final words = VideoTextMatch.normalize(c.title).split(' ').toSet();
    if (_otherRenditionWords.any(
      (w) => words.contains(w) && !wantedWords.contains(w),
    )) {
      continue;
    }
    if (durationMs != null &&
        durationMs > 0 &&
        seconds != null &&
        (seconds - durationMs ~/ 1000).abs() > 8) {
      continue;
    }
    first ??= c.id;
    if (VideoTextMatch.normalize(c.title) == wanted) {
      exact ??= c.id;
    }
  }
  return exact ?? first;
}
