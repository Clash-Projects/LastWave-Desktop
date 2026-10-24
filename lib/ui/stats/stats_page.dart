import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/track_actions.dart' show playGenerated, relativeTime;
import '../../features/feed/feed_repository.dart';
import '../../features/stats/stats_providers.dart';
import '../components/artwork.dart';
import '../components/buttons.dart';
import '../components/states.dart';
import '../navigation/wave_nav.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// WaveStatsPage — Complete listening statistics, local metrics,
/// Last.fm cloud stats, top tracks & artists, listening streaks,
/// peak listening rhythm, and interactive activity charts.
class WaveStatsPage extends ConsumerWidget {
  const WaveStatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statsAsync = ref.watch(listeningStatsProvider);
    final activePeriod = ref.watch(statsPeriodProvider);
    final viewport = MediaQuery.sizeOf(context).width;

    final pad = viewport < 900 ? 16.0 : viewport < 1300 ? 24.0 : 28.0;
    final side =
        ((viewport - WaveDensity.contentMax) / 2).clamp(0, double.infinity) +
            pad;

    return WaveEntranceGroup(
      start: statsAsync.hasValue,
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(side, 22, side, 0),
            sliver: SliverToBoxAdapter(
              child: WaveEntrance(
                local: true,
                rise: 10,
                child: _StatsHeader(
                  activePeriod: activePeriod,
                  onPeriodChanged: (p) =>
                      ref.read(statsPeriodProvider.notifier).state = p,
                ),
              ),
            ),
          ),
          statsAsync.when(
            loading: () => SliverPadding(
              padding: EdgeInsets.fromLTRB(side, 24, side, 32),
              sliver: const SliverToBoxAdapter(
                child: WaveLoading(label: 'Calculating your statistics…'),
              ),
            ),
            error: (err, _) => SliverPadding(
              padding: EdgeInsets.fromLTRB(side, 24, side, 32),
              sliver: SliverToBoxAdapter(
                child: WaveError(
                  title: 'Could not load statistics',
                  message: '$err',
                  onRetry: () => ref.invalidate(listeningStatsProvider),
                ),
              ),
            ),
            data: (stats) {
              return _StatsContentSlivers(
                stats: stats,
                side: side,
                viewportWidth: viewport,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StatsHeader extends StatelessWidget {
  final StatsPeriod activePeriod;
  final ValueChanged<StatsPeriod> onPeriodChanged;

  const _StatsHeader({
    required this.activePeriod,
    required this.onPeriodChanged,
  });

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 640;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              WaveIcons.stats,
              size: 13,
              color: waveAccent(context),
            ),
            const SizedBox(width: 6),
            Text(
              'ANALYTICS & INSIGHTS',
              style: WaveType.overline.copyWith(
                color: waveAccent(context),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (narrow) ...[
          Text('Statistics',
              style: WaveType.pageTitle.copyWith(fontSize: 26)),
          const SizedBox(height: 4),
          Text(
            'Local playback metrics, Last.fm history, and musical trends.',
            style:
                WaveType.meta.copyWith(color: waveTextSecondary(context)),
          ),
          const SizedBox(height: 14),
          _PeriodSegmentedSwitch(
            activePeriod: activePeriod,
            onChanged: onPeriodChanged,
          ),
        ] else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Statistics',
                        style: WaveType.pageTitle.copyWith(fontSize: 26)),
                    const SizedBox(height: 4),
                    Text(
                      'Local playback metrics, Last.fm history, and musical trends.',
                      style: WaveType.meta
                          .copyWith(color: waveTextSecondary(context)),
                    ),
                  ],
                ),
              ),
              _PeriodSegmentedSwitch(
                activePeriod: activePeriod,
                onChanged: onPeriodChanged,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _PeriodSegmentedSwitch extends StatelessWidget {
  final StatsPeriod activePeriod;
  final ValueChanged<StatsPeriod> onChanged;

  const _PeriodSegmentedSwitch({
    required this.activePeriod,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: dark
            ? WaveColors.surfaceRaised
            : WaveColors.lightOutlineSoft,
        borderRadius: WaveRadius.controlsRadius,
        border: Border.all(
          color: waveDivider(context),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: StatsPeriod.values.map((p) {
          final isSelected = p == activePeriod;
          return GestureDetector(
            onTap: () => onChanged(p),
            child: AnimatedContainer(
              duration: waveMotion(context, WaveMotion.fast),
              curve: WaveMotion.standard,
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: isSelected
                    ? (dark
                        ? Colors.white.withValues(alpha: 0.16)
                        : Colors.white)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(WaveRadius.controls - 2),
                boxShadow: isSelected && !dark
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        )
                      ]
                    : null,
              ),
              child: Text(
                p.label,
                style: WaveType.label.copyWith(
                  fontSize: 12,
                  color: isSelected
                      ? waveTextPrimary(context)
                      : waveTextTertiary(context),
                  fontWeight:
                      isSelected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _StatsContentSlivers extends StatelessWidget {
  final ListeningStatsData stats;
  final double side;
  final double viewportWidth;

  const _StatsContentSlivers({
    required this.stats,
    required this.side,
    required this.viewportWidth,
  });

  @override
  Widget build(BuildContext context) {
    final twoColumns = viewportWidth >= 960;
    var slotIndex = 0;
    int nextSlot() => slotIndex++;

    return SliverPadding(
      padding: EdgeInsets.fromLTRB(side, 20, side, 40),
      sliver: SliverList(
        delegate: SliverChildListDelegate([
          // 1. Metric Cards Grid
          WaveEntrance(
            index: nextSlot(),
            rise: 8,
            child: _MetricsGrid(stats: stats, viewportWidth: viewportWidth),
          ),
          const SizedBox(height: 24),

          // 2. Visual Charts (Activity + 24-hr Rhythm)
          WaveEntrance(
            index: nextSlot(),
            rise: 10,
            child: _ChartsSection(
              stats: stats,
              twoColumns: twoColumns,
            ),
          ),
          const SizedBox(height: 28),

          // 3. Top Tracks and Top Artists Rankings
          WaveEntrance(
            index: nextSlot(),
            rise: 10,
            child: twoColumns
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _TopTracksCard(tracks: stats.topTracks),
                      ),
                      const SizedBox(width: 18),
                      Expanded(
                        child: _TopArtistsCard(artists: stats.topArtists),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      _TopTracksCard(tracks: stats.topTracks),
                      const SizedBox(height: 20),
                      _TopArtistsCard(artists: stats.topArtists),
                    ],
                  ),
          ),
          const SizedBox(height: 28),

          // 4. Recent Listening History
          WaveEntrance(
            index: nextSlot(),
            rise: 10,
            child: _RecentHistoryCard(recentPlays: stats.recentPlays),
          ),
          const SizedBox(height: 24),

          // 5. Last.fm Cloud Integration Card
          WaveEntrance(
            index: nextSlot(),
            rise: 10,
            child: _LastFmStatusCard(stats: stats),
          ),
        ]),
      ),
    );
  }
}

class _MetricsGrid extends StatelessWidget {
  final ListeningStatsData stats;
  final double viewportWidth;

  const _MetricsGrid({required this.stats, required this.viewportWidth});

  String _formatListeningTime(int totalMinutes) {
    if (totalMinutes < 60) {
      return '$totalMinutes mins';
    }
    final hours = totalMinutes ~/ 60;
    final mins = totalMinutes % 60;
    return mins > 0 ? '${hours}h ${mins}m' : '${hours}h';
  }

  @override
  Widget build(BuildContext context) {
    final cols = viewportWidth < 700 ? 2 : 4;
    final formatter = NumberFormat('#,###');

    final cards = [
      _MetricTile(
        icon: FluentIcons.stopwatch,
        accentColor: const Color(0xFF4FC3E8),
        title: 'Time Listened',
        value: _formatListeningTime(stats.totalMinutesListened),
        subtext: '~3.5 min/track avg',
      ),
      _MetricTile(
        icon: FluentIcons.play,
        accentColor: const Color(0xFF7BE3A8),
        title: 'Total Plays',
        value: formatter.format(stats.totalPlays),
        subtext: stats.isLastFmConnected
            ? '${formatter.format(stats.lastFmScrobbles)} Last.fm scrobbles'
            : '${stats.uniqueTracks} distinct songs',
      ),
      _MetricTile(
        icon: FluentIcons.speed_high,
        accentColor: const Color(0xFFE0A030),
        title: 'Listening Streak',
        value: '${stats.currentStreakDays} ${stats.currentStreakDays == 1 ? 'day' : 'days'}',
        subtext: stats.currentStreakDays > 0
            ? 'Momentum is strong!'
            : 'Listen today to start streak',
      ),
      _MetricTile(
        icon: (stats.peakListeningHour >= 6 && stats.peakListeningHour < 18)
            ? FluentIcons.sunny
            : FluentIcons.clear_night,
        accentColor: const Color(0xFF9B7BE3),
        title: 'Peak Listening',
        value: stats.peakListeningLabel,
        subtext: stats.peakListeningHour >= 22 || stats.peakListeningHour < 5
            ? 'Late night sessions'
            : (stats.peakListeningHour < 12
                ? 'Morning energy'
                : 'Evening groove'),
      ),
    ];

    return LayoutBuilder(builder: (context, constraints) {
      final width = (constraints.maxWidth - (cols - 1) * 12) / cols;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: cards
            .map((c) => SizedBox(width: width, child: c))
            .toList(),
      );
    });
  }
}

class _MetricTile extends StatelessWidget {
  final IconData icon;
  final Color accentColor;
  final String title;
  final String value;
  final String subtext;

  const _MetricTile({
    required this.icon,
    required this.accentColor,
    required this.title,
    required this.value,
    required this.subtext,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: dark ? WaveColors.surface : WaveColors.lightSurface,
        borderRadius: WaveRadius.floatingRadius,
        border: Border.all(
          color: waveDivider(context),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.14),
                  borderRadius: WaveRadius.controlsRadius,
                ),
                child: Icon(icon, size: 15, color: accentColor),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: WaveType.overline.copyWith(
                    fontSize: 9.5,
                    color: waveTextTertiary(context),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: WaveType.numeral.copyWith(
              fontSize: 22,
              color: waveTextPrimary(context),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtext,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: WaveType.meta.copyWith(
              fontSize: 11,
              color: waveTextSecondary(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChartsSection extends StatelessWidget {
  final ListeningStatsData stats;
  final bool twoColumns;

  const _ChartsSection({
    required this.stats,
    required this.twoColumns,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);

    final activityCard = Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: dark ? WaveColors.surface : WaveColors.lightSurface,
        borderRadius: WaveRadius.floatingRadius,
        border: Border.all(color: waveDivider(context), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(FluentIcons.b_i_dashboard,
                  size: 14, color: waveAccent(context)),
              const SizedBox(width: 8),
              Text('Daily Activity (Last 14 Days)',
                  style: WaveType.sectionTitle.copyWith(fontSize: 14)),
              const Spacer(),
              Text(
                '${stats.dailyActivity.fold(0, (acc, e) => acc + e.count)} total plays',
                style: WaveType.meta
                    .copyWith(color: waveTextTertiary(context)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _DailyActivityBarChart(activity: stats.dailyActivity),
        ],
      ),
    );

    final rhythmCard = Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: dark ? WaveColors.surface : WaveColors.lightSurface,
        borderRadius: WaveRadius.floatingRadius,
        border: Border.all(color: waveDivider(context), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(FluentIcons.clock,
                  size: 14, color: const Color(0xFF9B7BE3)),
              const SizedBox(width: 8),
              Text('24-Hour Rhythm',
                  style: WaveType.sectionTitle.copyWith(fontSize: 14)),
              const Spacer(),
              Text('Peak: ${stats.peakListeningLabel}',
                  style: WaveType.meta.copyWith(
                    color: const Color(0xFF9B7BE3),
                    fontWeight: FontWeight.w600,
                  )),
            ],
          ),
          const SizedBox(height: 16),
          _HourlyDistributionChart(
            hourly: stats.hourlyDistribution,
            peakHour: stats.peakListeningHour,
          ),
        ],
      ),
    );

    if (twoColumns) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: activityCard),
          const SizedBox(width: 18),
          Expanded(flex: 2, child: rhythmCard),
        ],
      );
    }

    return Column(
      children: [
        activityCard,
        const SizedBox(height: 18),
        rhythmCard,
      ],
    );
  }
}

class _DailyActivityBarChart extends StatelessWidget {
  final List<({String date, int count})> activity;
  const _DailyActivityBarChart({required this.activity});

  @override
  Widget build(BuildContext context) {
    if (activity.isEmpty) {
      return Container(
        height: 110,
        alignment: Alignment.center,
        child: Text(
          'Start listening to build your daily activity history.',
          style: WaveType.meta.copyWith(color: waveTextTertiary(context)),
        ),
      );
    }

    final maxCount = math.max(
      1,
      activity.fold(0, (prev, e) => math.max(prev, e.count)),
    );

    return SizedBox(
      height: 110,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: activity.map((item) {
          final ratio = (item.count / maxCount).clamp(0.06, 1.0);
          final parsedDate = DateTime.tryParse(item.date);
          final dayLabel = parsedDate != null
              ? DateFormat('E').format(parsedDate).substring(0, 1)
              : '';
          final isToday = parsedDate != null &&
              DateFormat('yyyy-MM-dd').format(DateTime.now()) == item.date;

          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2.5),
              child: Tooltip(
                message: '${item.count} plays on ${item.date}',
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      item.count > 0 ? '${item.count}' : '',
                      style: WaveType.overline.copyWith(
                        fontSize: 8.5,
                        color: waveTextTertiary(context),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Expanded(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: FractionallySizedBox(
                          heightFactor: ratio,
                          child: Container(
                            decoration: BoxDecoration(
                              color: isToday
                                  ? const Color(0xFF7BE3A8)
                                  : (item.count > 0
                                      ? waveAccent(context).withValues(alpha: 0.75)
                                      : waveDivider(context).withValues(alpha: 0.3)),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      dayLabel,
                      style: WaveType.label.copyWith(
                        fontSize: 9.5,
                        color: isToday
                            ? waveTextPrimary(context)
                            : waveTextTertiary(context),
                        fontWeight:
                            isToday ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _HourlyDistributionChart extends StatelessWidget {
  final Map<int, int> hourly;
  final int peakHour;

  const _HourlyDistributionChart({
    required this.hourly,
    required this.peakHour,
  });

  @override
  Widget build(BuildContext context) {
    final maxHr = math.max(
      1,
      hourly.values.fold(0, (prev, c) => math.max(prev, c)),
    );

    return Column(
      children: [
        SizedBox(
          height: 80,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(24, (hr) {
              final count = hourly[hr] ?? 0;
              final ratio = (count / maxHr).clamp(0.08, 1.0);
              final isPeak = hr == peakHour && count > 0;

              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Tooltip(
                    message: '$count plays around $hr:00',
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: ratio,
                        child: Container(
                          decoration: BoxDecoration(
                            color: isPeak
                                ? const Color(0xFF9B7BE3)
                                : (count > 0
                                    ? waveTextSecondary(context)
                                        .withValues(alpha: 0.6)
                                    : waveDivider(context)
                                        .withValues(alpha: 0.2)),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('12 AM',
                style: WaveType.overline.copyWith(
                    fontSize: 8.5, color: waveTextTertiary(context))),
            Text('6 AM',
                style: WaveType.overline.copyWith(
                    fontSize: 8.5, color: waveTextTertiary(context))),
            Text('12 PM',
                style: WaveType.overline.copyWith(
                    fontSize: 8.5, color: waveTextTertiary(context))),
            Text('6 PM',
                style: WaveType.overline.copyWith(
                    fontSize: 8.5, color: waveTextTertiary(context))),
            Text('11 PM',
                style: WaveType.overline.copyWith(
                    fontSize: 8.5, color: waveTextTertiary(context))),
          ],
        ),
      ],
    );
  }
}

class _TopTracksCard extends ConsumerWidget {
  final List<StatTrack> tracks;
  const _TopTracksCard({required this.tracks});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: dark ? WaveColors.surface : WaveColors.lightSurface,
        borderRadius: WaveRadius.floatingRadius,
        border: Border.all(color: waveDivider(context), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(FluentIcons.music_in_collection,
                  size: 14, color: waveAccent(context)),
              const SizedBox(width: 8),
              Text('Top Tracks', style: WaveType.sectionTitle),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: dark
                      ? WaveColors.surfaceRaised
                      : WaveColors.lightOutlineSoft,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text('${tracks.length} ranked',
                    style: WaveType.overline.copyWith(
                      fontSize: 9.5,
                      color: waveTextSecondary(context),
                    )),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (tracks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  'No tracks played in this period.',
                  style: WaveType.meta
                      .copyWith(color: waveTextSecondary(context)),
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: tracks.take(10).length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, i) {
                final track = tracks[i];
                final rank = i + 1;
                return _TopTrackRow(track: track, rank: rank);
              },
            ),
        ],
      ),
    );
  }
}

class _TopTrackRow extends ConsumerWidget {
  final StatTrack track;
  final int rank;

  const _TopTrackRow({required this.track, required this.rank});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isTop3 = rank <= 3;
    final rankColor = rank == 1
        ? const Color(0xFFFFD700)
        : (rank == 2
            ? const Color(0xFFC0C0C0)
            : (rank == 3
                ? const Color(0xFFCD7F32)
                : waveTextTertiary(context)));

    return WavePressable(
      onTap: () {
        playGenerated(
          ref,
          context,
          GeneratedTrack(
            name: track.name,
            artist: track.artist,
            artworkUrl: track.artworkUrl,
          ),
          sourceLabel: 'Top Tracks',
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: WaveRadius.controlsRadius,
          color: Colors.transparent,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '$rank',
                style: WaveType.label.copyWith(
                  fontSize: 12,
                  color: rankColor,
                  fontWeight:
                      isTop3 ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
            WaveArtwork(
              url: track.artworkUrl,
              size: 38,
              radius: WaveRadius.tiny,
              title: track.name,
              artist: track.artist,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.trackTitle.copyWith(fontSize: 13),
                  ),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WaveType.meta.copyWith(
                      fontSize: 11.5,
                      color: waveTextSecondary(context),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: waveAccent(context).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '${track.playCount} ${track.playCount == 1 ? 'play' : 'plays'}',
                style: WaveType.label.copyWith(
                  fontSize: 11,
                  color: waveAccent(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopArtistsCard extends StatelessWidget {
  final List<StatArtist> artists;
  const _TopArtistsCard({required this.artists});

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: dark ? WaveColors.surface : WaveColors.lightSurface,
        borderRadius: WaveRadius.floatingRadius,
        border: Border.all(color: waveDivider(context), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(FluentIcons.microphone,
                  size: 14, color: waveAccent(context)),
              const SizedBox(width: 8),
              Text('Top Artists', style: WaveType.sectionTitle),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: dark
                      ? WaveColors.surfaceRaised
                      : WaveColors.lightOutlineSoft,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text('${artists.length} artists',
                    style: WaveType.overline.copyWith(
                      fontSize: 9.5,
                      color: waveTextSecondary(context),
                    )),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (artists.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  'No artists recorded in this period.',
                  style: WaveType.meta
                      .copyWith(color: waveTextSecondary(context)),
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: artists.take(10).length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, i) {
                final artist = artists[i];
                final rank = i + 1;
                return _TopArtistRow(artist: artist, rank: rank);
              },
            ),
        ],
      ),
    );
  }
}

class _TopArtistRow extends StatelessWidget {
  final StatArtist artist;
  final int rank;

  const _TopArtistRow({required this.artist, required this.rank});

  @override
  Widget build(BuildContext context) {
    final isTop3 = rank <= 3;
    final rankColor = rank == 1
        ? const Color(0xFFFFD700)
        : (rank == 2
            ? const Color(0xFFC0C0C0)
            : (rank == 3
                ? const Color(0xFFCD7F32)
                : waveTextTertiary(context)));

    return WavePressable(
      onTap: () {
        waveOpen(context, '/artist/${Uri.encodeComponent(artist.name)}');
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: WaveRadius.controlsRadius,
          color: Colors.transparent,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '$rank',
                style: WaveType.label.copyWith(
                  fontSize: 12,
                  color: rankColor,
                  fontWeight:
                      isTop3 ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
            ClipOval(
              child: WaveArtwork(
                url: artist.artworkUrl,
                size: 38,
                kind: ArtworkKind.artist,
                title: artist.name,
                artist: artist.name,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.trackTitle.copyWith(fontSize: 13),
              ),
            ),
            const SizedBox(width: 10),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: waveAccent(context).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '${artist.playCount} ${artist.playCount == 1 ? 'play' : 'plays'}',
                style: WaveType.label.copyWith(
                  fontSize: 11,
                  color: waveAccent(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentHistoryCard extends ConsumerWidget {
  final List<({String title, String artist, int timestampMillis})> recentPlays;
  const _RecentHistoryCard({required this.recentPlays});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: dark ? WaveColors.surface : WaveColors.lightSurface,
        borderRadius: WaveRadius.floatingRadius,
        border: Border.all(color: waveDivider(context), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(FluentIcons.history,
                  size: 14, color: waveAccent(context)),
              const SizedBox(width: 8),
              Text('Recent Play History', style: WaveType.sectionTitle),
              const Spacer(),
              GestureDetector(
                onTap: () => context.go('/history'),
                child: Text(
                  'Full history',
                  style: WaveType.label.copyWith(
                    color: waveAccent(context),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (recentPlays.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  'No recent playback history yet.',
                  style: WaveType.meta
                      .copyWith(color: waveTextSecondary(context)),
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: recentPlays.take(8).length,
              separatorBuilder: (_, _) => const SizedBox(height: 2),
              itemBuilder: (context, i) {
                final item = recentPlays[i];
                return WavePressable(
                  onTap: () {
                    playGenerated(
                      ref,
                      context,
                      GeneratedTrack(
                        name: item.title,
                        artist: item.artist,
                      ),
                      sourceLabel: 'History',
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 7),
                    child: Row(
                      children: [
                        Icon(FluentIcons.music_note,
                            size: 14, color: waveTextTertiary(context)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: WaveType.trackTitle
                                    .copyWith(fontSize: 12.5),
                              ),
                              Text(
                                item.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: WaveType.meta.copyWith(
                                  fontSize: 11,
                                  color: waveTextSecondary(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          relativeTime(DateTime.fromMillisecondsSinceEpoch(
                              item.timestampMillis)),
                          style: WaveType.meta.copyWith(
                            fontSize: 11,
                            color: waveTextTertiary(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _LastFmStatusCard extends StatelessWidget {
  final ListeningStatsData stats;
  const _LastFmStatusCard({required this.stats});

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final isConnected = stats.isLastFmConnected;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: dark ? WaveColors.surfaceRaised : WaveColors.lightSurface,
        borderRadius: WaveRadius.floatingRadius,
        border: Border.all(
          color: isConnected
              ? const Color(0xFFE0506A).withValues(alpha: 0.3)
              : waveDivider(context),
          width: 0.8,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFE0506A).withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              FluentIcons.favorite_star,
              color: Color(0xFFE0506A),
              size: 20,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      isConnected
                          ? 'Last.fm Connected'
                          : 'Sync with Last.fm',
                      style: WaveType.sectionTitle.copyWith(fontSize: 14),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: isConnected
                            ? const Color(0xFF7BE3A8).withValues(alpha: 0.15)
                            : waveDivider(context),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        isConnected ? 'SYNCED' : 'OFFLINE',
                        style: WaveType.overline.copyWith(
                          fontSize: 8.5,
                          color: isConnected
                              ? const Color(0xFF7BE3A8)
                              : waveTextTertiary(context),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  isConnected
                      ? 'Scrobbling as @${stats.lastFmUsername} with ${NumberFormat('#,###').format(stats.lastFmScrobbles)} scrobbles on record.'
                      : 'Connect Last.fm in Settings to scrobble every play, access global charts, and keep cross-device stats.',
                  style: WaveType.meta.copyWith(
                    fontSize: 12,
                    color: waveTextSecondary(context),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          WaveGhostButton(
            label: isConnected ? 'Last.fm Settings' : 'Connect Account',
            icon: FluentIcons.settings,
            onPressed: () => context.go('/settings?section=lastfm'),
          ),
        ],
      ),
    );
  }
}
