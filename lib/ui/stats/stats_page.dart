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
import '../components/track_row.dart' show WaveArtistLine;
import '../navigation/wave_nav.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

enum StatsViewTab {
  overview('Overview', FluentIcons.b_i_dashboard),
  tracks('Top Tracks', FluentIcons.music_in_collection),
  artists('Top Artists', FluentIcons.microphone),
  albums('Top Albums', FluentIcons.album),
  history('History', FluentIcons.history);

  final String label;
  final IconData icon;
  const StatsViewTab(this.label, this.icon);
}

final _statsTabProvider =
    StateProvider.autoDispose<StatsViewTab>((ref) => StatsViewTab.overview);

/// WaveStatsPage — Highly organized listening statistics dashboard.
///
/// Features:
/// - Last.fm profile hub with scrobbles, artist, album, track totals.
/// - Clear tab organization (Overview, Top Tracks, Top Artists, Top Albums, History).
/// - Period filter (7 Days, 30 Days, All Time).
/// - 100% individual separated artists (no 2-artist conjoined labels).
/// - Pristine artwork loading for tracks, artists, and history rows.
class WaveStatsPage extends ConsumerWidget {
  const WaveStatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statsAsync = ref.watch(listeningStatsProvider);
    final activePeriod = ref.watch(statsPeriodProvider);
    final activeTab = ref.watch(_statsTabProvider);
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
                  activeTab: activeTab,
                  onPeriodChanged: (p) =>
                      ref.read(statsPeriodProvider.notifier).state = p,
                  onTabChanged: (t) =>
                      ref.read(_statsTabProvider.notifier).state = t,
                  onRefresh: () => ref.invalidate(listeningStatsProvider),
                ),
              ),
            ),
          ),
          statsAsync.when(
            loading: () => SliverPadding(
              padding: EdgeInsets.fromLTRB(side, 32, side, 40),
              sliver: const SliverToBoxAdapter(
                child: WaveLoading(label: 'Syncing your statistics…'),
              ),
            ),
            error: (err, _) => SliverPadding(
              padding: EdgeInsets.fromLTRB(side, 32, side, 40),
              sliver: SliverToBoxAdapter(
                child: WaveError(
                  title: 'Could not load statistics',
                  message: '$err',
                  onRetry: () => ref.invalidate(listeningStatsProvider),
                ),
              ),
            ),
            data: (stats) {
              return SliverPadding(
                padding: EdgeInsets.fromLTRB(side, 18, side, 40),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 1. Last.fm Profile & Sync Hub
                      _LastFmProfileHub(stats: stats),
                      const SizedBox(height: 18),

                      // 2. Active Tab Content
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
                      },
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

class _StatsHeader extends StatelessWidget {
  final StatsPeriod activePeriod;
  final StatsViewTab activeTab;
  final ValueChanged<StatsPeriod> onPeriodChanged;
  final ValueChanged<StatsViewTab> onTabChanged;
  final VoidCallback onRefresh;

  const _StatsHeader({
    required this.activePeriod,
    required this.activeTab,
    required this.onPeriodChanged,
    required this.onTabChanged,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 760;

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
              'LISTENING INTELLIGENCE',
              style: WaveType.overline.copyWith(
                color: waveAccent(context),
              ),
            ),
            const Spacer(),
            WaveIconButton(
              tooltip: 'Refresh statistics',
              icon: const Icon(FluentIcons.refresh, size: 14),
              onPressed: onRefresh,
            ),
          ],
        ),
        const SizedBox(height: 2),
        if (narrow) ...[
          Text('Statistics',
              style: WaveType.pageTitle.copyWith(fontSize: 26)),
          const SizedBox(height: 4),
          Text(
            'Local metrics, Last.fm scrobbles, and rhythmic trends.',
            style:
                WaveType.meta.copyWith(color: waveTextSecondary(context)),
          ),
          const SizedBox(height: 14),
          _PeriodPillSwitch(
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
                    const SizedBox(height: 2),
                    Text(
                      'Local metrics, Last.fm scrobbles, and rhythmic trends.',
                      style: WaveType.meta
                          .copyWith(color: waveTextSecondary(context)),
                    ),
                  ],
                ),
              ),
              _PeriodPillSwitch(
                activePeriod: activePeriod,
                onChanged: onPeriodChanged,
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        // Section Navigation Tabs
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: StatsViewTab.values.map((tab) {
              final isSelected = tab == activeTab;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _TabButton(
                  label: tab.label,
                  icon: tab.icon,
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
  final bool selected;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.icon,
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
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? (dark
                    ? Colors.white.withValues(alpha: 0.16)
                    : Colors.black.withValues(alpha: 0.08))
                : Colors.transparent,
            borderRadius: WaveRadius.controlsRadius,
            border: Border.all(
              color: selected
                  ? waveDivider(context)
                  : Colors.transparent,
              width: 0.8,
            ),
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

class _LastFmProfileHub extends StatelessWidget {
  final ListeningStatsData stats;
  const _LastFmProfileHub({required this.stats});

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final isConnected = stats.isLastFmConnected;
    final formatter = NumberFormat('#,###');

    if (!isConnected) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: dark ? WaveColors.surfaceRaised : WaveColors.lightSurface,
          borderRadius: WaveRadius.floatingRadius,
          border: Border.all(color: waveDivider(context), width: 0.8),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFE0506A).withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                FluentIcons.favorite_star,
                color: Color(0xFFE0506A),
                size: 20,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Connect Last.fm for Complete Cross-Device Scrobbling',
                    style: WaveType.trackTitle.copyWith(fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Scrobble every track played on LastWave, access global charts, and keep permanent music history.',
                    style: WaveType.meta.copyWith(
                      color: waveTextSecondary(context),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            WaveGhostButton(
              label: 'Connect Last.fm',
              icon: FluentIcons.settings,
              onPressed: () => context.go('/settings?section=lastfm'),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: dark ? WaveColors.surfaceRaised : WaveColors.lightSurface,
        borderRadius: WaveRadius.floatingRadius,
        border: Border.all(
          color: const Color(0xFFE0506A).withValues(alpha: 0.25),
          width: 0.9,
        ),
      ),
      child: LayoutBuilder(builder: (context, c) {
        final narrow = c.maxWidth < 700;

        final profileLeading = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFFE0506A).withValues(alpha: 0.4),
                  width: 1.5,
                ),
              ),
              child: ClipOval(
                child: WaveArtwork(
                  url: stats.lastFmAvatarUrl,
                  size: 44,
                  kind: ArtworkKind.artist,
                  label: stats.lastFmUsername,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      '@${stats.lastFmUsername}',
                      style: WaveType.trackTitle.copyWith(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE0506A).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'LAST.FM',
                        style: WaveType.overline.copyWith(
                          fontSize: 8.5,
                          color: const Color(0xFFE0506A),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Connected & scrobbling',
                  style: WaveType.meta.copyWith(
                    fontSize: 11.5,
                    color: const Color(0xFF7BE3A8),
                  ),
                ),
              ],
            ),
          ],
        );

        final badges = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _HubStatBadge(
              label: 'Scrobbles',
              value: formatter.format(stats.lastFmScrobbles),
            ),
            const SizedBox(width: 14),
            _HubStatBadge(
              label: 'Artists',
              value: formatter.format(stats.lastFmArtistsCount),
            ),
            const SizedBox(width: 14),
            _HubStatBadge(
              label: 'Albums',
              value: formatter.format(stats.lastFmAlbumsCount),
            ),
            const SizedBox(width: 14),
            _HubStatBadge(
              label: 'Tracks',
              value: formatter.format(stats.lastFmTracksCount),
            ),
          ],
        );

        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              profileLeading,
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: badges,
              ),
            ],
          );
        }

        return Row(
          children: [
            profileLeading,
            const Spacer(),
            badges,
            const SizedBox(width: 16),
            WaveIconButton(
              tooltip: 'Last.fm Settings',
              icon: const Icon(FluentIcons.settings, size: 14),
              onPressed: () => context.go('/settings?section=lastfm'),
            ),
          ],
        );
      }),
    );
  }
}

