import 'package:audio_video_progress_bar/audio_video_progress_bar.dart' as avp;
import 'package:fluent_ui/fluent_ui.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../theme/wave_icons.dart';

import '../../core/artwork/artwork_resolver.dart';
import '../../core/audio/stream_models.dart';
import '../../design_system/fluent/lw_viewport.dart';
import '../../features/downloads/download_manager.dart';
import '../../features/library/playlists.dart';
import '../../features/player/playback_service.dart';
import '../theme/haze.dart';
import '../../widgets/ambient.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip;
import '../components/menus.dart';
import '../components/states.dart';
import '../lyrics/lyrics_panel.dart';
import '../queue/queue_panel.dart' show QueueBodyPublic;
import '../theme/tokens.dart';

/// Dedicated Now Playing — visual centerpiece with strict scroll ownership.
///
/// ```
/// ┌─────────────────────────────────────────────┐
/// │ mode segmented (fixed)                      │
/// ├───────────────────┬─────────────────────────┤
/// │ ARTWORK + META +  │ LYRICS / CONTEXT        │
/// │ CONTROLS (fixed,  │ (independently          │
/// │ art fits viewport)│  scrollable)            │
/// └───────────────────┴─────────────────────────┘
/// ```
/// Left never forces whole-screen scroll: artwork derives from
/// constraints (`LwViewport.artworkFor`). Right owns its scroll.
/// Now Playing, Lyrics, and Queue share one fixed transport area.
class WaveNowPlayingPage extends ConsumerStatefulWidget {
  const WaveNowPlayingPage({super.key});
  @override
  ConsumerState<WaveNowPlayingPage> createState() =>
      _WaveNowPlayingPageState();
}

class _WaveNowPlayingPageState extends ConsumerState<WaveNowPlayingPage> {
  // now | lyrics | queue — three primary modes only. Default shows the
  // complete essentials without scrolling (art, title, artist, album /
  // quality, actions, progress, transport, lyrics preview).
  String _pane = 'now';
  String _preloadedKey = '';

  String get _normPane => switch (_pane) {
        'overview' || 'details' || 'artwork' => 'now',
        'up next' => 'queue',
        _ => _pane,
      };

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(
      playbackServiceProvider.select((s) => s.current),
    );
    // Preload current + next artwork off the critical path (deduped,
    // best-effort). The select returns stable string keys (not a fresh
    // List) so 1Hz position ticks don't rebuild this page (perf audit).
    final upcomingKeys = ref.watch(
      playbackServiceProvider.select((s) {
        final q = s.queue;
        final i = s.currentIndex;
        if (i < 0 || q.isEmpty) return ('', '');
        final a = i + 1 < q.length ? q[i + 1].artworkUrl : '';
        final b = i + 2 < q.length ? q[i + 2].artworkUrl : '';
        return (a, b);
      }),
    );
    if (current == null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: WaveEmpty(
            icon: WaveIcons.music,
            title: 'Nothing playing',
            subtitle:
                'Pick something from Home, Discover or Search and it will take centre stage here.',
            actionLabel: 'Browse music',
            onAction: () => context.go('/home'),
          ),
        ),
      );
    }
    if (current.queueKey != _preloadedKey) {
      _preloadedKey = current.queueKey;
      final warm = [
        current.artworkUrl,
        upcomingKeys.$1,
        upcomingKeys.$2,
      ].where((u) => u.isNotEmpty).toList();
      if (warm.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ArtworkResolver.preload(context, warm, targetPx: 640);
        });
      }
    }
    final pane = _normPane;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Canonical compact breakpoint (900): content-aware, not window.
        // At 1024 window with expanded rail, content is ~824 → narrow.
        // At 1024 with collapsed rail, content is ~964 → wide. Correct.
        final wide = constraints.maxWidth > 900;
        if (wide) {
          final gutter = LwViewport.pageGutter(constraints.maxWidth);
          return _WideSplit(
            gutter: gutter,
            pane: pane,
            onPane: (v) => setState(() => _pane = v),
            maxHeight: constraints.maxHeight,
            maxWidth: constraints.maxWidth,
          );
        }
        // Narrow: artwork derives from BOTH width and height so the
        // essentials (art + transport) fit without scrolling the page.
        final narrowArt = LwViewport.artworkFor(
          availableHeight: constraints.maxHeight,
          availableWidth: constraints.maxWidth,
          reservedForMetadata: 380,
          desired: (constraints.maxWidth - 40).clamp(220.0, 340.0).toDouble(),
          min: 160,
          max: 320,
          widthRatio: 0.9,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (pane != 'now') Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: _CompactHeader(track: current),
            ),
            const SizedBox(height: 12),
            Center(
              child: _ModeSegmented(
                pane: pane,
                onPane: (v) => setState(() => _pane = v),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Padding(
                padding:
                    const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: pane == 'now'
                    ? Column(
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              physics: const ClampingScrollPhysics(),
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 480),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Center(
                                        child: SizedBox(
                                          width: narrowArt,
                                          child: _MainColumn(
                                            artSize: narrowArt,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 24),
                                      const _LyricPreviewStatic(),
                                      const SizedBox(height: 16),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 480),
                            child: const _PlayerFooter(),
                          ),
                        ],
                      )
                    : pane == 'lyrics'
                        ? _ContextCard(
                            pane: 'lyrics',
                            onPane: (_) {},
                            hideTabs: true)
                        : const QueueBodyPublic(embedded: true),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _NowAmbient extends ConsumerWidget {
  const _NowAmbient();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(
      playbackServiceProvider.select((s) => s.current?.artworkUrl ?? ''),
    );
    if (url.isEmpty) return const SizedBox.shrink();
    return AmbientWash(artworkUrl: url, height: 320);
  }
}

