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

/// Pure blend of YouTube shelves and the taste-scored feed.
///
/// - Quick Picks interleaves two YouTube picks with one Last.fm taste pick.
/// - Shelves run personal, then general. An unrecognised shelf stays only if
///   it features an artist the user listens to; junk never does.
/// - A shelf needs at least [minItems] items, most with real artwork, so a
///   thin or half-blank row never makes the page.
HomeBlend blendHomeFeed({
  required List<YtHomeShelf> shelves,
  required FeedData feed,
  Set<String> excluded = const {},
  int maxPersonal = 6,
  int maxGeneral = 3,
  int minItems = 3,
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

  // YouTube's order stays the base. Taste can lift a strong artist up to
  // eight places, which sharpens a shelf without shuffling it.
  List<T> rerank<T>(List<T> items, String Function(T) artistOf) {
    final scored = [
      for (var i = 0; i < items.length; i++)
        (item: items[i], score: taste(artistOf(items[i])) * 8 - i),
    ]..sort((a, b) => b.score.compareTo(a.score));
    return [for (final s in scored) s.item];
  }

  String entityArtist(YouTubeMusicEntity e) =>
      e.artist.isNotEmpty ? e.artist : e.subtitle;

  YtHomeShelf tuned(YtHomeShelf s) => YtHomeShelf(
        title: s.title,
        subtitle: s.subtitle,
        tracks: rerank(s.tracks.where(allowed).toList(), (t) => t.artist),
        trackCards:
            rerank(s.trackCards.where(allowed).toList(), (t) => t.artist),
        entities: rerank(s.entities, entityArtist),
      );

  bool looksGood(YtHomeShelf s) {
    final art = [
      ...s.tracks.map((t) => t.artworkUrl),
      ...s.trackCards.map((t) => t.artworkUrl),
      ...s.entities.map((e) => e.artworkUrl),
    ];
    if (art.length < minItems) return false;
    return art.where((a) => a.isNotEmpty).length * 4 >= art.length * 3;
  }

  bool featuresTaste(YtHomeShelf s) =>
      s.tracks.any((t) => taste(t.artist) > 0) ||
      s.trackCards.any((t) => taste(t.artist) > 0) ||
      s.entities.any((e) => taste(entityArtist(e)) > 0);

  double shelfTaste(YtHomeShelf s) {
    final scores = [
      ...s.tracks.map((t) => taste(t.artist)),
      ...s.trackCards.map((t) => taste(t.artist)),
      ...s.entities.map((e) => taste(entityArtist(e))),
    ];
    if (scores.isEmpty) return 0;
    return scores.reduce((a, b) => a + b) / scores.length;
  }

  final ytQuick = <YouTubeMusicTrack>[];
  final ytAgain = <YouTubeMusicTrack>[];
  final personal = <YtHomeShelf>[];
  final general = <YtHomeShelf>[];
  final titles = <String>{};
  for (final raw in shelves) {
    if (raw.title.isEmpty || !titles.add(raw.title.toLowerCase())) continue;
    final tier = classifyYtShelf(raw.title);
    if (tier == YtShelfTier.junk) continue;
    final shelf = tuned(raw);
    switch (tier) {
      case YtShelfTier.quickPicks:
        ytQuick.addAll([...shelf.tracks, ...shelf.trackCards]);
      case YtShelfTier.listenAgain:
        ytAgain.addAll([...shelf.trackCards, ...shelf.tracks]);
      case YtShelfTier.personal:
        if (looksGood(shelf)) personal.add(shelf);
      case YtShelfTier.general:
        if (looksGood(shelf)) general.add(shelf);
      case YtShelfTier.unknown:
        if (looksGood(shelf) && featuresTaste(shelf)) personal.add(shelf);
      case YtShelfTier.junk:
        break;
    }
  }
  // Stable: Dart's sort isn't, so the original index breaks ties.
  final order = {for (var i = 0; i < personal.length; i++) personal[i]: i};
  personal.sort((a, b) {
    final byTaste = shelfTaste(b).compareTo(shelfTaste(a));
    return byTaste != 0 ? byTaste : order[a]!.compareTo(order[b]!);
  });

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

  final quick = _interleave(
    ytQuick.map(fromYt).toList(),
    tastePicks,
    limit: quickPickCount,
    maxPerArtist: 2,
  );
  final again = _interleave(
    ytAgain.map(fromYt).toList(),
    feed.jumpBackIn.where((t) => t.artworkUrl.isNotEmpty).toList(),
    limit: listenAgainCount,
    maxPerArtist: 3,
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
    personal: personal.take(maxPersonal).toList(),
    general: general.take(maxGeneral).toList(),
    artists: artists,
    hasYouTube: ytQuick.isNotEmpty ||
        ytAgain.isNotEmpty ||
        personal.isNotEmpty ||
        general.isNotEmpty,
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
