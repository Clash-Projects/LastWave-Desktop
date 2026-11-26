import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/track_actions.dart' show playGenerated, relativeTime;
import '../../core/artwork/official_artwork_service.dart';
import '../../features/feed/feed_repository.dart';
import '../../features/feed/genre_source.dart';
import '../../features/innertube/album_match.dart';
import '../../features/innertube/innertube_api.dart' show innerTubeProvider;
import '../../features/search/shared_providers.dart' show databaseProvider;
import '../../features/stats/stats_providers.dart';
import '../genres/genres_page.dart';
import '../components/artist_line.dart';
import '../components/artwork.dart';
import '../components/buttons.dart';
import '../components/menus.dart' show WaveContextMenu, waveTrackMenuItems;
import '../components/shelf.dart' show LWSectionHeader;
import '../components/states.dart';
import '../navigation/wave_nav.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

enum StatsViewTab {
  overview('Overview', FluentIcons.b_i_dashboard),
  tracks('Top Tracks', FluentIcons.music_in_collection),
  artists('Top Artists', FluentIcons.microphone),
  albums('Top Albums', WaveIcons.albums),
  history('History', WaveIcons.history),
  genres('Genres', WaveIcons.genres);

  final String label;
  final IconData icon;
  const StatsViewTab(this.label, this.icon);
}

final _statsTabProvider =
    StateProvider.autoDispose<StatsViewTab>((ref) => StatsViewTab.overview);

/// WaveStatsPage — listening statistics, kept deliberately quiet.
///
/// Hierarchy: title + period + refresh, tabs, a one-line Last.fm strip, then
/// the tab body. Overview = three period-scoped metric tiles (each names its
/// window), two on-device activity charts, and Top Tracks / Top Artists /
/// Recently played previews. Every section is a [_StatsCard]; one accent
/// colour; rank badges keep their gold / silver / bronze.
class WaveStatsPage extends ConsumerWidget {
  const WaveStatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statsAsync = ref.watch(listeningStatsProvider);
    final activePeriod = ref.watch(statsPeriodProvider);
    final activeTab = ref.watch(_statsTabProvider);
    final genreCount = ref
        .watch(genreChartProvider(activePeriod.lastFmPeriod))
        .valueOrNull
        ?.bars
        .length;
    final stats = statsAsync.valueOrNull;
    final viewport = MediaQuery.sizeOf(context).width;

    final pad = viewport < 900 ? 16.0 : viewport < 1300 ? 24.0 : 28.0;
    final side = pad;

    return WaveEntranceGroup(
      start: stats != null,
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
                  activeTab: activeTab,
                  stats: stats,
                  genreCount: genreCount,
                  isRefreshing: statsAsync.isLoading && stats != null,
                  onPeriodChanged: (p) =>
                      ref.read(statsPeriodProvider.notifier).state = p,
                  onTabChanged: (t) =>
                      ref.read(_statsTabProvider.notifier).state = t,
                  onRefresh: () {
                    ref.invalidate(listeningStatsProvider);
                    ref.invalidate(
                      genreChartProvider(activePeriod.lastFmPeriod),
                    );
                  },
                ),
              ),
            ),
          ),
          if (stats != null)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(side, 18, side, 44),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Active Tab Content (previous data stays mounted while refreshing)
                    switch (activeTab) {
                      StatsViewTab.overview => _OverviewTab(
                          stats: stats,
                          viewportWidth: viewport,
                          onSwitchTab: (t) => ref
                              .read(_statsTabProvider.notifier)
                              .state = t,
                        ),
                      StatsViewTab.tracks => _TracksTab(tracks: stats.topTracks),
                      StatsViewTab.artists =>
                        _ArtistsTab(artists: stats.topArtists),
                      StatsViewTab.albums =>
                        _AlbumsTab(albums: stats.topAlbums),
                      StatsViewTab.history =>
                        _HistoryTab(recentPlays: stats.recentPlays),
                      StatsViewTab.genres => WaveGenresPage(
                          embedded: true,
                          externalPeriod: activePeriod.lastFmPeriod,
                        ),
                    },
                  ],
                ),
              ),
            )
          else if (statsAsync.hasError)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(side, 36, side, 40),
              sliver: SliverToBoxAdapter(
                child: WaveError(
                  title: 'Could not load statistics',
                  message: '${statsAsync.error}',
                  onRetry: () => ref.invalidate(listeningStatsProvider),
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(side, 36, side, 40),
              sliver: const SliverToBoxAdapter(
                child: WaveLoading(label: 'Loading your music statistics…'),
              ),
            ),
          const WaveDockSpacer(),
        ],
      ),
    );
  }
}

class _StatsHeader extends StatelessWidget {
  final StatsPeriod activePeriod;
  final StatsViewTab activeTab;
  final ListeningStatsData? stats;
  final int? genreCount;
  final bool isRefreshing;
  final ValueChanged<StatsPeriod> onPeriodChanged;
  final ValueChanged<StatsViewTab> onTabChanged;
  final VoidCallback onRefresh;