/// Wide split: fixed mode bar + LEFT fixed artwork pane + RIGHT
/// independently scrollable context. Artwork derives from constraints
/// so it NEVER requires whole-screen scroll, never clips, never runs
/// under the player (shell already reserves dock height).
class _WideSplit extends StatelessWidget {
  final double gutter;
  final String pane;
  final ValueChanged<String> onPane;
  final double maxHeight;
  final double maxWidth;
  const _WideSplit({
    required this.gutter,
    required this.pane,
    required this.onPane,
    required this.maxHeight,
    required this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    // Mode bar (~34) + page padding (22+20) + inter-gap (12).
    const chromeReserved = 34.0 + 42.0 + 12.0;
    final rowHeight =
        (maxHeight - chromeReserved).clamp(320.0, double.infinity).toDouble();
    final isLyrics = pane == 'lyrics';
    // Left column: responsive — min(380, 38%) so 900–1300 windows don't
    // force left scroll; lyrics mode shrinks so words dominate.
    final contentW = maxWidth - gutter * 2;
    final leftWidth = isLyrics
        ? 280.0.clamp(240.0, contentW * 0.32)
        : (contentW * 0.38).clamp(300.0, 380.0).toDouble();
    final art = LwViewport.artworkFor(
      availableHeight: rowHeight,
      availableWidth: maxWidth,
      reservedForMetadata: isLyrics ? 260 : 330,
      desired: isLyrics ? 200 : 360,
      min: isLyrics ? 160 : 200,
      max: isLyrics ? 240 : 420,
      widthRatio: 0.34,
    );
    return Stack(
      children: [
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _NowAmbient(),
        ),
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.fromLTRB(gutter, 22, gutter, 20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: WaveDensity.contentMax,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text('Now Playing', style: WaveType.sectionTitle)),
                        _ModeSegmented(pane: pane, onPane: onPane),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: leftWidth,
                            // LEFT is fixed: art shrinks first via
                            // LwViewport; transport/actions anchored.
                            // Only extremely short windows scroll this
                            // pane — never the whole screen.
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: SingleChildScrollView(
                                    physics: const ClampingScrollPhysics(),
                                    child: _MainColumn(
                                      artSize: art.clamp(0.0, leftWidth).toDouble(),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                _PlayerFooter(pane: pane),
                              ],
                            ),
                          ),
                          const SizedBox(width: 24),
                          Expanded(
                            child: _ContextCard(
                              pane: pane,
                              onPane: onPane,
                              hideTabs: true,
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
        ),
      ],
    );
  }
}

/// Wide artwork mode: centred statement, art constrained by viewport
/// (never 480px-forced scroll). Single scroll owner, only when needed.
/// Underline segmented tabs for the wide context card (legacy path —
/// wide layout now uses [_ModeSegmented] above).
class _UnderlineTabs extends StatelessWidget {
  final String pane;
  final ValueChanged<String> onPane;
  const _UnderlineTabs({required this.pane, required this.onPane});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _UTab(
          label: 'Lyrics',
          selected: pane == 'lyrics',
          onTap: () => onPane('lyrics'),
        ),
        const SizedBox(width: 20),
        _UTab(
          label: 'Up Next',
          selected: pane == 'queue',
          onTap: () => onPane('queue'),
        ),
      ],
    );
  }
}