class _HubStatBadge extends StatelessWidget {
  final String label;
  final String value;
  const _HubStatBadge({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: WaveType.numeral.copyWith(
            fontSize: 15,
            color: waveTextPrimary(context),
          ),
        ),
        Text(
          label.toUpperCase(),
          style: WaveType.overline.copyWith(
            fontSize: 8.5,
            color: waveTextTertiary(context),
          ),
        ),
      ],
    );
  }
}

/// Overview tab: Key metrics, 14-day activity chart, 24-hr rhythm,
/// and executive previews of Top Tracks, Artists, and Recent History.
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
    final twoColumns = viewportWidth >= 960;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Metrics Summary Grid
        _MetricsGrid(stats: stats, viewportWidth: viewportWidth),
        const SizedBox(height: 22),

        // Activity Charts
        _ChartsSection(stats: stats, twoColumns: twoColumns),
        const SizedBox(height: 26),

        // Side-by-side or stacked preview of Top Tracks & Top Artists
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
        const SizedBox(height: 26),

        // Recent History Preview
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

  @override
  Widget build(BuildContext context) {
    final cols = viewportWidth < 700 ? 2 : (viewportWidth < 1100 ? 3 : 5);
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
            ? '${formatter.format(stats.lastFmScrobbles)} scrobbles'
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
        title: 'Peak Rhythm',
        value: stats.peakListeningLabel,
        subtext: stats.peakListeningHour >= 22 || stats.peakListeningHour < 5
            ? 'Late night sessions'
            : (stats.peakListeningHour < 12
                ? 'Morning energy'
                : 'Evening groove'),
      ),
      _MetricTile(
        icon: FluentIcons.music_in_collection,
        accentColor: const Color(0xFFE08BB8),
        title: 'Library Scope',
        value: '${formatter.format(stats.uniqueArtists)} artists',
        subtext: '${formatter.format(stats.uniqueTracks)} distinct tracks',
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
      padding: const EdgeInsets.all(15),
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
                child: Icon(icon, size: 14, color: accentColor),
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
              fontSize: 21,
              color: waveTextPrimary(context),
            ),
          ),
          const SizedBox(height: 3),
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

