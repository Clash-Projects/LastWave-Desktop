import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/artwork/official_artwork_service.dart';
import '../../core/audio/artist_parser.dart';
import '../search/shared_providers.dart';

enum StatsPeriod {
  week('7 Days', 7, '7day'),
  month('30 Days', 30, '1month'),
  allTime('All Time', null, 'overall');

  final String label;
  final int? days;
  final String lastFmPeriod;
  const StatsPeriod(this.label, this.days, this.lastFmPeriod);
}

class StatTrack {
  final String name;
  final String artist;
  final String artworkUrl;
  final int playCount;
  final int? timestampMillis;

  const StatTrack({
    required this.name,
    required this.artist,
    this.artworkUrl = '',
    required this.playCount,
    this.timestampMillis,
  });
}

class StatArtist {
  final String name;
  final int playCount;
  final String artworkUrl;

  const StatArtist({
    required this.name,
    required this.playCount,
    this.artworkUrl = '',
  });
}

class StatAlbum {
  final String name;
  final String artist;
  final String artworkUrl;
  final int playCount;

  const StatAlbum({
    required this.name,
    required this.artist,
    this.artworkUrl = '',
    required this.playCount,
  });
}

class ListeningStatsData {
  final StatsPeriod period;
  final int totalPlays;
  final int totalMinutesListened;
  final bool hasEstimatedDuration;
  final int? prevPeriodPlays;
  final int? prevPeriodMinutesListened;
  final int uniqueArtists;
  final int uniqueTracks;
  final int currentStreakDays;
  final int peakListeningHour;
  final String peakListeningLabel;
  final List<StatArtist> topArtists;
  final List<StatTrack> topTracks;
  final List<StatAlbum> topAlbums;
  final List<({String title, String artist, int timestampMillis, String artworkUrl})> recentPlays;
  final Map<int, int> hourlyDistribution;
  final List<({String date, int count})> dailyActivity;
  final bool isLastFmConnected;
  final String lastFmUsername;
  final String scrobblerName;
  final int lastFmScrobbles;
  final int lastFmArtistsCount;
  final int lastFmAlbumsCount;
  final int lastFmTracksCount;
  final String lastFmAvatarUrl;

  const ListeningStatsData({
    required this.period,
    required this.totalPlays,
    required this.totalMinutesListened,
    this.hasEstimatedDuration = false,
    this.prevPeriodPlays,
    this.prevPeriodMinutesListened,
    required this.uniqueArtists,
    required this.uniqueTracks,
    required this.currentStreakDays,
    required this.peakListeningHour,
    required this.peakListeningLabel,
    required this.topArtists,
    required this.topTracks,
    required this.topAlbums,
    required this.recentPlays,
    required this.hourlyDistribution,
    required this.dailyActivity,
    required this.isLastFmConnected,
    required this.lastFmUsername,
    this.scrobblerName = '',
    required this.lastFmScrobbles,
    required this.lastFmArtistsCount,
    required this.lastFmAlbumsCount,
    required this.lastFmTracksCount,
    required this.lastFmAvatarUrl,
  });
}

final statsPeriodProvider = StateProvider<StatsPeriod>((ref) => StatsPeriod.week);