class _UTab extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _UTab(
      {required this.label, required this.selected, required this.onTap});
  @override
  State<_UTab> createState() => _UTabState();
}

class _UTabState extends State<_UTab> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final color = widget.selected
        ? (dark
            ? WaveColors.textPrimary
            : WaveColors.lightTextPrimary)
        : _hover
            ? (dark
                ? WaveColors.textPrimary
                : WaveColors.lightTextPrimary)
            : (dark
                ? WaveColors.textTertiary
                : WaveColors.lightTextTertiary);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color:
                    widget.selected ? accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            widget.label,
            style: WaveType.label.copyWith(color: color),
          ),
        ),
      ),
    );
  }
}

class _CompactHeader extends ConsumerWidget {
  final PlayableTrack track;
  const _CompactHeader({required this.track});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        WaveArtwork(
          url: track.artworkUrl,
          videoId: track.videoId,
          size: 88,
          radius: WaveRadius.artwork,
          label: track.title,
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.sectionTitle),
              Text(track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WaveType.body
                      .copyWith(color: waveTextSecondary(context))),
            ],
          ),
        ),
        _LikeGlyph(track: track),
      ],
    );
  }
}

class _MainColumn extends ConsumerWidget {
  final double artSize;
  const _MainColumn({this.artSize = 400});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(
      playbackServiceProvider.select((s) => s.current),
    )!;
    final dark = waveIsDark(context);
    final source = ref.watch(
      playbackServiceProvider.select((s) => s.sourceLabel),
    );
    // Fixed geometry: art reserves its box so metadata/quality arrival
    // never jumps the layout (spec §24–25).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (source.isNotEmpty)
          Text(source.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WaveType.overline.copyWith(
                  fontSize: 9.5,
                  color: dark
                      ? WaveColors.textTertiary
                      : WaveColors.lightTextTertiary)),
        if (source.isNotEmpty) const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            borderRadius:
                BorderRadius.circular(WaveRadius.artwork),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                    alpha: dark ? 0.45 : 0.18),
                blurRadius: dark ? 32 : 20,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: WaveArtwork(
            url: current.artworkUrl,
            videoId: current.videoId,
            size: artSize,
            radius: WaveRadius.artwork,
            label: current.title,
          ),
        ),
        const SizedBox(height: 18),
        Text(current.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: WaveType.pageTitle.copyWith(fontSize: 24)),
        const SizedBox(height: 3),
        GestureDetector(
          onTap: () => context.go(
              '/search?q=${Uri.encodeComponent(current.artist)}'),
          child: Text(current.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WaveType.body.copyWith(
                  fontSize: 15,
                  color: dark
                      ? WaveColors.textSecondary
                      : WaveColors.lightTextSecondary)),
        ),
        if (current.album.isNotEmpty)
          Text(current.album,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WaveType.meta.copyWith(
                  color: dark
                      ? WaveColors.textTertiary
                      : WaveColors.lightTextTertiary)),
        const SizedBox(height: 12),
        const _QualityLine(),
      ],
    );
  }
}

class _PlayerFooter extends ConsumerWidget {
  final String pane;
  const _PlayerFooter({this.pane = 'now'});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(
      playbackServiceProvider.select((state) => state.current),
    );
    if (current == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(height: 1, color: waveDivider(context)),
        const SizedBox(height: 16),
        const _MainTransport(),
        const SizedBox(height: 8),
        Center(
          child: _MainActions(track: current, pane: pane),
        ),
      ],
    );
  }
}
/// Compact Fluent segmented control — Now Playing / Lyrics / Queue.
/// Three primary modes only; small, never giant tabs.
class _ModeSegmented extends StatelessWidget {
  final String pane;
  final ValueChanged<String> onPane;
  const _ModeSegmented({required this.pane, required this.onPane});
  @override
  Widget build(BuildContext context) {
    const modes = [
      ('now', 'Now Playing'),
      ('lyrics', 'Lyrics'),
      ('queue', 'Queue'),
    ];
    final dark = waveIsDark(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: (dark ? Colors.white : Colors.black)
            .withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: waveDivider(context)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < modes.length; i++) ...[
            _ModeSeg(
              label: modes[i].$2,
              selected: pane == modes[i].$1,
              onTap: () => onPane(modes[i].$1),
            ),
            if (i < modes.length - 1) const SizedBox(width: 2),
          ],
        ],
      ),
    );
  }
}

