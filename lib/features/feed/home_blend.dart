import '../../core/artwork/official_artwork_service.dart';
import '../../core/storage/app_database.dart';
import '../innertube/innertube_api.dart';
import 'feed_repository.dart';

/// How much a YouTube Music home shelf deserves a place on Home.
enum YtShelfTier { quickPicks, listenAgain, personal, general, unknown, junk }

/// Sorts a shelf by its title. YouTube gives no machine-readable shelf type,
/// so titles are all there is. Junk is checked first: "Recommended music
/// videos" must not pass as personal because it says "recommended".
YtShelfTier classifyYtShelf(String title) {
  final t = title.toLowerCase().trim();
  bool any(List<String> words) => words.any(t.contains);
  if (any(const [
    'video',
    'short',
    'podcast',
    'episode',
    'live performance',
    'long listening',
    'cover',
    'remix',
    'community',
    'mood',
    'genre',
    'audiobook',
    'sing along',
  ])) {
    return YtShelfTier.junk;
  }
  if (t.contains('quick pick')) return YtShelfTier.quickPicks;
  if (t.contains('listen again')) return YtShelfTier.listenAgain;
  if (any(const [
    'for you',
    'your ',
    'mix',
    'recommended',
    'similar to',
    'more from',
    'because',
    'favorite',
    'favourite',
    'keep listening',
    'recap',
    'discover',
  ])) {
    return YtShelfTier.personal;
  }
  if (any(const ['new release', 'chart', 'trending', 'top ', 'hits', 'album'])) {
    return YtShelfTier.general;
  }
  return YtShelfTier.unknown;
}

/// The connected Home: YouTube's own shelves re-ordered by Last.fm taste.
class HomeBlend {
  final List<GeneratedTrack> quickPicks;
  final List<GeneratedTrack> listenAgain;
  final List<YtHomeShelf> personal;
  final List<YtHomeShelf> general;

  /// Billed artists the user actually listens to, strongest first.
  final List<GeneratedTrack> artists;

  const HomeBlend({
    this.quickPicks = const [],
    this.listenAgain = const [],
    this.personal = const [],
    this.general = const [],
    this.artists = const [],
    this.hasYouTube = false,
  });

  /// False when YouTube gave nothing usable and Home should fall back.
  final bool hasYouTube;
}

/// Shelves that do not belong on the music Home (they have their own tabs).
bool _offTopic(String title) {
  final t = title.toLowerCase();
  return const ['podcast', 'episode', 'short', 'audiobook']
      .any(t.contains);
}

