import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/lastfm_api.dart';
import '../../core/storage/app_database.dart';
import '../lastfm/auth_repository.dart';
import '../lastfm/home_repository.dart';
import '../search/shared_providers.dart';

/// One bar on the Genres page.
class GenreWeight {
  final String name;
  final int weight;
  const GenreWeight({required this.name, required this.weight});
}

class GenreChart {
  final List<GenreWeight> bars;

  /// True when the bars came from a Last.fm session. False means the
  /// play log and track names were the only source.
  final bool fromLastFm;

  const GenreChart({
    this.bars = const [],
    this.fromLastFm = false,
  });
}

/// Top genres for 7 days, 30 days, and all time.
///
/// A signed-in Last.fm session uses `user.getTopTags` (all time) and
/// `user.getTopArtists` plus `artist.getTopTags` (every period). Without
/// a session, plays in `local_plays` are scored by genre words in the
/// track and artist names.
class GenreSource {
  final LastFmApiService api;
  final HomeRepository home;
  final AppDatabase db;
  final String apiKey;
  final String username;

  GenreSource({
    required this.api,
    required this.home,
    required this.db,
    required this.apiKey,
    required this.username,
  });

  Future<GenreChart> load({
    required String period,
    required bool session,
  }) async {
    if (session && apiKey.isNotEmpty && username.isNotEmpty) {
      if (period == 'overall') {
        final direct = await _userTopTags();
        if (direct.isNotEmpty) {
          return GenreChart(bars: direct, fromLastFm: true);
        }
      }
      final aggregated = await _fromArtists(period);
      return GenreChart(bars: aggregated, fromLastFm: true);
    }
    return GenreChart(bars: _fromLocalPlays(period));
  }

  Future<List<GenreWeight>> _userTopTags() async {
    try {
      final json = await api.get({
        'method': 'user.getTopTags',
        'user': username,
        'api_key': apiKey,
        'limit': '20',
      }).timeout(const Duration(seconds: 12));
      if (json.containsKey('error')) return const [];
      return _ranked(_tagsOf(json));
    } catch (_) {
      return const [];
    }
  }

  Future<List<GenreWeight>> _fromArtists(String period) async {
    final artists = await home.fetchTopArtists(period: period, limit: 8);
    if (artists.isEmpty) return const [];
    final batches = await Future.wait(artists.map((artist) async {
      try {
        final json = await api.get({
          'method': 'artist.getTopTags',
          'artist': artist.name,
          'api_key': apiKey,
          'autocorrect': '1',
        }).timeout(const Duration(seconds: 8));
        if (json.containsKey('error')) {
          return (playCount: artist.playCount, tags: const <_Tag>[]);
        }
        return (playCount: artist.playCount, tags: _tagsOf(json));
      } catch (_) {
        return (playCount: artist.playCount, tags: const <_Tag>[]);
      }
    }));
    final scores = <String, int>{};
    final labels = <String, String>{};
    for (final batch in batches) {
      final tags = batch.tags.take(5).toList();
      final plays = batch.playCount <= 0 ? 1 : batch.playCount;
      for (var i = 0; i < tags.length; i++) {
        final key = _canon(tags[i].name);
        if (key.isEmpty) continue;
        final add = (plays / (i + 1)).round();
        if (add <= 0) continue;
        scores[key] = (scores[key] ?? 0) + add;
        labels.putIfAbsent(key, () => _pretty(tags[i].name));
      }
    }
    return _fromScores(scores, labels);
  }

  List<GenreWeight> _fromLocalPlays(String period) {
    final since = _cutoff(period);
    final scores = <String, int>{};
    final labels = <String, String>{};
    for (final play in db.loadRecentPlays(limit: 500)) {
      if (since != null &&
          (play.atMillis <= 0 || play.atMillis < since)) {
        continue;
      }
      final blob = '${play.title} ${play.artist}'.toLowerCase();
      if (blob.trim().isEmpty) continue;
      for (final genre in _localGenres) {
        if (!_mentions(blob, genre.needles)) continue;
        scores[genre.key] = (scores[genre.key] ?? 0) + 1;
        labels.putIfAbsent(genre.key, () => genre.label);
      }
    }
    return _fromScores(scores, labels);
  }

  List<GenreWeight> _ranked(List<_Tag> tags) {
    final scores = <String, int>{};
    final labels = <String, String>{};
    for (final tag in tags) {
      final key = _canon(tag.name);
      if (key.isEmpty || tag.count <= 0) continue;
      scores[key] = (scores[key] ?? 0) + tag.count;
      labels.putIfAbsent(key, () => _pretty(tag.name));
    }
    return _fromScores(scores, labels);
  }

  List<GenreWeight> _fromScores(
    Map<String, int> scores,
    Map<String, String> labels,
  ) {
    final rows = scores.entries
        .where((e) => e.value > 0 && isMusicGenreTag(e.key))
        .map((e) => GenreWeight(
              name: labels[e.key] ?? _pretty(e.key),
              weight: e.value,
            ))
        .toList()
      ..sort((a, b) => b.weight.compareTo(a.weight));
    return rows.take(12).toList();
  }
}

class _Tag {
  final String name;
  final int count;
  const _Tag(this.name, this.count);
}

List<_Tag> _tagsOf(Map<String, dynamic> json) {
  final root = json['toptags'];
  if (root is! Map) return const [];
  final raw = root['tag'];
  final maps = <Map>[];
  if (raw is List) {
    maps.addAll(raw.whereType<Map>());
  } else if (raw is Map) {
    maps.add(raw);
  }
  final out = <_Tag>[];
  for (final tag in maps) {
    final name = tag['name']?.toString().trim() ?? '';
    if (name.isEmpty) continue;
    final count = int.tryParse(tag['count']?.toString() ?? '') ?? 0;
    out.add(_Tag(name, count));
  }
  return out;
}