class _ModeSeg extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ModeSeg(
      {required this.label, required this.selected, required this.onTap});
  @override
  State<_ModeSeg> createState() => _ModeSegState();
}

class _ModeSegState extends State<_ModeSeg> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: WaveMotion.fast,
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: widget.selected
                ? (dark ? Colors.white : Colors.black)
                    .withValues(alpha: 0.12)
                : _hover
                    ? (dark ? Colors.white : Colors.black)
                        .withValues(alpha: WaveState.hoverAlpha)
                    : Colors.transparent,
            borderRadius:
                BorderRadius.circular(WaveRadius.controls),
          ),
          child: Text(
            widget.label,
            style: WaveType.label.copyWith(
              fontSize: 12,
              fontWeight: widget.selected
                  ? FontWeight.w700
                  : FontWeight.w500,
              color: widget.selected
                  ? (dark
                      ? WaveColors.textPrimary
                      : WaveColors.lightTextPrimary)
                  : (dark
                      ? WaveColors.textSecondary
                      : WaveColors.lightTextSecondary),
            ),
          ),
        ),
      ),
    );
  }
}

class _QualityLine extends ConsumerWidget {
  const _QualityLine();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final error = ref.watch(
      playbackServiceProvider.select((state) => state.error),
    );
    if (error != null) {
      return Text(error,
          style: WaveType.meta.copyWith(color: waveTextSecondary(context)));
    }
    final stream = ref.watch(
      playbackServiceProvider.select((s) => s.stream),
    );
    final dark = waveIsDark(context);
    // Reserve one line so transport never jumps when stream resolves.
    if (stream == null) {
      return Text(
        'Loading audio…',
        style: WaveType.overline.copyWith(
          fontSize: 9.5,
          color: (dark
                  ? WaveColors.textTertiary
                  : WaveColors.lightTextTertiary)
              .withValues(alpha: 0.7),
        ),
      );
    }
    return Text(
      '${stream.qualityBadge} · ${stream.audioCodec}${stream.bitrateKbps > 0 ? ' · ${stream.bitrateKbps} kbps' : ''}',
      style: WaveType.overline.copyWith(
        fontSize: 9.5,
        color: dark ? WaveColors.textTertiary : WaveColors.lightTextTertiary,
      ),
    );
  }
}

class _MainTransport extends ConsumerWidget {
  const _MainTransport();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    // Transport state only — clock isolated below so position ticks
    // don't rebuild the buttons.
    final player = ref.watch(
      playbackServiceProvider.select((s) => (
        shuffleEnabled: s.shuffleEnabled,
        isPlaying: s.isPlaying,
        isBuffering: s.isBuffering,
        repeatMode: s.repeatMode,
      )),
    );
    final notifier = ref.read(playbackServiceProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Consumer(builder: (context, ref, _) {
          final clock = ref.watch(
            playbackServiceProvider.select((s) => (
              position: s.position,
              buffered: s.buffered,
              duration: s.duration,
            )),
          );
          return avp.ProgressBar(
            progress: clock.position,
            buffered: clock.buffered,
            total: clock.duration,
            onSeek: notifier.seek,
            barHeight: 4,
            thumbRadius: 6,
            thumbColor: dark ? Colors.white : Colors.black,
            thumbGlowColor: Colors.transparent,
            progressBarColor: dark ? Colors.white : Colors.black,
            bufferedBarColor: (dark ? Colors.white : Colors.black)
                .withValues(alpha: 0.18),
            baseBarColor: (dark ? Colors.white : Colors.black)
                .withValues(alpha: 0.12),
            timeLabelLocation: avp.TimeLabelLocation.sides,
            timeLabelTextStyle: WaveType.meta.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              color: dark
                  ? WaveColors.textSecondary
                  : WaveColors.lightTextSecondary,
            ),
          );
        }),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _TBtn(
                tooltip: 'Shuffle',
                icon: WaveIcons.shuffle,
                active: player.shuffleEnabled,
                onTap: notifier.toggleShuffle),
            _TBtn(
                tooltip: 'Previous',
                icon: WaveIcons.previous,
                large: true,
                onTap: notifier.previous),
            const SizedBox(width: 6),
            LWTooltip(
              message: player.isPlaying ? 'Pause' : 'Play',
              child: IconButton(
              onPressed: notifier.toggle,
              icon: Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: WaveColors.defaultAccent,
                ),
                child: player.isBuffering
                    ? const Center(
                        child: SizedBox(
                          width: 17,
                          height: 17,
                          child: ProgressRing(
                            strokeWidth: 2.5,
                            activeColor: Colors.black,
                            backgroundColor: Color(0x40000000),
                          ),
                        ),
                      )
                    : Icon(
                        player.isPlaying
                            ? WaveIcons.pause
                            : WaveIcons.play,
                        size: 24,
                        color: Colors.black,
                      ),
              ),
              ),
            ),
            const SizedBox(width: 6),
            _TBtn(
                tooltip: 'Next',
                icon: WaveIcons.next,
                large: true,
                onTap: notifier.next),
            _TBtn(
                tooltip: 'Repeat',
                icon: player.repeatMode == RepeatMode.one
                    ? WaveIcons.repeatOne
                    : WaveIcons.repeat,
                active: player.repeatMode != RepeatMode.off,
                onTap: notifier.cycleRepeat),
          ],
        ),
      ],
    );
  }
}