/// The connected Home: YouTube Music's own feed, as YouTube lays it out.
///
/// YouTube's shelves keep YouTube's order and contents — no re-ranking by
/// Last.fm taste, no shelf dropped for "not matching taste", no cap. Last.fm
/// only fills in where YouTube has nothing (an empty Quick picks / Listen
/// again) and supplies the small "because you listened" and artist rows
/// that follow the feed.
HomeBlend blendHomeFeed({
  required List<YtHomeShelf> shelves,
  required FeedData feed,
  Set<String> excluded = const {},
  int maxShelves = 40,
  int minItems = 2,
  int quickPickCount = 12,
  int listenAgainCount = 12,
}) {
  final affinities = feed.tasteAffinities;
  final maxAffinity =
      affinities.values.fold<double>(0, (m, v) => v > m ? v : m);

  double taste(String artist) {
    if (maxAffinity <= 0 || artist.isEmpty) return 0;
    var best = 0.0;
    final credits = OfficialArtworkService.splitArtistCredits(artist);
    for (final name in credits.isEmpty ? [artist] : credits) {
      final v = affinities[normalizeArtistKey(name)] ?? 0;
      if (v > best) best = v;
    }
    return best / maxAffinity;
  }

  bool allowed(YouTubeMusicTrack t) => !excluded
      .contains(AppDatabase.exclusionKey(t.title, t.artist));

  // Hidden tracks are the only thing removed from a shelf.
  YtHomeShelf visible(YtHomeShelf s) => YtHomeShelf(
        title: s.title,
        subtitle: s.subtitle,
        tracks: s.tracks.where(allowed).toList(),
        trackCards: s.trackCards.where(allowed).toList(),
        entities: s.entities,
      );

  bool renderable(YtHomeShelf s) =>
      s.tracks.length + s.trackCards.length + s.entities.length >= minItems;

  final ytQuick = <YouTubeMusicTrack>[];
  final ytAgain = <YouTubeMusicTrack>[];
  final feedShelves = <YtHomeShelf>[];
  final titles = <String>{};
  for (final raw in shelves) {
    if (raw.title.isEmpty || !titles.add(raw.title.toLowerCase())) continue;
    if (_offTopic(raw.title)) continue;
    final shelf = visible(raw);
    switch (classifyYtShelf(raw.title)) {
      case YtShelfTier.quickPicks:
        ytQuick.addAll([...shelf.tracks, ...shelf.trackCards]);
      case YtShelfTier.listenAgain:
        ytAgain.addAll([...shelf.trackCards, ...shelf.tracks]);
      default:
        if (renderable(shelf)) feedShelves.add(shelf);
    }
  }

  GeneratedTrack fromYt(YouTubeMusicTrack t) => GeneratedTrack(
        name: t.title,
        artist: t.artist,
        album: t.album,
        artworkUrl: t.artworkUrl,
        videoId: t.videoId,
        durationSeconds: t.durationSeconds,
      );

  // Feed picks can include charts; only ones matching real taste count.
  final tastePicks = [...feed.heavyRotation, ...feed.quickPicks]
      .where((t) => t.artworkUrl.isNotEmpty && taste(t.artist) > 0)
      .toList();

  // YouTube's picks as YouTube ranks them; Last.fm only when YouTube sent
  // none.
  final quick = _interleave(
    ytQuick.map(fromYt).toList(),
    ytQuick.isEmpty ? tastePicks : const [],
    limit: quickPickCount,
    maxPerArtist: 3,
  );
  final again = _interleave(
    ytAgain.map(fromYt).toList(),
    ytAgain.isEmpty
        ? feed.jumpBackIn.where((t) => t.artworkUrl.isNotEmpty).toList()
        : const [],
    limit: listenAgainCount,
    maxPerArtist: 4,
  );

  final artists = <GeneratedTrack>[];
  final seen = <String>{};
  final tasted = [...feed.heavyRotation, ...feed.jumpBackIn, ...tastePicks];
  for (final t in tasted) {
    if (artists.length >= 12) break;
    for (final name in OfficialArtworkService.splitArtistCredits(t.artist)) {
      if (artists.length >= 12) break;
      if (taste(name) <= 0 || !seen.add(name.toLowerCase())) continue;
      artists.add(GeneratedTrack(name: name, artist: name, videoId: t.videoId));
    }
  }

  return HomeBlend(
    quickPicks: quick,
    listenAgain: again,
    // Every YouTube shelf, in YouTube's order.
    personal: feedShelves.take(maxShelves).toList(),
    general: const [],
    artists: artists,
    hasYouTube: ytQuick.isNotEmpty ||
        ytAgain.isNotEmpty ||
        feedShelves.isNotEmpty,
  );
}
/// Two from [primary], one from [secondary], deduped by id and name|artist.
List<GeneratedTrack> _interleave(
  List<GeneratedTrack> primary,
  List<GeneratedTrack> secondary, {
  required int limit,
  required int maxPerArtist,
}) {
  final out = <GeneratedTrack>[];
  final seen = <String>{};
  final perArtist = <String, int>{};
  bool take(GeneratedTrack t) {
    final key = '${t.name.toLowerCase()}|${t.artist.toLowerCase()}';
    final artist = normalizeArtistKey(t.artist);
    if (seen.contains(key) ||
        (t.videoId.isNotEmpty && seen.contains(t.videoId)) ||
        (perArtist[artist] ?? 0) >= maxPerArtist) {
      return false;
    }
    seen.add(key);
    if (t.videoId.isNotEmpty) seen.add(t.videoId);
    perArtist[artist] = (perArtist[artist] ?? 0) + 1;
    out.add(t);
    return true;
  }

  var p = 0;
  var s = 0;
  void pull(List<GeneratedTrack> from, bool isPrimary) {
    while (isPrimary ? p < from.length : s < from.length) {
      final t = from[isPrimary ? p++ : s++];
      if (take(t)) return;
    }
  }

  while (out.length < limit && (p < primary.length || s < secondary.length)) {
    pull(primary, true);
    if (out.length >= limit) break;
    pull(primary, true);
    if (out.length >= limit) break;
    pull(secondary, false);
  }
  return out;
}