/// Last.fm tags include countries, languages, and one-off words
/// ("India", "Hindi", "Coke"). Those are not styles you can play.
bool isMusicGenreTag(String name) {
  final key = _canon(name);
  if (key.length < 2) return false;
  if (_junkTags.contains(key) || _placeTags.contains(key)) return false;
  if (RegExp(r'^(19|20)\d{2}s?$').hasMatch(key)) return false;
  if (RegExp(r'^\d+$').hasMatch(key)) return false;
  return true;
}

const _junkTags = {
  'seen live',
  'favorites',
  'favourite',
  'my music',
  'spotify',
  'youtube',
  'lastfm',
  'last.fm',
  'coke',
  'coca cola',
  'under 2000 listeners',
  'all',
  'music',
  'songs',
  'various',
  'misc',
  'other',
  'female vocalists',
  'male vocalists',
  'awesome',
  'cool',
  'love',
  'beautiful',
  'epic',
  'sexy',
  'fun',
  'sad',
  'happy',
  'chillout',
};

const _placeTags = {
  'india',
  'indian',
  'pakistan',
  'pakistani',
  'hindi',
  'punjabi',
  'usa',
  'american',
  'uk',
  'british',
  'england',
  'english',
  'canada',
  'canadian',
  'australia',
  'australian',
  'japan',
  'japanese',
  'korea',
  'korean',
  'china',
  'chinese',
  'france',
  'french',
  'germany',
  'german',
  'spain',
  'spanish',
  'brazil',
  'brazilian',
  'mexico',
  'mexican',
  'russia',
  'russian',
  'italy',
  'italian',
  'turkey',
  'turkish',
  'arabic',
  'africa',
  'african',
  'europe',
  'european',
  'asia',
  'asian',
  'bangladesh',
  'bangladeshi',
  'nepal',
  'nepali',
  'sri lanka',
  'tamil',
  'telugu',
  'marathi',
  'urdu',
};

String _canon(String name) {
  var key = name.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
  key = key.replaceAll('-', ' ');
  return switch (key) {
    'hiphop' || 'hip hop' => 'hip hop',
    'rnb' || 'r&b' || 'rhythm and blues' => 'r&b',
    'electronic dance music' || 'edm' => 'electronic',
    'lo fi' || 'lofi' || 'lo-fi' => 'lo-fi',
    _ => key,
  };
}

String _pretty(String name) {
  final key = _canon(name);
  const special = {
    'r&b': 'R&B',
    'edm': 'EDM',
    'lo-fi': 'Lo-fi',
    'k pop': 'K-Pop',
    'hip hop': 'Hip-Hop',
  };
  final known = special[key];
  if (known != null) return known;
  return key.split(' ').map((word) {
    if (word.isEmpty) return word;
    return word[0].toUpperCase() + word.substring(1);
  }).join(' ');
}

int? _cutoff(String period) {
  final days = switch (period) {
    '7day' => 7,
    '1month' => 30,
    _ => null,
  };
  if (days == null) return null;
  return DateTime.now().subtract(Duration(days: days)).millisecondsSinceEpoch;
}

bool _mentions(String blob, List<String> needles) {
  for (final needle in needles) {
    final pattern = RegExp('\\b${RegExp.escape(needle)}\\b');
    if (pattern.hasMatch(blob)) return true;
  }
  return false;
}

const _localGenres = <({String key, String label, List<String> needles})>[
  (key: 'hip hop', label: 'Hip-Hop', needles: ['hip hop', 'hip-hop', 'hiphop', 'rap', 'trap', 'drill']),
  (key: 'r&b', label: 'R&B', needles: ['r&b', 'rnb']),
  (key: 'rock', label: 'Rock', needles: ['rock', 'metal', 'punk', 'grunge']),
  (key: 'pop', label: 'Pop', needles: ['pop', 'k-pop', 'kpop']),
  (key: 'electronic', label: 'Electronic', needles: ['electronic', 'edm', 'house', 'techno', 'trance', 'dubstep']),
  (key: 'jazz', label: 'Jazz', needles: ['jazz']),
  (key: 'lo-fi', label: 'Lo-fi', needles: ['lofi', 'lo-fi', 'lo fi']),
  (key: 'classical', label: 'Classical', needles: ['classical', 'orchestra', 'piano']),
  (key: 'country', label: 'Country', needles: ['country']),
  (key: 'folk', label: 'Folk', needles: ['folk', 'acoustic']),
  (key: 'soul', label: 'Soul', needles: ['soul', 'funk', 'disco']),
  (key: 'reggae', label: 'Reggae', needles: ['reggae', 'dancehall']),
  (key: 'latin', label: 'Latin', needles: ['latin', 'reggaeton', 'salsa']),
  (key: 'blues', label: 'Blues', needles: ['blues']),
  (key: 'ambient', label: 'Ambient', needles: ['ambient', 'chill']),
  (key: 'indie', label: 'Indie', needles: ['indie']),
];

final genreChartProvider = FutureProvider.autoDispose
    .family<GenreChart, String>((ref, period) async {
  final auth = ref.watch(authRepositoryProvider);
  final apiKey = ref.watch(prefsApiKeyProvider);
  final session = auth.status == AuthStatus.signedIn &&
      auth.username.isNotEmpty &&
      apiKey.isNotEmpty;
  final source = GenreSource(
    api: ref.watch(lastFmApiProvider),
    home: ref.watch(homeRepositoryProvider),
    db: ref.watch(databaseProvider),
    apiKey: apiKey,
    username: auth.username,
  );
  return source.load(period: period, session: session);
});
