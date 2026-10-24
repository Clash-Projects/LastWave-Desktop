import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../lastfm/auth_repository.dart';
import '../lastfm/home_repository.dart';
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

class ListeningStatsData {
  final StatsPeriod period;
  final int totalPlays;
  final int totalMinutesListened;
  final int uniqueArtists;
  final int uniqueTracks;
  final int currentStreakDays;
  final int peakListeningHour;
  final String peakListeningLabel;
  final List<StatArtist> topArtists;
  final List<StatTrack> topTracks;
  final List<({String title, String artist, int timestampMillis})> recentPlays;
  final Map<int, int> hourlyDistribution;
  final List<({String date, int count})> dailyActivity;
  final bool isLastFmConnected;
  final String lastFmUsername;
  final int lastFmScrobbles;
  final String lastFmAvatarUrl;

  const ListeningStatsData({
    required this.period,
    required this.totalPlays,
    required this.totalMinutesListened,
    required this.uniqueArtists,
    required this.uniqueTracks,
    required this.currentStreakDays,
    required this.peakListeningHour,
    required this.peakListeningLabel,
    required this.topArtists,
    required this.topTracks,
    required this.recentPlays,
    required this.hourlyDistribution,
    required this.dailyActivity,
    required this.isLastFmConnected,
    required this.lastFmUsername,
    required this.lastFmScrobbles,
    required this.lastFmAvatarUrl,
  });
}

final statsPeriodProvider = StateProvider<StatsPeriod>((ref) => StatsPeriod.week);

final listeningStatsProvider = FutureProvider<ListeningStatsData>((ref) async {
  final period = ref.watch(statsPeriodProvider);
  final db = ref.watch(databaseProvider);
  final homeRepo = ref.watch(homeRepositoryProvider);
  final auth = ref.watch(authRepositoryProvider);

  int? sinceMillis;
  if (period.days != null) {
    sinceMillis =
        DateTime.now().subtract(Duration(days: period.days!)).millisecondsSinceEpoch;
  }

  // 1. Fetch Local SQLite Stats
  final local = db.getLocalStatsSummary(sinceMillis: sinceMillis);
  final localTotalPlays = (local['totalPlays'] as int?) ?? 0;
  final localUniqueArtists = (local['uniqueArtists'] as int?) ?? 0;
  final localUniqueTracks = (local['uniqueTracks'] as int?) ?? 0;
  final localHourly = (local['hourly'] as Map<int, int>?) ?? {};
  final localDaily = (local['daily'] as List<({String date, int count})>?) ?? [];
  final rawLocalTopArtists =
      (local['topArtists'] as List<({String name, int count})>?) ?? [];
  final rawLocalTopTracks =
      (local['topTracks'] as List<({String title, String artist, int count})>?) ??
          [];

  final localRecent = db.loadRecentPlays(limit: 50).map((p) => (
        title: p.title,
        artist: p.artist,
        timestampMillis: p.atMillis,
      )).toList();

  // Streak Calculation from local plays
  final allPlays = db.loadRecentPlays(limit: 500);
  final activeDates = <String>{};
  for (final p in allPlays) {
    final dt = DateTime.fromMillisecondsSinceEpoch(p.atMillis);
    activeDates.add(DateFormat('yyyy-MM-dd').format(dt));
  }

  var streak = 0;
  var cursor = DateTime.now();
  final todayStr = DateFormat('yyyy-MM-dd').format(cursor);
  if (!activeDates.contains(todayStr)) {
    // If not listened yet today, check if listened yesterday
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
  var maxHourCount = -1;
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

  // 2. Fetch Last.fm Data if Signed In
  var isLastFm = false;
  var lastFmUser = '';
  var lastFmScrobbles = 0;
  var lastFmAvatar = '';
  List<HomeTrack> lastFmTopTracks = const [];
  List<({String name, int playCount, String artworkUrl})> lastFmTopArtists =
      const [];

  if (auth.status == AuthStatus.signedIn && auth.username.isNotEmpty) {
    isLastFm = true;
    lastFmUser = auth.username;
    try {
      final statsFuture = homeRepo.fetchStats();
      final topTracksFuture = homeRepo.fetchTopTracks(
        period: period.lastFmPeriod,
        limit: 15,
      );
      final topArtistsFuture = homeRepo.fetchTopArtists(
        period: period.lastFmPeriod,
        limit: 15,
      );

      final results = await Future.wait([
        statsFuture,
        topTracksFuture,
        topArtistsFuture,
      ]);

      final stats = results[0] as HomeStats;
      lastFmScrobbles = stats.scrobbles;
      lastFmAvatar = stats.avatarUrl;
      lastFmTopTracks = results[1] as List<HomeTrack>;
      lastFmTopArtists =
          results[2] as List<({String name, int playCount, String artworkUrl})>;
    } catch (_) {}
  }

  // 3. Merge & Prioritize Top Tracks & Artists
  final mergedTopTracks = <StatTrack>[];
  if (isLastFm && lastFmTopTracks.isNotEmpty) {
    for (final t in lastFmTopTracks) {
      mergedTopTracks.add(StatTrack(
        name: t.name,
        artist: t.artist,
        artworkUrl: t.artworkUrl,
        playCount: t.playCount,
        timestampMillis: t.timestampMillis,
      ));
    }
  } else {
    for (final t in rawLocalTopTracks) {
      mergedTopTracks.add(StatTrack(
        name: t.title,
        artist: t.artist,
        playCount: t.count,
      ));
    }
  }

  final mergedTopArtists = <StatArtist>[];
  if (isLastFm && lastFmTopArtists.isNotEmpty) {
    for (final a in lastFmTopArtists) {
      mergedTopArtists.add(StatArtist(
        name: a.name,
        playCount: a.playCount,
        artworkUrl: a.artworkUrl,
      ));
    }
  } else {
    for (final a in rawLocalTopArtists) {
      mergedTopArtists.add(StatArtist(
        name: a.name,
        playCount: a.count,
      ));
    }
  }

  // Estimate total listening minutes (~3.5 minutes per play on average)
  final effectivePlays = isLastFm && period == StatsPeriod.allTime && lastFmScrobbles > localTotalPlays
      ? lastFmScrobbles
      : localTotalPlays;
  final totalMinutes = (effectivePlays * 3.5).round();

  return ListeningStatsData(
    period: period,
    totalPlays: effectivePlays,
    totalMinutesListened: totalMinutes,
    uniqueArtists: localUniqueArtists,
    uniqueTracks: localUniqueTracks,
    currentStreakDays: streak,
    peakListeningHour: peakHour,
    peakListeningLabel: formatHour(peakHour),
    topArtists: mergedTopArtists,
    topTracks: mergedTopTracks,
    recentPlays: localRecent,
    hourlyDistribution: localHourly,
    dailyActivity: localDaily,
    isLastFmConnected: isLastFm,
    lastFmUsername: lastFmUser,
    lastFmScrobbles: lastFmScrobbles,
    lastFmAvatarUrl: lastFmAvatar,
  );
});
