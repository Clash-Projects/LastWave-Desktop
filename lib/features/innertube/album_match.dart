import '../../core/artwork/official_artwork_service.dart';
import '../../core/audio/artist_parser.dart' show splitArtistCredits;
import 'innertube_api.dart';

const _versionWords = {
  'remix', 'edm', 'mix', 'slowed', 'reverb', 'lofi', 'lo',
  'acoustic', 'live', 'unplugged', 'reprise', 'sped', 'mashup', 'bass',
};

/// Picks the album entity that actually corresponds to a target
/// (title, artist) pair from YouTube Music album search results.
///
/// Why: YouTube ranks by popularity, not correctness — searching
/// "Future DS2 (Deluxe)" returns "DS2: Track by Track Commentary"
/// first. Taking results.first loads commentary/fan entities whose
/// tracks have no artist, no durations and no artwork.
///
/// [minScore] floors acceptance: the default 60 admits substring
/// title matches, while callers working from uncertain (backfilled)
/// album text pass a higher bar so weak matches fall back to search
/// instead of opening a wrong album page.
YouTubeMusicEntity? pickBestAlbumMatch(
  List<YouTubeMusicEntity> results, {
  required String title,
  required String artist,
  int minScore = 60,
  bool requireArtist = false,
}) {
  final targetTitle = OfficialArtworkService.normalizeForSearch(title);
  final targetArtist = OfficialArtworkService.normalizeForSearch(artist);
  if (targetTitle.isEmpty) return null;

  YouTubeMusicEntity? best;
  var bestScore = -1;
  for (final e in results) {
    if (e.browseId.isEmpty) continue;
    final name = OfficialArtworkService.normalizeForSearch(e.name);
    final by = OfficialArtworkService.normalizeForSearch(e.artist);
    if (name.isEmpty) continue;

    var score = 0;
    if (name == targetTitle) {
      score += 100;
    } else if (name.contains(targetTitle) ||
        targetTitle.contains(name)) {
      score += 60;
    } else {
      continue; // unrelated title
    }

    if (targetArtist.isNotEmpty && by.isNotEmpty) {
      if (by == targetArtist) {
        score += 100;
      } else if (by.contains(targetArtist) ||
          targetArtist.contains(by)) {
        score += 50;
      }
    }

    if (requireArtist && targetArtist.isNotEmpty) {
      // The same title exists under many artists ("Rehbara" by Abhijeet
      // vs another act): the row must credit one of the billed artists.
      final credited = '$by ${OfficialArtworkService.normalizeForSearch(e.subtitle)}';
      final billed = splitArtistCredits(artist)
          .map(OfficialArtworkService.normalizeForSearch)
          .where((c) => c.isNotEmpty);
      if (!billed.any(credited.contains)) continue;
    }

    // A remix/EDM/slowed edition must not stand in for the original.
    final nameTokens = name.split(' ').toSet();
    final targetTokens = targetTitle.split(' ').toSet();
    if (nameTokens.intersection(_versionWords).difference(targetTokens)
        .isNotEmpty) {
      score -= 80;
    }

    final noise = '$name ${OfficialArtworkService.normalizeForSearch(e.subtitle)}';
    if (noise.contains('commentary') ||
        noise.contains('karaoke') ||
        noise.contains('tribute') ||
        noise.contains('instrumental') ||
        noise.contains('track by track') ||
        noise.contains('cover')) {
      score -= 100;
    }

    if (score > bestScore) {
      bestScore = score;
      best = e;
    }
  }
  if (best == null || bestScore < minScore) return null;
  return best;
}

/// YouTube Music browseId for a Last.fm-style (title, artist) album, or ''.
///
/// Last.fm bills singles as "Aarzu (with Asim Azhar)" / "X (From "Film")";
/// the catalog files the plain title, so the full billing is tried first
/// and the title cut at its first bracket second.
Future<String> resolveAlbumBrowseId(
  InnerTubeMusicApi tube, {
  required String title,
  required String artist,
}) async {
  final plain = title.replaceFirst(RegExp(r'\s*[\(\[].*$'), '').trim();
  for (final t in {title, if (plain.isNotEmpty) plain}) {
    try {
      final results = await tube.searchAlbums('$artist $t', limit: 6);
      final hit = pickBestAlbumMatch(results,
          title: t, artist: artist, requireArtist: true, minScore: 100);
      if (hit != null) return hit.browseId;
    } catch (_) {}
  }
  // Singles often have no album the album search surfaces, but the song
  // row links straight to its album: take the id from the matching song.
  final wantTitle = OfficialArtworkService.normalizeForSearch(
      plain.isNotEmpty ? plain : title);
  final billed = splitArtistCredits(artist)
      .map(OfficialArtworkService.normalizeForSearch)
      .where((c) => c.isNotEmpty);
  try {
    final songs = await tube.searchSongs('$artist $title', limit: 8);
    for (final s in songs) {
      if (s.albumBrowseId.isEmpty) continue;
      final name = OfficialArtworkService.normalizeForSearch(
          s.title.replaceFirst(RegExp(r'\s*[\(\[].*$'), ''));
      final by = OfficialArtworkService.normalizeForSearch(s.artist);
      if (name == wantTitle && billed.any(by.contains)) {
        return s.albumBrowseId;
      }
    }
  } catch (_) {}
  return '';
}