class _TBtn extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final bool active;
  final bool large;
  final VoidCallback onTap;
  const _TBtn(
      {required this.tooltip,
      required this.icon,
      this.active = false,
      this.large = false,
      required this.onTap});
  @override
  State<_TBtn> createState() => _TBtnState();
}

class _TBtnState extends State<_TBtn> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final color = widget.active
        ? waveAccent(context)
        : _hover
            ? (dark
                ? WaveColors.textPrimary
                : WaveColors.lightTextPrimary)
            : (dark
                ? WaveColors.textSecondary
                : WaveColors.lightTextSecondary);
    // Canonical 36px hit target (was 42px, drifted from WaveDensity).
    return LWTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 36,
            height: 36,
            color: Colors.transparent,
            child: Icon(widget.icon,
                size: widget.large ? 18 : 15, color: color),
          ),
        ),
      ),
    );
  }
}

class _LikeGlyph extends ConsumerWidget {
  final PlayableTrack track;
  const _LikeGlyph({required this.track});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(playlistRepositoryProvider);
    final liked = ref
        .read(playlistRepositoryProvider.notifier)
        .likedKeys()
        .contains(track.queueKey);
    return _TBtn(
      tooltip: liked ? 'Unlike' : 'Like',
      icon: WaveIcons.liked,
      active: liked,
      onTap: () => ref
          .read(playlistRepositoryProvider.notifier)
          .toggleLiked(StoredTrack(
              name: track.title,
              artist: track.artist,
              artworkUrl: track.artworkUrl,
              videoId: track.videoId)),
    );
  }
}

class _MainActions extends ConsumerWidget {
  final PlayableTrack track;
  final String pane;
  const _MainActions({required this.track, this.pane = 'now'});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(playlistRepositoryProvider);
    final liked = ref
        .read(playlistRepositoryProvider.notifier)
        .likedKeys()
        .contains(track.queueKey);
    final isLyrics = pane == 'lyrics';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TBtn(
          tooltip: liked ? 'Unlike' : 'Like',
          icon: WaveIcons.liked,
          active: liked,
          onTap: () => ref
              .read(playlistRepositoryProvider.notifier)
              .toggleLiked(StoredTrack(
                  name: track.title,
                  artist: track.artist,
                  artworkUrl: track.artworkUrl,
                  videoId: track.videoId)),
        ),
        _TBtn(
          tooltip: 'Download',
          icon: WaveIcons.downloadAction,
          onTap: () {
            ref.read(downloadManagerProvider.notifier).downloadTrack(
                  title: track.title,
                  artist: track.artist,
                  album: track.album,
                  artworkUrl: track.artworkUrl,
                );
          },
        ),
        _TBtn(
          tooltip: 'Add to playlist',
          icon: WaveIcons.addTo,
          onTap: () => showWaveAddToPlaylist(context, ref,
              title: track.title,
              artist: track.artist,
              artworkUrl: track.artworkUrl,
              videoId: track.videoId),
        ),
        _TBtn(
          tooltip: isLyrics
              ? 'Back to Now Playing'
              : 'Lyrics (Ctrl+L)',
          icon: WaveIcons.lyrics,
          active: isLyrics,
          onTap: () {
            if (isLyrics) {
              context.go('/now');
            } else {
              context.go('/lyrics');
            }
          },
        ),
      ],
    );
  }
}