class _TopTracksPreview extends StatelessWidget {
  final List<StatTrack> tracks;
  final VoidCallback onViewAll;

  const _TopTracksPreview({required this.tracks, required this.onViewAll});

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
              Icon(FluentIcons.music_in_collection,
                  size: 14, color: waveAccent(context)),
              const SizedBox(width: 8),
              Text('Top Tracks', style: WaveType.sectionTitle),
              const Spacer(),
              GestureDetector(
                onTap: onViewAll,
                child: Text('View all (${tracks.length}) →',
                    style: WaveType.label.copyWith(
                      color: waveAccent(context),
                      fontSize: 12,
                    )),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (tracks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('No tracks played in this period.',
                  style: WaveType.meta.copyWith(color: waveTextSecondary(context))),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: math.min(5, tracks.length),
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, i) =>
                  _TrackRowItem(track: tracks[i], rank: i + 1),
            ),
        ],
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
              GestureDetector(
                onTap: onViewAll,
                child: Text('View all (${artists.length}) →',
                    style: WaveType.label.copyWith(
                      color: waveAccent(context),
                      fontSize: 12,
                    )),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (artists.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('No artists recorded in this period.',
                  style: WaveType.meta.copyWith(color: waveTextSecondary(context))),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: math.min(5, artists.length),
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, i) =>
                  _ArtistRowItem(artist: artists[i], rank: i + 1),
            ),
        ],
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
              Text('Recent Playback Stream', style: WaveType.sectionTitle),
              const Spacer(),
              GestureDetector(
                onTap: onViewAll,
                child: Text('See all →',
                    style: WaveType.label.copyWith(
                      color: waveAccent(context),
                      fontSize: 12,
                    )),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (recentPlays.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('No recent playback history yet.',
                  style: WaveType.meta.copyWith(color: waveTextSecondary(context))),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: math.min(5, recentPlays.length),
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, i) =>
                  _RecentPlayItem(item: recentPlays[i]),
            ),
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
    final dark = waveIsDark(context);

    return Container(
      padding: const EdgeInsets.all(20),
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
                  size: 16, color: waveAccent(context)),
              const SizedBox(width: 8),
              Text('Top Tracks',
                  style: WaveType.sectionTitle.copyWith(fontSize: 16)),
              const SizedBox(width: 10),
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
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Center(
                child: Text('No tracks played during this period.',
                    style: WaveType.meta
                        .copyWith(color: waveTextSecondary(context))),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: tracks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, i) =>
                  _TrackRowItem(track: tracks[i], rank: i + 1),
            ),
        ],
      ),
    );
  }
}