  const _StatsHeader({
    required this.activePeriod,
    required this.activeTab,
    this.stats,
    this.genreCount,
    this.isRefreshing = false,
    required this.onPeriodChanged,
    required this.onTabChanged,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 800;

    final title = Text('Statistics',
        style: WaveType.pageTitle.copyWith(fontSize: 27));
    final refresh = isRefreshing
        ? const Padding(
            padding: EdgeInsets.all(8),
            child: SizedBox(
              width: 14,
              height: 14,
              child: ProgressRing(strokeWidth: 2),
            ),
          )
        : WaveIconButton(
            tooltip: 'Refresh statistics',
            icon: const Icon(FluentIcons.refresh, size: 14),
            onPressed: onRefresh,
          );
    final periods = _PeriodPillSwitch(
      activePeriod: activePeriod,
      onChanged: onPeriodChanged,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (narrow) ...[
          Row(children: [title, const Spacer(), refresh]),
          const SizedBox(height: 12),
          periods,
        ] else
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              title,
              const Spacer(),
              periods,
              const SizedBox(width: 8),
              refresh,
            ],
          ),
        const SizedBox(height: 16),
        // Segmented Nav Tab Bar with counts
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: StatsViewTab.values.map((tab) {
              final isSelected = tab == activeTab;
              final count = switch (tab) {
                StatsViewTab.overview => null,
                StatsViewTab.tracks => stats?.topTracks.length,
                StatsViewTab.artists => stats?.topArtists.length,
                StatsViewTab.albums => stats?.topAlbums.length,
                StatsViewTab.history => stats?.recentPlays.length,
                StatsViewTab.genres => genreCount,
              };

              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _TabButton(
                  label: tab.label,
                  icon: tab.icon,
                  count: count,
                  selected: isSelected,
                  onTap: () => onTabChanged(tab),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.icon,
    this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: waveMotion(context, WaveMotion.fast),
          curve: WaveMotion.standard,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? (dark
                    ? Colors.white.withValues(alpha: 0.15)
                    : Colors.white)
                : waveSurface(context),
            borderRadius: WaveRadius.controlsRadius,
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.4)
                  : waveDivider(context),
              width: selected ? 1.2 : 0.8,
            ),
            boxShadow: selected && !dark
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 13,
                color: selected ? accent : waveTextTertiary(context),
              ),
              const SizedBox(width: 7),
              Text(
                label,
                style: WaveType.label.copyWith(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? waveTextPrimary(context)
                      : waveTextSecondary(context),
                ),
              ),
              if (count != null && count! > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5.5, vertical: 1),
                  decoration: BoxDecoration(
                    color: selected
                        ? accent.withValues(alpha: 0.18)
                        : (dark
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.black.withValues(alpha: 0.06)),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$count',
                    style: WaveType.overline.copyWith(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: selected ? accent : waveTextTertiary(context),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PeriodPillSwitch extends StatelessWidget {
  final StatsPeriod activePeriod;
  final ValueChanged<StatsPeriod> onChanged;

  const _PeriodPillSwitch({
    required this.activePeriod,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);

    return Container(
      padding: const EdgeInsets.all(3.5),
      decoration: BoxDecoration(
        color: dark ? waveSurfaceRaised(context) : waveOutlineSoft(context),
        borderRadius: WaveRadius.floatingRadius,
        border: Border.all(
          color: waveDivider(context),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: StatsPeriod.values.map((p) {
          final isSelected = p == activePeriod;
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
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
                  borderRadius: BorderRadius.circular(WaveRadius.floating - 2),
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
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Overview tab: three key metrics, activity charts, then previews of Top
/// Tracks, Artists and Recent History. The #1 track/artist are simply the
/// first rows of the previews, so there is no separate spotlight.
class _OverviewTab extends StatelessWidget {
  final ListeningStatsData stats;
  final double viewportWidth;
  final ValueChanged<StatsViewTab> onSwitchTab;

  const _OverviewTab({
    required this.stats,
    required this.viewportWidth,
    required this.onSwitchTab,
  });

  @override
  Widget build(BuildContext context) {
    final twoColumns = viewportWidth >= 980;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Metrics (period-scoped, each tile states its window)
        _MetricsGrid(stats: stats, viewportWidth: viewportWidth),
        const SizedBox(height: 18),

        // 2. Activity charts (on-device play log)
        _ChartsSection(stats: stats, twoColumns: twoColumns),
        const SizedBox(height: 18),

        // 3. Previews of Top Tracks & Top Artists
        if (twoColumns)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _TopTracksPreview(
                  tracks: stats.topTracks,
                  onViewAll: () => onSwitchTab(StatsViewTab.tracks),
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: _TopArtistsPreview(
                  artists: stats.topArtists,
                  onViewAll: () => onSwitchTab(StatsViewTab.artists),
                ),
              ),
            ],
          )
        else ...[
          _TopTracksPreview(
            tracks: stats.topTracks,
            onViewAll: () => onSwitchTab(StatsViewTab.tracks),
          ),
          const SizedBox(height: 20),
          _TopArtistsPreview(
            artists: stats.topArtists,
            onViewAll: () => onSwitchTab(StatsViewTab.artists),
          ),
        ],
        const SizedBox(height: 18),

        // 4. Recent History Preview
        _RecentHistoryPreview(
          recentPlays: stats.recentPlays,
          onViewAll: () => onSwitchTab(StatsViewTab.history),
        ),
      ],
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

  /// "this week" / "last 30 days" / "all time" — every tile states the
  /// window it covers so the numbers can be compared at a glance.
  String get _scope => switch (stats.period) {
        StatsPeriod.week => 'this week',
        StatsPeriod.month => 'last 30 days',
        StatsPeriod.allTime => 'all time',
      };

  String get _peakPhase {
    final h = stats.peakListeningHour;
    if (h >= 22 || h < 5) return 'Late night';
    if (h < 12) return 'Morning';
    if (h < 17) return 'Afternoon';
    return 'Evening';
  }

  String? _deltaText(int current, int? previous) {
    if (previous == null || previous <= 0) return null;
    final pct = (((current - previous) / previous) * 100).round();
    final sign = pct > 0 ? '+' : '';
    final unit = stats.period == StatsPeriod.week ? '7d' : '30d';
    return '$sign$pct% vs prior $unit';
  }

  @override
  Widget build(BuildContext context) {
    final cols = viewportWidth < 700 ? 1 : 3;
    final formatter = NumberFormat('#,###');
    final streak = stats.currentStreakDays;
    final timeDelta = _deltaText(
      stats.totalMinutesListened,
      stats.prevPeriodMinutesListened,
    );
    final playsDelta = _deltaText(stats.totalPlays, stats.prevPeriodPlays);

    final cards = [
      _MetricTile(
        icon: FluentIcons.stopwatch,
        title: 'Time listened',
        value: _formatListeningTime(stats.totalMinutesListened),
        deltaText: timeDelta,
        deltaPositive: (stats.prevPeriodMinutesListened ?? 0) <=
            stats.totalMinutesListened,
        subtext: stats.totalPlays == 0
            ? '$_scope · no plays yet'
            : (stats.hasEstimatedDuration
                ? '$_scope · actual + est. fallback'
                : '$_scope · actual track durations'),
      ),
      _MetricTile(
        icon: FluentIcons.play,
        title: 'Plays',
        value: formatter.format(stats.totalPlays),
        deltaText: playsDelta,
        deltaPositive: (stats.prevPeriodPlays ?? 0) <= stats.totalPlays,
        subtext:
            '$_scope · ${formatter.format(stats.uniqueArtists)} artists, '
            '${formatter.format(stats.uniqueTracks)} tracks',
      ),
      _MetricTile(
        icon: (stats.peakListeningHour >= 6 && stats.peakListeningHour < 18)
            ? FluentIcons.sunny
            : FluentIcons.clear_night,
        title: 'Rhythm',
        value: stats.peakListeningLabel,
        subtext: stats.peakListeningLabel == '—'
            ? (streak > 0 ? 'No plays yet · $streak-day streak' : 'No plays yet')
            : (streak > 0
                ? '$_peakPhase peak · $streak-day streak'
                : '$_peakPhase peak · no active streak'),
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
  final String title;
  final String value;
  final String subtext;
  final String? deltaText;
  final bool deltaPositive;

  const _MetricTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.subtext,
    this.deltaText,
    this.deltaPositive = true,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);

    final accent = waveAccent(context);
    final base = waveSurface(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        // A faint accent wash from the corner: lifts the tile off the page
        // without adding a colour block.
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(accent.withValues(alpha: dark ? 0.07 : 0.05), base),
            base,
          ],
        ),
        borderRadius: WaveRadius.floatingRadius,
        border: Border.all(color: waveDivider(context), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 13, color: accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: WaveType.overline.copyWith(
                    fontSize: 10,
                    color: waveTextTertiary(context),
                  ),
                ),
              ),
              if (deltaText != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: (deltaPositive
                            ? accent
                            : waveTextTertiary(context))
                        .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    deltaText!,
                    style: WaveType.meta.copyWith(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: deltaPositive
                          ? accent
                          : waveTextSecondary(context),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: WaveType.numeral.copyWith(
              fontSize: 30,
              letterSpacing: -0.4,
              color: waveTextPrimary(context),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            subtext,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: WaveType.meta.copyWith(
              fontSize: 11.5,
              color: waveTextSecondary(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChartsSection extends ConsumerStatefulWidget {
  final ListeningStatsData stats;
  final bool twoColumns;

  const _ChartsSection({
    required this.stats,
    required this.twoColumns,
  });

  @override
  ConsumerState<_ChartsSection> createState() => _ChartsSectionState();
}

class _ChartsSectionState extends ConsumerState<_ChartsSection> {
  String? _selectedDate;

  @override
  void didUpdateWidget(covariant _ChartsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stats.period != widget.stats.period) {
      _selectedDate = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = widget.stats;
    final rawShown = switch (stats.period) {
      StatsPeriod.week => stats.dailyActivity.take(7).toList(),
      StatsPeriod.month => stats.dailyActivity.take(30).toList(),
      StatsPeriod.allTime => stats.dailyActivity.take(60).toList(),
    };
    final shown = rawShown.reversed.toList(); // chart reads oldest -> newest
    final plays = shown.fold(0, (acc, e) => acc + e.count);
    final windowLabel = stats.period == StatsPeriod.allTime
        ? '${shown.length} active days'
        : 'last ${shown.length} days';

    final dayPlays = _selectedDate == null
        ? const <({String title, String artist, int atMillis})>[]
        : ref.read(databaseProvider).loadPlaysForDate(_selectedDate!);

    final activityCard = _StatsCard(
      title: 'Daily activity',
      icon: FluentIcons.b_i_dashboard,
      note: shown.isEmpty
          ? 'no activity in this period'
          : '$plays plays on this device · $windowLabel · click a bar to inspect',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DailyActivityBarChart(
            activity: shown,
            selectedDate: _selectedDate,
            onSelectDate: (date) => setState(() {
              _selectedDate = _selectedDate == date ? null : date;
            }),
          ),
          if (_selectedDate != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: waveBackground(context).withValues(alpha: 0.45),
                borderRadius: WaveRadius.controlsRadius,
                border: Border.all(color: waveDivider(context), width: 0.8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Played on $_selectedDate (${dayPlays.length})',
                        style: WaveType.label.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      WaveIconButton(
                        tooltip: 'Close day breakdown',
                        icon: const Icon(FluentIcons.chrome_close, size: 11),
                        onPressed: () => setState(() => _selectedDate = null),
                      ),
                    ],
                  ),
                  if (dayPlays.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'No tracks recorded on this day.',
                        style: WaveType.meta
                            .copyWith(color: waveTextTertiary(context)),
                      ),
                    )
                  else ...[
                    const SizedBox(height: 6),
                    for (final p in dayPlays.take(8))
                      _RecentPlayItem(
                        item: (
                          title: p.title,
                          artist: p.artist,
                          timestampMillis: p.atMillis,
                          artworkUrl: OfficialArtworkService.instance
                                  .peekTrack(title: p.title, artist: p.artist)
                                  ?.artworkUrl ??
                              '',
                        ),
                      ),
                    if (dayPlays.length > 8)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '+${dayPlays.length - 8} more tracks on $_selectedDate',
                          style: WaveType.meta
                              .copyWith(color: waveTextTertiary(context)),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );

    final rhythmCard = _StatsCard(
      title: 'Time of day',
      icon: FluentIcons.clock,
      note: stats.peakListeningLabel == '—'
          ? 'no plays yet'
          : 'peak ${stats.peakListeningLabel}',
      child: _HourlyDistributionChart(
        hourly: stats.hourlyDistribution,
        peakHour: stats.peakListeningHour,
      ),
    );

    if (widget.twoColumns) {
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
  final String? selectedDate;
  final ValueChanged<String>? onSelectDate;

  const _DailyActivityBarChart({
    required this.activity,
    this.selectedDate,
    this.onSelectDate,
  });

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
    final dense = activity.length > 14;
    final labelStep = activity.length > 35
        ? 6
        : (activity.length > 20 ? 4 : (dense ? 2 : 1));

    return SizedBox(
      height: 114,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: activity.asMap().entries.map((entry) {
          final index = entry.key;
          final item = entry.value;
          final ratio = (item.count / maxCount).clamp(0.06, 1.0);
          final parsedDate = DateTime.tryParse(item.date);
          final dayLabel = parsedDate != null
              ? DateFormat('E').format(parsedDate).substring(0, 1)
              : '';
          final dayNum = parsedDate != null ? '${parsedDate.day}' : '';
          final isToday = parsedDate != null &&
              DateFormat('yyyy-MM-dd').format(DateTime.now()) == item.date;
          final isSelected = selectedDate == item.date;
          final showAxisLabel =
              index % labelStep == 0 || index == activity.length - 1;

          return Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: dense ? 1.2 : 2.5),
              child: Tooltip(
                message: '${item.count} plays on ${item.date}',
                child: MouseRegion(
                  cursor: item.count > 0 && onSelectDate != null
                      ? SystemMouseCursors.click
                      : SystemMouseCursors.basic,
                  child: GestureDetector(
                    onTap: item.count > 0 && onSelectDate != null
                        ? () => onSelectDate!(item.date)
                        : null,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (!dense) ...[
                          Text(
                            item.count > 0 ? '${item.count}' : '',
                            style: WaveType.overline.copyWith(
                              fontSize: 8.5,
                              color: isSelected
                                  ? waveTextPrimary(context)
                                  : waveTextTertiary(context),
                            ),
                          ),
                          const SizedBox(height: 3),
                        ],
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              heightFactor: ratio,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: item.count == 0
                                      ? waveDivider(context)
                                          .withValues(alpha: 0.3)
                                      : (isSelected || isToday
                                          ? waveAccent(context)
                                          : waveAccent(context)
                                              .withValues(alpha: 0.48)),
                                  border: isSelected
                                      ? Border.all(
                                          color: Colors.white
                                              .withValues(alpha: 0.85),
                                          width: 1.3,
                                        )
                                      : null,
                                  borderRadius: BorderRadius.circular(
                                      dense ? 2.5 : 4),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        SizedBox(
                          height: 12,
                          child: showAxisLabel
                              ? Text(
                                  dense ? dayNum : '$dayLabel $dayNum',
                                  maxLines: 1,
                                  overflow: TextOverflow.clip,
                                  style: WaveType.label.copyWith(
                                    fontSize: dense ? 8.5 : 9.0,
                                    color: (isSelected || isToday)
                                        ? waveTextPrimary(context)
                                        : waveTextTertiary(context),
                                    fontWeight: (isSelected || isToday)
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
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

              // One accent: the peak hour solid, other hours muted.
              final color = isPeak
                  ? waveAccent(context)
                  : (count > 0
                      ? waveAccent(context).withValues(alpha: 0.45)
                      : waveDivider(context).withValues(alpha: 0.2));

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
                            color: color,
                            borderRadius: BorderRadius.circular(2.5),
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
            Text('12 AM · Night',
                style: WaveType.overline.copyWith(
                    fontSize: 8.5, color: waveTextTertiary(context))),
            Text('6 AM · Morning',
                style: WaveType.overline.copyWith(
                    fontSize: 8.5, color: waveTextTertiary(context))),
            Text('12 PM · Afternoon',
                style: WaveType.overline.copyWith(
                    fontSize: 8.5, color: waveTextTertiary(context))),
            Text('6 PM · Evening',
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

/// The one card every Stats section uses: surface + hairline border, a
/// title row (title, optional dim note, optional action link) and a body.
/// Overview previews, charts and the full tabs all share it so spacing and
/// hierarchy stay identical.
class _StatsCard extends StatelessWidget {
  final String title;
  final IconData? icon;
  final String? note;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Widget child;

  const _StatsCard({
    required this.title,
    required this.child,
    this.icon,
    this.note,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);

    final base = waveSurface(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        // Barely-there top-down sheen so the cards read as surfaces.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.alphaBlend(
              (dark ? Colors.white : Colors.black)
                  .withValues(alpha: dark ? 0.025 : 0.015),
              base,
            ),
            base,
          ],
        ),
        borderRadius: WaveRadius.floatingRadius,
        border: Border.all(color: waveDivider(context), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LWSectionHeader(
            title: title,
            actionLabel: actionLabel,
            onAction: onAction,
          ),
          if (note != null) ...[
            const SizedBox(height: 2),
            Text(note!,
                style:
                    WaveType.meta.copyWith(color: waveTextTertiary(context))),
          ],
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

/// Dim one-liner shown when a card has nothing to list.
class _CardEmpty extends StatelessWidget {
  final String text;
  const _CardEmpty(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(text,
            style:
                WaveType.meta.copyWith(color: waveTextSecondary(context))),
      );
}

class _TopTracksPreview extends StatelessWidget {
  final List<StatTrack> tracks;
  final VoidCallback onViewAll;

  const _TopTracksPreview({required this.tracks, required this.onViewAll});

  @override
  Widget build(BuildContext context) {
    final topPlays = tracks.isNotEmpty ? tracks.first.playCount : 1;

    return _StatsCard(
      title: 'Top tracks',
      actionLabel: 'View all →',
      onAction: onViewAll,
      child: tracks.isEmpty
          ? const _CardEmpty('No tracks played in this period.')
          : ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: math.min(5, tracks.length),
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, i) => _TrackRowItem(
                track: tracks[i],
                rank: i + 1,
                maxPlays: topPlays,
              ),
            ),
    );
  }
}

class _TopArtistsPreview extends StatelessWidget {
  final List<StatArtist> artists;
  final VoidCallback onViewAll;

  const _TopArtistsPreview({required this.artists, required this.onViewAll});

  @override
  Widget build(BuildContext context) {
    return _StatsCard(
      title: 'Top artists',
      actionLabel: 'View all →',
      onAction: onViewAll,
      child: artists.isEmpty
          ? const _CardEmpty('No artists recorded in this period.')
          : ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: math.min(5, artists.length),
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, i) =>
                  _ArtistRowItem(artist: artists[i], rank: i + 1),
            ),
    );
  }
}

class _RecentHistoryPreview extends StatelessWidget {
  final List<({String title, String artist, int timestampMillis, String artworkUrl})>
      recentPlays;
  final VoidCallback onViewAll;

  const _RecentHistoryPreview({
    required this.recentPlays,
    required this.onViewAll,
  });

  @override
  Widget build(BuildContext context) {
    return _StatsCard(
      title: 'Recently played',
      actionLabel: 'See all →',
      onAction: onViewAll,
      child: recentPlays.isEmpty
          ? const _CardEmpty('No recent playback history yet.')
          : ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: math.min(5, recentPlays.length),
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, i) =>
                  _RecentPlayItem(item: recentPlays[i]),
            ),
    );
  }
}

/// Shared filter + pagination wrapper for full Stats tabs.
class _SearchablePagedCard<T> extends StatefulWidget {
  final String title;
  final IconData icon;
  final String noteSuffix;
  final List<T> items;
  final String emptyText;
  final String searchPlaceholder;
  final bool Function(T item, String query) matches;
  final Widget Function(BuildContext context, List<T> visible) builder;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _SearchablePagedCard({
    required this.title,
    required this.icon,
    required this.noteSuffix,
    required this.items,
    required this.emptyText,
    required this.searchPlaceholder,
    required this.matches,
    required this.builder,
    this.actionLabel,
    this.onAction,
  });

  @override
  State<_SearchablePagedCard<T>> createState() => _SearchablePagedCardState<T>();
}

class _SearchablePagedCardState<T> extends State<_SearchablePagedCard<T>> {
  static const int _pageSize = 25;
  final _searchCtrl = TextEditingController();
  String _query = '';
  int _limit = _pageSize;

  @override
  void didUpdateWidget(covariant _SearchablePagedCard<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items != widget.items) {
      _limit = _pageSize;
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? widget.items
        : widget.items.where((e) => widget.matches(e, q)).toList();
    final shown = filtered.take(_limit).toList();
    final remaining = filtered.length - shown.length;

    return _StatsCard(
      title: widget.title,
      icon: widget.icon,
      note: q.isEmpty
          ? '${widget.items.length} ${widget.noteSuffix}'
          : '${filtered.length} of ${widget.items.length} ${widget.noteSuffix}',
      actionLabel: widget.actionLabel,
      onAction: widget.onAction,
      child: widget.items.isEmpty
          ? _CardEmpty(widget.emptyText)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.items.length > 5) ...[
                  SizedBox(
                    width: 280,
                    child: TextBox(
                      controller: _searchCtrl,
                      placeholder: widget.searchPlaceholder,
                      prefix: const Padding(
                        padding: EdgeInsets.only(left: 10),
                        child: Icon(WaveIcons.search, size: 13),
                      ),
                      suffix: q.isNotEmpty
                          ? IconButton(
                              icon: const Icon(FluentIcons.chrome_close,
                                  size: 10),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() {
                                  _query = '';
                                  _limit = _pageSize;
                                });
                              },
                            )
                          : null,
                      onChanged: (v) => setState(() {
                        _query = v;
                        _limit = _pageSize;
                      }),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (filtered.isEmpty)
                  const _CardEmpty('No matching entries.')
                else
                  widget.builder(context, shown),
                if (remaining > 0) ...[
                  const SizedBox(height: 14),
                  Center(
                    child: WaveButton(
                      onPressed: () => setState(() => _limit += _pageSize),
                      child: Text(
                        'Show more ($remaining remaining)',
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

/// Full Top Tracks View Tab
class _TracksTab extends StatelessWidget {
  final List<StatTrack> tracks;
  const _TracksTab({required this.tracks});

  @override
  Widget build(BuildContext context) {
    final topPlays = tracks.isNotEmpty ? tracks.first.playCount : 1;

    return _SearchablePagedCard<StatTrack>(
      title: 'Top tracks',
      icon: FluentIcons.music_in_collection,
      noteSuffix: 'ranked',
      items: tracks,
      emptyText: 'No tracks played during this period.',
      searchPlaceholder: 'Filter tracks or artists…',
      matches: (t, q) =>
          t.name.toLowerCase().contains(q) ||
          t.artist.toLowerCase().contains(q),
      builder: (context, visible) => ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: visible.length,
        separatorBuilder: (_, _) => const SizedBox(height: 4),
        itemBuilder: (context, i) => _TrackRowItem(
          track: visible[i],
          rank: i + 1,
          maxPlays: topPlays,
        ),
      ),
    );
  }
}

/// Column count shared by the artist and album grids.
int _gridColumns(double width) =>
    width < 600 ? 2 : (width < 900 ? 3 : (width < 1200 ? 4 : 5));

/// Full Top Artists View Tab (Individual artists with high-res photos)
class _ArtistsTab extends StatelessWidget {
  final List<StatArtist> artists;
  const _ArtistsTab({required this.artists});

  @override
  Widget build(BuildContext context) {
    return _SearchablePagedCard<StatArtist>(
      title: 'Top artists',
      icon: FluentIcons.microphone,
      noteSuffix: 'artists',
      items: artists,
      emptyText: 'No artists recorded during this period.',
      searchPlaceholder: 'Filter artists…',
      matches: (a, q) => a.name.toLowerCase().contains(q),
      builder: (context, visible) => LayoutBuilder(builder: (context, c) {
        final cols = _gridColumns(c.maxWidth);
        final itemWidth = (c.maxWidth - (cols - 1) * 14) / cols;

        return Wrap(
          spacing: 14,
          runSpacing: 14,
          children: visible.asMap().entries.map((entry) {
            return SizedBox(
              width: itemWidth,
              child: _ArtistGridCard(
                artist: entry.value,
                rank: entry.key + 1,
              ),
            );
          }).toList(),
        );
      }),
    );
  }
}

/// Full Top Albums View Tab
class _AlbumsTab extends StatelessWidget {
  final List<StatAlbum> albums;
  const _AlbumsTab({required this.albums});

  @override
  Widget build(BuildContext context) {
    return _SearchablePagedCard<StatAlbum>(
      title: 'Top albums',
      icon: WaveIcons.albums,
      noteSuffix: 'albums',
      items: albums,
      emptyText: 'No album plays found for this period.',
      searchPlaceholder: 'Filter albums or artists…',
      matches: (a, q) =>
          a.name.toLowerCase().contains(q) ||
          a.artist.toLowerCase().contains(q),
      builder: (context, visible) => LayoutBuilder(builder: (context, c) {
        final cols = _gridColumns(c.maxWidth);
        final itemWidth = (c.maxWidth - (cols - 1) * 14) / cols;

        return Wrap(
          spacing: 14,
          runSpacing: 14,
          children: visible.asMap().entries.map((entry) {
            return SizedBox(
              width: itemWidth,
              child: _AlbumGridCard(
                album: entry.value,
                rank: entry.key + 1,
                size: itemWidth,
              ),
            );
          }).toList(),
        );
      }),
    );
  }
}

/// Full History View Tab
class _HistoryTab extends StatelessWidget {
  final List<({String title, String artist, int timestampMillis, String artworkUrl})>
      recentPlays;
  const _HistoryTab({required this.recentPlays});

  @override
  Widget build(BuildContext context) {
    return _SearchablePagedCard<
        ({String title, String artist, int timestampMillis, String artworkUrl})>(
      title: 'Recently played',
      icon: WaveIcons.history,
      noteSuffix: 'plays',
      items: recentPlays,
      emptyText: 'No recent playback records.',
      searchPlaceholder: 'Filter history…',
      matches: (p, q) =>
          p.title.toLowerCase().contains(q) ||
          p.artist.toLowerCase().contains(q),
      actionLabel: 'Full history →',
      onAction: () => context.go('/history'),
      builder: (context, visible) => ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: visible.length,
        separatorBuilder: (_, _) => const SizedBox(height: 4),
        itemBuilder: (context, i) => _RecentPlayItem(item: visible[i]),
      ),
    );
  }
}
// ---------------------------------------------------------------------------
// Shared Row & Grid Widgets
// ---------------------------------------------------------------------------

class _TrackRowItem extends ConsumerStatefulWidget {
  final StatTrack track;
  final int rank;
  final int maxPlays;

  const _TrackRowItem({
    required this.track,
    required this.rank,
    required this.maxPlays,
  });

  @override
  ConsumerState<_TrackRowItem> createState() => _TrackRowItemState();
}

class _TrackRowItemState extends ConsumerState<_TrackRowItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final rank = widget.rank;
    final isTop3 = rank <= 3;
    final dark = waveIsDark(context);

    final rankColor = rank == 1
        ? const Color(0xFFFFD700)
        : (rank == 2
            ? const Color(0xFFC0C0C0)
            : (rank == 3
                ? const Color(0xFFCD7F32)
                : waveTextTertiary(context)));

    final ratio = widget.maxPlays > 0
        ? (track.playCount / widget.maxPlays).clamp(0.04, 1.0)
        : 1.0;

    void play() {
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
    }

    return WaveContextMenu(
      items: () => waveTrackMenuItems(
        context: context,
        ref: ref,
        title: track.name,
        artist: track.artist,
        artworkUrl: track.artworkUrl,
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: play,
          child: AnimatedContainer(
          duration: waveMotion(context, WaveMotion.fast),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: WaveRadius.controlsRadius,
            color: _hover
                ? (dark
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.black.withValues(alpha: 0.04))
                : Colors.transparent,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  '$rank',
                  style: WaveType.label.copyWith(
                    fontSize: isTop3 ? 14 : 12.5,
                    color: rankColor,
                    fontWeight: isTop3 ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ),
              Stack(
                children: [
                  WaveArtwork(
                    url: track.artworkUrl,
                    size: 44,
                    radius: WaveRadius.artwork,
                    title: track.name,
                    artist: track.artist,
                    label: track.name,
                  ),
                  Positioned.fill(
                    child: AnimatedOpacity(
                      opacity: _hover ? 1.0 : 0.0,
                      duration: waveMotion(context, WaveMotion.fast),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: WaveRadius.artworkRadius,
                        ),
                        child: const Center(
                          child: Icon(WaveIcons.play,
                              size: 16, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ],
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
                      style: WaveType.trackTitle.copyWith(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    WaveArtistLine(artist: track.artist),
                    const SizedBox(height: 4),
                    // Relative popularity gauge bar
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: Container(
                        height: 2.5,
                        width: double.infinity,
                        color: dark
                            ? Colors.white.withValues(alpha: 0.06)
                            : Colors.black.withValues(alpha: 0.06),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: ratio,
                            child: Container(
                              color: rank == 1
                                  ? const Color(0xFFFFD700)
                                  : waveAccent(context).withValues(alpha: 0.65),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8.5, vertical: 4),
                decoration: BoxDecoration(
                  color: waveAccent(context).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: waveAccent(context).withValues(alpha: 0.2),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(WaveIcons.play, size: 9, color: waveAccent(context)),
                    const SizedBox(width: 4),
                    Text(
                      '${track.playCount} ${track.playCount == 1 ? 'play' : 'plays'}',
                      style: WaveType.label.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: waveAccent(context),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

class _ArtistRowItem extends StatelessWidget {
  final StatArtist artist;
  final int rank;

  const _ArtistRowItem({required this.artist, required this.rank});

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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: WaveRadius.controlsRadius,
          color: Colors.transparent,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                '$rank',
                style: WaveType.label.copyWith(
                  fontSize: isTop3 ? 14 : 12.5,
                  color: rankColor,
                  fontWeight:
                      isTop3 ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isTop3
                      ? rankColor.withValues(alpha: 0.6)
                      : waveDivider(context),
                  width: isTop3 ? 1.5 : 1.0,
                ),
              ),
              child: ClipOval(
                child: WaveArtwork(
                  url: artist.artworkUrl,
                  size: 42,
                  kind: ArtworkKind.artist,
                  title: artist.name,
                  artist: artist.name,
                  label: artist.name,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WaveType.trackTitle.copyWith(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8.5, vertical: 4),
              decoration: BoxDecoration(
                color: waveAccent(context).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: waveAccent(context).withValues(alpha: 0.2),
                  width: 0.8,
                ),
              ),
              child: Text(
                '${artist.playCount} ${artist.playCount == 1 ? 'play' : 'plays'}',
                style: WaveType.label.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
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

class _ArtistGridCard extends StatefulWidget {
  final StatArtist artist;
  final int rank;

  const _ArtistGridCard({required this.artist, required this.rank});

  @override
  State<_ArtistGridCard> createState() => _ArtistGridCardState();
}

class _ArtistGridCardState extends State<_ArtistGridCard> {
  static const double _size = 110;
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final a = widget.artist;
    final isTop3 = widget.rank <= 3;
    final medalColor = widget.rank == 1
        ? const Color(0xFFFFD700)
        : (widget.rank == 2
            ? const Color(0xFFC0C0C0)
            : (widget.rank == 3
                ? const Color(0xFFCD7F32)
                : Colors.white));

    final radius = BorderRadius.circular(
      _hover ? WaveRadius.floating : _size / 2,
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () =>
            waveOpen(context, '/artist/${Uri.encodeComponent(a.name)}'),
        child: Column(
          children: [
            AnimatedScale(
              scale: _pressed ? 0.97 : (_hover ? 1.04 : 1.0),
              duration: waveMotion(context, WaveMotion.fast),
              curve: Curves.easeOutCubic,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedContainer(
                    duration: waveMotion(context, WaveMotion.normal),
                    curve: Curves.easeOutCubic,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      boxShadow: [
                        if (_hover) ...WaveElevation.lift(dark),
                        if (isTop3)
                          BoxShadow(
                            color: medalColor.withValues(alpha: 0.25),
                            blurRadius: 10,
                          ),
                      ],
                    ),
                    foregroundDecoration: BoxDecoration(
                      borderRadius: radius,
                      border: Border.all(
                        color: isTop3
                            ? medalColor.withValues(alpha: 0.6)
                            : waveDivider(context),
                        width: isTop3 ? 1.5 : 1.0,
                      ),
                    ),
                    child: WaveArtwork(
                      url: a.artworkUrl,
                      size: _size,
                      radius: WaveRadius.structural,
                      kind: ArtworkKind.artist,
                      label: a.name,
                      title: a.name,
                      artist: a.name,
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: isTop3
                            ? medalColor
                            : Colors.black.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(999),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                      child: Text(
                        '#${widget.rank}',
                        style: WaveType.label.copyWith(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: isTop3 ? Colors.black : Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              a.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: WaveType.trackTitle.copyWith(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: waveAccent(context).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '${a.playCount} plays',
                style: WaveType.meta.copyWith(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
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

class _AlbumGridCard extends ConsumerStatefulWidget {
  final StatAlbum album;
  final int rank;
  final double size;

  const _AlbumGridCard({
    required this.album,
    required this.rank,
    this.size = 160,
  });

  @override
  ConsumerState<_AlbumGridCard> createState() => _AlbumGridCardState();
}

class _AlbumGridCardState extends ConsumerState<_AlbumGridCard> {
  bool _hover = false;
  bool _pressed = false;

  /// Last.fm gives no browseId, and `/album/` with an empty one is a
  /// dead route — resolve it, else fall back to a search.
  Future<void> _open() async {
    final album = widget.album;
    final bid = await resolveAlbumBrowseId(ref.read(innerTubeProvider),
        title: album.name, artist: album.artist);
    if (!mounted) return;
    if (bid.isEmpty) {
      context.go(
          '/search?q=${Uri.encodeComponent('${album.artist} ${album.name}')}');
      return;
    }
    waveOpen(
      context,
      waveAlbumLocation(
        browseId: bid,
        title: album.name,
        artist: album.artist,
        artworkUrl: album.artworkUrl,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final album = widget.album;
    final rank = widget.rank;
    final isTop3 = rank <= 3;
    final medalColor = rank == 1
        ? const Color(0xFFFFD700)
        : (rank == 2
            ? const Color(0xFFC0C0C0)
            : (rank == 3
                ? const Color(0xFFCD7F32)
                : Colors.white));

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: _open,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedScale(
              scale: _pressed ? 0.97 : (_hover ? 1.03 : 1.0),
              duration: waveMotion(context, WaveMotion.fast),
              curve: Curves.easeOutCubic,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedContainer(
                    duration: waveMotion(context, WaveMotion.normal),
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      borderRadius: WaveRadius.artworkRadius,
                      boxShadow: [
                        if (_hover) ...WaveElevation.lift(dark),
                        BoxShadow(
                          color: Colors.black
                              .withValues(alpha: dark ? 0.35 : 0.12),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                        if (isTop3)
                          BoxShadow(
                            color: medalColor.withValues(alpha: 0.25),
                            blurRadius: 10,
                          ),
                      ],
                    ),
                    foregroundDecoration: BoxDecoration(
                      borderRadius: WaveRadius.artworkRadius,
                      border: Border.all(
                        color: isTop3
                            ? medalColor.withValues(alpha: 0.65)
                            : waveDivider(context),
                        width: isTop3 ? 1.5 : 0.8,
                      ),
                    ),
                    child: WaveArtwork(
                      url: album.artworkUrl,
                      size: widget.size,
                      radius: WaveRadius.artwork,
                      title: album.name,
                      artist: album.artist,
                      kind: ArtworkKind.album,
                      label: album.name,
                    ),
                  ),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: isTop3
                            ? medalColor
                            : Colors.black.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(999),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                      child: Text(
                        '#$rank',
                        style: WaveType.label.copyWith(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: isTop3 ? Colors.black : Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              album.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WaveType.trackTitle.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 1),
            WaveArtistLine(
              artist: album.artist,
              style: WaveType.meta.copyWith(fontSize: 11.5),
            ),
            const SizedBox(height: 2),
            Text(
              '${album.playCount} ${album.playCount == 1 ? 'play' : 'plays'}',
              style: WaveType.meta.copyWith(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: waveTextTertiary(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentPlayItem extends ConsumerStatefulWidget {
  final ({String title, String artist, int timestampMillis, String artworkUrl})
      item;
  const _RecentPlayItem({required this.item});

  @override
  ConsumerState<_RecentPlayItem> createState() => _RecentPlayItemState();
}

class _RecentPlayItemState extends ConsumerState<_RecentPlayItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final dark = waveIsDark(context);

    return WaveContextMenu(
      items: () => waveTrackMenuItems(
        context: context,
        ref: ref,
        title: item.title,
        artist: item.artist,
        artworkUrl: item.artworkUrl,
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () {
            playGenerated(
              ref,
              context,
              GeneratedTrack(
                name: item.title,
                artist: item.artist,
                artworkUrl: item.artworkUrl,
              ),
              sourceLabel: 'History',
            );
          },
          child: AnimatedContainer(
            duration: waveMotion(context, WaveMotion.fast),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: WaveRadius.controlsRadius,
              color: _hover
                  ? (dark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.black.withValues(alpha: 0.04))
                  : Colors.transparent,
            ),
            child: Row(
              children: [
                Stack(
                  children: [
                    WaveArtwork(
                      url: item.artworkUrl,
                      size: 40,
                      radius: WaveRadius.artwork,
                      title: item.title,
                      artist: item.artist,
                      label: item.title,
                    ),
                    Positioned.fill(
                      child: AnimatedOpacity(
                        opacity: _hover ? 1.0 : 0.0,
                        duration: waveMotion(context, WaveMotion.fast),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: WaveRadius.artworkRadius,
                          ),
                          child: const Center(
                            child: Icon(WaveIcons.play,
                                size: 15, color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.trackTitle.copyWith(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 1),
                      WaveArtistLine(artist: item.artist),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: waveTextTertiary(context).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    relativeTime(
                      DateTime.fromMillisecondsSinceEpoch(item.timestampMillis),
                    ),
                    style: WaveType.meta.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: waveTextSecondary(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