class _ContextCard extends StatelessWidget {
  final String pane;
  final ValueChanged<String> onPane;
  final bool hideTabs;
  const _ContextCard(
      {required this.pane, required this.onPane, this.hideTabs = false});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!hideTabs) _UnderlineTabs(pane: pane, onPane: onPane),
        if (!hideTabs) const SizedBox(height: 10),
        Expanded(
          child: AnimatedSwitcher(
            duration: WaveMotion.normal,
            child: switch (pane) {
              'queue' => const QueueBodyPublic(
                  key: ValueKey('queue'), embedded: true),
              'lyrics' => const _ContextLyrics(key: ValueKey('lyrics')),
              // 'now' + legacy fallthrough → essentials + preview.
              _ => const _OverviewPane(key: ValueKey('now')),
            },
          ),
        ),
      ],
    );
  }
}

/// Overview: static lyric preview (NO nested scroll) + Up Next preview.
/// Single scroll owner = this ListView. Full lyrics live in Lyrics mode.
class _OverviewPane extends ConsumerWidget {
  const _OverviewPane({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(playbackServiceProvider.select((s) => s.queue));
    final index =
        ref.watch(playbackServiceProvider.select((s) => s.currentIndex));
    final upcoming = index >= 0 && queue.length > index + 1
        ? queue.sublist(index + 1).take(3).toList()
        : const [];
    return ListView(
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.zero,
      children: [
        Row(
          children: [
            Text('LYRICS PREVIEW',
                style: WaveType.overline.copyWith(
                    fontSize: 9.5,
                    color: waveTextTertiary(context))),
            const Spacer(),
            HyperlinkButton(
              onPressed: () => context.go('/lyrics'),
              child: const Text('Open full lyrics'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const _LyricPreviewStatic(),
        if (upcoming.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('UP NEXT',
              style: WaveType.overline.copyWith(
                  fontSize: 9.5, color: waveTextTertiary(context))),
          const SizedBox(height: 8),
          for (var i = 0; i < upcoming.length; i++)
            _UpNextPreview(
                track: upcoming[i],
                queueIndex: index + 1 + i),
        ],
      ],
    );
  }
}

/// Static first-lines preview: reserves fixed geometry (no jump when
/// lyrics load), never scrolls — eliminates nested-scroll chaos.
class _LyricPreviewStatic extends ConsumerWidget {
  const _LyricPreviewStatic();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current =
        ref.watch(playbackServiceProvider.select((s) => s.current))!;
    final async = ref.watch(waveLyricsProvider(current.queueKey));
    return WaveHaze.panel(
      base: waveIsDark(context)
          ? WaveColors.surface
          : WaveColors.lightContent,
      border: Border.all(color: waveDivider(context)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 180),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: async.when(
            loading: () => Text('Finding lyrics…',
                style: WaveType.meta.copyWith(
                    color: waveTextTertiary(context))),
            error: (_, _) => Text('Lyrics unavailable',
                style: WaveType.meta.copyWith(
                    color: waveTextTertiary(context))),
            data: (result) {
              if (result.isEmpty || result.isInstrumental) {
                return Text(
                  result.isInstrumental
                      ? 'Instrumental — no lyrics.'
                      : 'No lyrics found.',
                  style: WaveType.meta.copyWith(
                      color: waveTextTertiary(context)),
                );
              }
              final lines = result.isSynced
                  ? result.lines.take(8).map((l) => l.text).toList()
                  : result.plainLyrics.split('\n').take(8).toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < lines.length; i++)
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: 3),
                      child: Text(
                        lines[i],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: (i == 0
                                ? WaveType.lyricActive
                                : WaveType.lyricIdle)
                            .copyWith(
                          fontSize: i == 0 ? 17 : 14,
                          color: i == 0
                              ? waveTextPrimary(context)
                              : waveTextSecondary(context),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _UpNextPreview extends ConsumerWidget {
  final PlayableTrack track;
  final int queueIndex;
  const _UpNextPreview({required this.track, required this.queueIndex});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => ref
            .read(playbackServiceProvider.notifier)
            .seekToQueueItem(queueIndex),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          color: Colors.transparent,
          child: Row(
            children: [
              WaveArtwork(
                url: track.artworkUrl,
                videoId: track.videoId,
                size: 36,
                radius: WaveRadius.artwork,
                label: track.title,
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.trackTitle
                          .copyWith(fontSize: 12.5)),
                  Text(track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.meta.copyWith(
                          color: dark
                              ? WaveColors.textSecondary
                              : WaveColors
                                  .lightTextSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _ContextLyrics extends ConsumerWidget {
  const _ContextLyrics({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current =
        ref.watch(playbackServiceProvider.select((s) => s.current))!;
    return WaveLyricsPanel(
      key: ValueKey(current.queueKey),
      track: current,
    );
  }
}