/// Full Top Artists View Tab (Individual artists with high-res photos)
class _ArtistsTab extends StatelessWidget {
  final List<StatArtist> artists;
  const _ArtistsTab({required this.artists});

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);

    return Container(
      padding: const EdgeInsets.all(20),
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
                  size: 16, color: waveAccent(context)),
              const SizedBox(width: 8),
              Text('Top Artists',
                  style: WaveType.sectionTitle.copyWith(fontSize: 16)),
              const SizedBox(width: 10),
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
          const SizedBox(height: 16),
          if (artists.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Center(
                child: Text('No artists recorded during this period.',
                    style: WaveType.meta
                        .copyWith(color: waveTextSecondary(context))),
              ),
            )
          else
            LayoutBuilder(builder: (context, c) {
              final cols = c.maxWidth < 600
                  ? 2
                  : (c.maxWidth < 900 ? 3 : (c.maxWidth < 1200 ? 4 : 5));
              final itemWidth = (c.maxWidth - (cols - 1) * 14) / cols;

              return Wrap(
                spacing: 14,
                runSpacing: 14,
                children: artists.asMap().entries.map((entry) {
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
        ],
      ),
    );
  }
}

/// Full Top Albums View Tab
class _AlbumsTab extends StatelessWidget {
  final List<StatAlbum> albums;
  const _AlbumsTab({required this.albums});

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);

    return Container(
      padding: const EdgeInsets.all(20),
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
              Icon(FluentIcons.album, size: 16, color: waveAccent(context)),
              const SizedBox(width: 8),
              Text('Top Albums',
                  style: WaveType.sectionTitle.copyWith(fontSize: 16)),
              const SizedBox(width: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: dark
                      ? WaveColors.surfaceRaised
                      : WaveColors.lightOutlineSoft,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text('${albums.length} albums',
                    style: WaveType.overline.copyWith(
                      fontSize: 9.5,
                      color: waveTextSecondary(context),
                    )),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (albums.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Center(
                child: Text(
                  'No album scrobbles found for this period. Connect Last.fm or listen to full albums.',
                  style: WaveType.meta
                      .copyWith(color: waveTextSecondary(context)),
                ),
              ),
            )
          else
            LayoutBuilder(builder: (context, c) {
              final cols = c.maxWidth < 600
                  ? 2
                  : (c.maxWidth < 900 ? 3 : (c.maxWidth < 1200 ? 4 : 5));
              final itemWidth = (c.maxWidth - (cols - 1) * 14) / cols;

              return Wrap(
                spacing: 14,
                runSpacing: 14,
                children: albums.asMap().entries.map((entry) {
                  return SizedBox(
                    width: itemWidth,
                    child: _AlbumGridCard(
                      album: entry.value,
                      rank: entry.key + 1,
                    ),
                  );
                }).toList(),
              );
            }),
        ],
      ),
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
    final dark = waveIsDark(context);

    return Container(
      padding: const EdgeInsets.all(20),
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
                  size: 16, color: waveAccent(context)),
              const SizedBox(width: 8),
              Text('Playback History Stream',
                  style: WaveType.sectionTitle.copyWith(fontSize: 16)),
              const Spacer(),
              GestureDetector(
                onTap: () => context.go('/history'),
                child: Text(
                  'Full library history →',
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
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Center(
                child: Text('No recent playback records.',
                    style: WaveType.meta
                        .copyWith(color: waveTextSecondary(context))),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: recentPlays.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, i) =>
                  _RecentPlayItem(item: recentPlays[i]),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared Row & Grid Widgets
// ---------------------------------------------------------------------------

class _TrackRowItem extends ConsumerWidget {
  final StatTrack track;
  final int rank;

  const _TrackRowItem({required this.track, required this.rank});

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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: WaveRadius.controlsRadius,
          color: Colors.transparent,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text(
                '$rank',
                style: WaveType.label.copyWith(
                  fontSize: 12.5,
                  color: rankColor,
                  fontWeight:
                      isTop3 ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
            WaveArtwork(
              url: track.artworkUrl,
              size: 42,
              radius: WaveRadius.artwork,
              title: track.name,
              artist: track.artist,
              label: track.name,
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
                  const SizedBox(height: 1),
                  WaveArtistLine(artist: track.artist),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
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
              width: 26,
              child: Text(
                '$rank',
                style: WaveType.label.copyWith(
                  fontSize: 12.5,
                  color: rankColor,
                  fontWeight:
                      isTop3 ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
            ClipOval(
              child: WaveArtwork(
                url: artist.artworkUrl,
                size: 42,
                kind: ArtworkKind.artist,
                title: artist.name,
                artist: artist.name,
                label: artist.name,
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
            const SizedBox(width: 12),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
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
              scale: _pressed ? 0.97 : (_hover ? 1.03 : 1.0),
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
                      ],
                    ),
                    foregroundDecoration: BoxDecoration(
                      borderRadius: radius,
                      border: Border.all(color: waveDivider(context)),
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
                        color: Colors.black.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '#${widget.rank}',
                        style: WaveType.label.copyWith(
                          fontSize: 10.5,
                          color: Colors.white,
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
              style: WaveType.trackTitle.copyWith(fontSize: 13),
            ),
            const SizedBox(height: 2),
            Text(
              '${a.playCount} plays',
              style: WaveType.meta.copyWith(
                fontSize: 11,
                color: waveTextSecondary(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlbumGridCard extends StatelessWidget {
  final StatAlbum album;
  final int rank;

  const _AlbumGridCard({required this.album, required this.rank});

  @override
  Widget build(BuildContext context) {
    return WavePressable(
      onTap: () {
        waveOpen(
          context,
          waveAlbumLocation(
            browseId: '',
            title: album.name,
            artist: album.artist,
            artworkUrl: album.artworkUrl,
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              WaveArtwork(
                url: album.artworkUrl,
                size: 140,
                radius: WaveRadius.artwork,
                title: album.name,
                artist: album.artist,
                kind: ArtworkKind.album,
                label: album.name,
              ),
              Positioned(
                left: 6,
                top: 6,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '#$rank',
                    style: WaveType.label.copyWith(
                      fontSize: 10,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            album.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: WaveType.trackTitle.copyWith(fontSize: 12.5),
          ),
          const SizedBox(height: 1),
          WaveArtistLine(
            artist: album.artist,
            style: WaveType.meta.copyWith(fontSize: 11),
          ),
          Text(
            '${album.playCount} plays',
            style: WaveType.meta.copyWith(
              fontSize: 10.5,
              color: waveTextTertiary(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentPlayItem extends ConsumerWidget {
  final ({String title, String artist, int timestampMillis, String artworkUrl}) item;
  const _RecentPlayItem({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return WavePressable(
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
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: WaveRadius.controlsRadius,
          color: Colors.transparent,
        ),
        child: Row(
          children: [
            WaveArtwork(
              url: item.artworkUrl,
              size: 38,
              radius: WaveRadius.artwork,
              title: item.title,
              artist: item.artist,
              label: item.title,
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
                    style: WaveType.trackTitle.copyWith(fontSize: 13),
                  ),
                  const SizedBox(height: 1),
                  WaveArtistLine(artist: item.artist),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              relativeTime(
                DateTime.fromMillisecondsSinceEpoch(item.timestampMillis),
              ),
              style: WaveType.meta.copyWith(
                fontSize: 11.5,
                color: waveTextTertiary(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
