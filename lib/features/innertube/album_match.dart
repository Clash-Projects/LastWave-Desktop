import '../../core/artwork/official_artwork_service.dart';
import 'innertube_api.dart';

/// Picks the album entity that actually corresponds to a target
/// (title, artist) pair from YouTube Music album search results.
///
/// Why: YouTube ranks by popularity, not correctness — searching
/// "Future DS2 (Deluxe)" returns "DS2: Track by Track Commentary"
/// first. Taking results.first loads commentary/fan entities whose
/// tracks have no artist, no durations and no artwork.
YouTubeMusicEntity? pickBestAlbumMatch(
  List<YouTubeMusicEntity> results, {
  required String title,
  required String artist,
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
  if (best == null || bestScore < 60) return null;
  return best;
}