final listeningStatsProvider = FutureProvider<ListeningStatsData>((ref) async {
  final period = ref.watch(statsPeriodProvider);
  final db = ref.watch(databaseProvider);

  final now = DateTime.now();
  int? sinceMillis;
  int? prevSinceMillis;
  if (period.days != null) {
    sinceMillis =
        now.subtract(Duration(days: period.days!)).millisecondsSinceEpoch;
    prevSinceMillis =
        now.subtract(Duration(days: period.days! * 2)).millisecondsSinceEpoch;
  }

  // 100% Local SQLite Stats (scrobblers are outbound-only and never reset stats).
  final local = db.getLocalStatsSummary(
    sinceMillis: sinceMillis,
    prevSinceMillis: prevSinceMillis,
  );
  final localTotalPlays = (local['totalPlays'] as int?) ?? 0;
  final localDurationMs = (local['totalDurationMs'] as int?) ?? 0;
  final unmeasuredPlays = (local['unmeasuredPlays'] as int?) ?? 0;
  final prevPeriodPlays = local['prevPlays'] as int?;
  final prevDurationMs = (local['prevDurationMs'] as int?) ?? 0;
  final prevUnmeasuredPlays = (local['prevUnmeasuredPlays'] as int?) ?? 0;
  final localUniqueArtists = (local['uniqueArtists'] as int?) ?? 0;
  final localUniqueTracks = (local['uniqueTracks'] as int?) ?? 0;
  final localHourly = (local['hourly'] as Map<int, int>?) ?? {};
  final localDaily = (local['daily'] as List<({String date, int count})>?) ?? [];
  final rawLocalTopArtists =
      (local['topArtists'] as List<({String name, int count})>?) ?? [];
  final rawLocalTopTracks =
      (local['topTracks'] as List<({String title, String artist, int count})>?) ??
          [];
  final rawLocalTopAlbums =
      (local['topAlbums'] as List<({String name, String artist, int count})>?) ??
          [];

  final localRecent = db
      .loadRecentPlays(limit: 200, sinceMillis: sinceMillis)
      .map((p) {
    final peek = OfficialArtworkService.instance.peekTrack(
      title: p.title,
      artist: p.artist,
    );
    return (
      title: p.title,
      artist: p.artist,
      timestampMillis: p.atMillis,
      artworkUrl: peek?.artworkUrl ?? '',
    );
  }).toList();

  // Streak Calculation from all local play dates.
  final activeDates = db.loadActivePlayDates();

  var streak = 0;
  var cursor = DateTime.now();
  final todayStr = DateFormat('yyyy-MM-dd').format(cursor);
  if (!activeDates.contains(todayStr)) {
    cursor = cursor.subtract(const Duration(days: 1));
  }
  while (true) {
    final dayStr = DateFormat('yyyy-MM-dd').format(cursor);
    if (activeDates.contains(dayStr)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    } else {
      break;
    }
  }

  // Peak Listening Hour
  var peakHour = 20;
  var maxHourCount = 0;
  localHourly.forEach((hr, count) {
    if (count > maxHourCount) {
      maxHourCount = count;
      peakHour = hr;
    }
  });

  String formatHour(int hour) {
    final periodStr = hour >= 12 ? 'PM' : 'AM';
    final h12 = hour % 12 == 0 ? 12 : hour % 12;
    return '$h12:00 $periodStr';
  }

  final peakLabel = maxHourCount > 0 ? formatHour(peakHour) : '—';

  // Top Tracks with local artwork cache peek.
  final mergedTopTracks = <StatTrack>[
    for (final t in rawLocalTopTracks)
      StatTrack(
        name: t.title,
        artist: t.artist,
        artworkUrl: OfficialArtworkService.instance
                .peekTrack(title: t.title, artist: t.artist)
                ?.artworkUrl ??
            '',
        playCount: t.count,
      ),
  ];

  // Top Artists (break collaborations into individual artists).
  final artistCountMap = <String, int>{};
  for (final a in rawLocalTopArtists) {
    for (final single in splitArtistCredits(a.name)) {
      artistCountMap[single] = (artistCountMap[single] ?? 0) + a.count;
    }
  }

  final sortedArtists = artistCountMap.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  final mergedTopArtists = sortedArtists.take(100).map((e) {
    final peek = OfficialArtworkService.instance.peekArtist(e.key);
    return StatArtist(
      name: e.key,
      playCount: e.value,
      artworkUrl: peek?.artworkUrl ?? '',
    );
  }).toList();

  // Top Albums: recorded local album column, falling back to cached track
  // metadata for older plays recorded before the album column existed.
  final albumCounts = <String, ({String name, String artist, int count})>{};
  for (final a in rawLocalTopAlbums) {
    final key = '${a.name.toLowerCase()}|${a.artist.toLowerCase()}';
    final prev = albumCounts[key];
    albumCounts[key] = (
      name: a.name,
      artist: a.artist,
      count: (prev?.count ?? 0) + a.count,
    );
  }
  if (albumCounts.isEmpty) {
    for (final t in rawLocalTopTracks) {
      final peek = OfficialArtworkService.instance.peekTrack(
        title: t.title,
        artist: t.artist,
      );
      final albumTitle = peek?.albumTitle.trim() ?? '';
      if (albumTitle.isEmpty) continue;
      final key = '${albumTitle.toLowerCase()}|${t.artist.toLowerCase()}';
      final prev = albumCounts[key];
      albumCounts[key] = (
        name: albumTitle,
        artist: t.artist,
        count: (prev?.count ?? 0) + t.count,
      );
    }
  }
  final sortedAlbums = albumCounts.values.toList()
    ..sort((a, b) => b.count.compareTo(a.count));
  final mergedTopAlbums = sortedAlbums.take(100).map((a) {
    final peek = OfficialArtworkService.instance.peekAlbum(
      album: a.name,
      artist: a.artist,
    );
    return StatAlbum(
      name: a.name,
      artist: a.artist,
      artworkUrl: peek?.artworkUrl ?? '',
      playCount: a.count,
    );
  }).toList();

  // Prefer actual recorded track durations; legacy rows without duration_ms
  // fall back to 3.5 minutes per play.
  const fallbackMsPerPlay = 210000;
  final totalMinutes =
      ((localDurationMs + unmeasuredPlays * fallbackMsPerPlay) / 60000).round();
  final prevTotalMinutes = prevPeriodPlays == null
      ? null
      : ((prevDurationMs + prevUnmeasuredPlays * fallbackMsPerPlay) / 60000)
          .round();

  return ListeningStatsData(
    period: period,
    totalPlays: localTotalPlays,
    totalMinutesListened: totalMinutes,
    hasEstimatedDuration: unmeasuredPlays > 0,
    prevPeriodPlays: prevPeriodPlays,
    prevPeriodMinutesListened: prevTotalMinutes,
    uniqueArtists: localUniqueArtists,
    uniqueTracks: localUniqueTracks,
    currentStreakDays: streak,
    peakListeningHour: peakHour,
    peakListeningLabel: peakLabel,
    topArtists: mergedTopArtists,
    topTracks: mergedTopTracks,
    topAlbums: mergedTopAlbums,
    recentPlays: localRecent,
    hourlyDistribution: localHourly,
    dailyActivity: localDaily,
    isLastFmConnected: false,
    lastFmUsername: '',
    scrobblerName: '',
    lastFmScrobbles: 0,
    lastFmArtistsCount: 0,
    lastFmAlbumsCount: 0,
    lastFmTracksCount: 0,
    lastFmAvatarUrl: '',
  );
});
