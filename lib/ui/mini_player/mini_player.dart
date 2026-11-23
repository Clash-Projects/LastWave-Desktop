import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/track_actions.dart' show formatDuration;
import '../../core/storage/prefs.dart';
import '../../core/audio/stream_models.dart' show PlayableTrack;
import '../../features/lyrics/karaoke_lyrics_view.dart' show lyricsOffsetProvider;
import '../../features/lyrics/lyrics_models.dart';
import '../../features/player/playback_service.dart';
import '../lyrics/lyrics_panel.dart' show waveLyricsProvider;
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip;
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// Small floating mini player window content, in one of four looks picked
/// by [Prefs.miniPlayerStyle] (window size per style lives in
/// [miniPlayerBounds]):
///
/// - `classic`: grip + artwork + title/artist + transport + window actions.
/// - `compact`: slim strip, artwork + title + play/next + expand/close.
/// - `card`: full-bleed square cover, controls over a bottom scrim.
/// - `ambient`: wide panel lit by the blurred cover, with a timed scrubber.
///
/// Clicking and dragging anywhere on the non-button areas moves the native
/// desktop window; double-click expands.
/// Window size and minimum size of the miniplayer for a [Prefs.miniPlayerStyle].
/// [lyricsWide]: the lyrics style while the song has synced lyrics.
({Size size, Size min}) miniPlayerBounds(String style,
        {bool lyricsWide = false}) =>
    switch (style) {
      'compact' => (size: const Size(320, 56), min: const Size(260, 48)),
      'card' => (size: const Size(280, 280), min: const Size(220, 220)),
      'ambient' => (size: const Size(440, 120), min: const Size(360, 108)),
      'lyrics' => lyricsWide
          ? (size: const Size(480, 148), min: const Size(380, 130))
          : (size: const Size(440, 120), min: const Size(360, 108)),
      _ => (size: const Size(380, 78), min: const Size(300, 64)),
    };

/// True when [lyrics] are word- or line-synced (plain text doesn't count).
bool miniHasSyncedLyrics(LyricsResult? lyrics) =>
    lyrics != null &&
    (lyrics.isSynced || lyrics.isWordSynced) &&
    lyrics.lines.isNotEmpty;

class WaveMiniPlayer extends ConsumerStatefulWidget {
  final VoidCallback onClose;
  final VoidCallback onExpand;
  const WaveMiniPlayer({
    super.key,
    required this.onClose,
    required this.onExpand,
  });

  @override
  ConsumerState<WaveMiniPlayer> createState() => _WaveMiniPlayerState();
}

class _WaveMiniPlayerState extends ConsumerState<WaveMiniPlayer> {
  bool _hover = false;

  void _minimizeMini() {
    windowManager.minimize().catchError((Object _) {});
  }

  List<Widget> _windowActions({bool onDark = false, bool minimize = true}) => [
        if (minimize)
          _MiniGlyph(
            tooltip: 'Minimize',
            icon: FluentIcons.chrome_minimize,
            onTap: _minimizeMini,
            size: 11,
            onDark: onDark,
          ),
        _MiniGlyph(
          tooltip: 'Expand to window',
          icon: WaveIcons.expand,
          onTap: widget.onExpand,
          size: 12,
          onDark: onDark,
        ),
        _MiniGlyph(
          tooltip: 'Close mini player',
          icon: FluentIcons.chrome_close,
          onTap: widget.onClose,
          danger: true,
          size: 12,
          onDark: onDark,
        ),
      ];

  @override
  void initState() {
    super.initState();
    _setTop(true);
  }

  @override
  void dispose() {
    _setTop(false);
    super.dispose();
  }

  Future<void> _setTop(bool value) async {
    try {
      await windowManager.setAlwaysOnTop(value);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final style = ref.read(prefsProvider).miniPlayerStyle;
    final snap = ref.watch(playbackServiceProvider.select((s) => (
          current: s.current,
          isPlaying: s.isPlaying,
          isBuffering: s.isBuffering,
        )));
    final notifier = ref.read(playbackServiceProvider.notifier);
    final current = snap.current;
    // Card/ambient paint the cover edge to edge; the others sit on the theme.
    final artBacked = current != null &&
        (style == 'card' || style == 'ambient' || style == 'lyrics');

    final Widget content = current == null
        ? _buildEmptyState(context)
        : switch (style) {
            'compact' => _buildCompact(context, current, snap, notifier),
            'card' => _buildCard(context, current, snap, notifier),
            'ambient' => _buildAmbient(context, current, snap, notifier),
            'lyrics' => _buildLyrics(context, current, snap, notifier),
            _ => _buildPlayerContent(context, current, snap, notifier),
          };

    // Draggable card container that fills the miniplayer window
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) {
          try {
            windowManager.startDragging();
          } catch (_) {}
        },
        onDoubleTap: widget.onExpand,
        child: Container(
          width: double.infinity,
          height: double.infinity,
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: artBacked
                ? Colors.black
                : (dark ? waveSurfaceRaised(context) : waveSurface(context)),
            border: Border.all(
              color: artBacked
                  ? Colors.white.withValues(alpha: 0.08)
                  : waveDivider(context).withValues(alpha: dark ? 0.35 : 0.6),
              width: 1,
            ),
          ),
          // macOS keeps the native traffic lights above this chromeless
          // window even in mini mode; clear their corner (they end
          // around x=74) so the grip/artwork do not sit underneath them.
          // The card style has no left-edge content row, so it skips this.
          child: Padding(
            padding: EdgeInsets.only(
              left: Platform.isMacOS && !(artBacked && style == 'card')
                  ? 76
                  : 0,
            ),
            child: content,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.move,
            child: Icon(
              FluentIcons.gripper_dots_vertical,
              size: 14,
              color: waveTextSecondary(context).withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(width: 8),
          Icon(WaveIcons.music, size: 16, color: waveTextSecondary(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'No track playing',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WaveType.meta.copyWith(fontSize: 12),
            ),
          ),
          _MiniGlyph(
            tooltip: 'Minimize',
            icon: FluentIcons.chrome_minimize,
            onTap: () {
              try {
                windowManager.minimize();
              } catch (_) {}
            },
            size: 11,
          ),
          _MiniGlyph(
            tooltip: 'Expand to window',
            icon: WaveIcons.expand,
            onTap: widget.onExpand,
            size: 12,
          ),
          _MiniGlyph(
            tooltip: 'Close mini player',
            icon: FluentIcons.chrome_close,
            onTap: widget.onClose,
            danger: true,
            size: 12,
          ),
        ],
      ),
    );
  }

  /// Title over artist, tap to expand.
  Widget _titles(
    dynamic current, {
    double titleSize = 12,
    double artistSize = 11,
    bool onDark = false,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onExpand,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              current.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WaveType.trackTitle.copyWith(
                fontSize: titleSize,
                fontWeight: FontWeight.w600,
                color: onDark ? Colors.white : null,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              current.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WaveType.meta.copyWith(
                fontSize: artistSize,
                color: onDark ? Colors.white.withValues(alpha: 0.72) : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _artwork(dynamic current, double size, {double? radius}) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onExpand,
        child: WaveArtwork(
          url: current.artworkUrl,
          videoId: current.videoId,
          size: size,
          radius: radius ?? WaveRadius.artwork,
          label: current.title,
        ),
      ),
    );
  }

  List<Widget> _transport(
    dynamic snap,
    dynamic notifier, {
    double playSize = 32,
    bool previous = true,
    bool onDark = false,
  }) =>
      [
        if (previous) ...[
          _MiniGlyph(
            tooltip: 'Previous',
            icon: WaveIcons.previous,
            onTap: notifier.previous,
            size: 13,
            onDark: onDark,
          ),
          const SizedBox(width: 2),
        ],
        _MiniPlay(
          playing: snap.isPlaying,
          buffering: snap.isBuffering,
          onTap: notifier.toggle,
          size: playSize,
          onDark: onDark,
        ),
        const SizedBox(width: 2),
        _MiniGlyph(
          tooltip: 'Next',
          icon: WaveIcons.next,
          onTap: notifier.next,
          size: 13,
          onDark: onDark,
        ),
      ];

  Widget _buildPlayerContent(
    BuildContext context,
    dynamic current,
    dynamic snap,
    dynamic notifier,
  ) {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                // Grip indicator for dragging window
                MouseRegion(
                  cursor: SystemMouseCursors.move,
                  child: Container(
                    padding: const EdgeInsets.only(right: 6, left: 2),
                    color: Colors.transparent,
                    child: Icon(
                      FluentIcons.gripper_dots_vertical,
                      size: 14,
                      color: waveTextSecondary(context).withValues(alpha: 0.5),
                    ),
                  ),
                ),
                _artwork(current, 46),
                const SizedBox(width: 8),
                Expanded(child: _titles(current)),
                const SizedBox(width: 4),
                ..._transport(snap, notifier),
                const SizedBox(width: 4),
                // Subtle divider between transport and window actions
                Container(
                  width: 1,
                  height: 18,
                  color: waveDivider(context).withValues(alpha: 0.6),
                ),
                const SizedBox(width: 4),
                _MiniGlyph(
                  tooltip: 'Minimize',
                  icon: FluentIcons.chrome_minimize,
                  onTap: () {
                    try {
                      windowManager.minimize();
                    } catch (_) {}
                  },
                  size: 11,
                ),
                _MiniGlyph(
                  tooltip: 'Expand to window',
                  icon: WaveIcons.expand,
                  onTap: widget.onExpand,
                  size: 12,
                ),
                _MiniGlyph(
                  tooltip: 'Close mini player',
                  icon: FluentIcons.chrome_close,
                  onTap: widget.onClose,
                  danger: true,
                  size: 12,
                ),
              ],
            ),
          ),
        ),
        const RepaintBoundary(child: _MiniProgress()),
      ],
    );
  }

  Widget _buildCompact(
    BuildContext context,
    dynamic current,
    dynamic snap,
    dynamic notifier,
  ) {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 8, right: 6),
            child: Row(
              children: [
                _artwork(current, 36, radius: 8),
                const SizedBox(width: 10),
                Expanded(child: _titles(current)),
                const SizedBox(width: 4),
                ..._transport(snap, notifier, playSize: 28, previous: false),
                const SizedBox(width: 2),
                // Window actions fade in on hover to keep the strip quiet.
                AnimatedOpacity(
                  opacity: _hover ? 1 : 0.45,
                  duration: waveMotion(
                      context, const Duration(milliseconds: 160)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: _windowActions(minimize: false),
                  ),
                ),
              ],
            ),
          ),
        ),
        const RepaintBoundary(child: _MiniProgress(slim: true)),
      ],
    );
  }

  Widget _buildCard(
    BuildContext context,
    dynamic current,
    dynamic snap,
    dynamic notifier,
  ) {
    final fade = waveMotion(context, const Duration(milliseconds: 180));
    return Stack(
      fit: StackFit.expand,
      children: [
        _CoverFill(current: current),
        // Scrim: a light top band for the window actions (hover only) and a
        // deep bottom band for the text and controls.
        AnimatedContainer(
          duration: fade,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: _hover ? 0.5 : 0),
                Colors.transparent,
                Colors.transparent,
                Colors.black.withValues(alpha: 0.88),
              ],
              stops: const [0, 0.28, 0.38, 1],
            ),
          ),
        ),
        Positioned(
          top: 6,
          right: 6,
          child: IgnorePointer(
            ignoring: !_hover,
            child: AnimatedOpacity(
              opacity: _hover ? 1 : 0,
              duration: fade,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: _windowActions(onDark: true),
              ),
            ),
          ),
        ),
        Positioned(
          left: 14,
          right: 14,
          bottom: 10,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _titles(current, titleSize: 15, artistSize: 12, onDark: true),
              const SizedBox(height: 8),
              const RepaintBoundary(
                child: _MiniProgress(onDark: true, showTimes: true),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: _transport(snap, notifier,
                    playSize: 40, onDark: true),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Ambient panel; the window widens to show one synced lyric line when
  /// the song has word- or line-synced lyrics, else stays ambient-sized.
  Widget _buildLyrics(
    BuildContext context,
    PlayableTrack current,
    dynamic snap,
    dynamic notifier,
  ) {
    final lyrics = ref.watch(waveLyricsProvider(current)).valueOrNull;
    final synced = miniHasSyncedLyrics(lyrics);
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitLyrics(synced));
    return _buildAmbient(
      context,
      current,
      snap,
      notifier,
      lyricLine: synced ? _MiniLyricLine(track: current, lyrics: lyrics!) : null,
    );
  }

  bool? _lyricsWide;

  /// Resize for the lyric line, keeping the right edge where it is (the
  /// miniplayer usually sits at the right of the screen).
  Future<void> _fitLyrics(bool wide) async {
    if (!mounted || _lyricsWide == wide) return;
    final first = _lyricsWide == null;
    _lyricsWide = wide;
    // The shell already opened at the narrow size.
    if (first && !wide) return;
    final bounds = miniPlayerBounds('lyrics', lyricsWide: wide);
    try {
      final pos = await windowManager.getPosition();
      final size = await windowManager.getSize();
      await windowManager.setMinimumSize(bounds.min);
      await windowManager.setBounds(Rect.fromLTWH(
        pos.dx + size.width - bounds.size.width,
        pos.dy,
        bounds.size.width,
        bounds.size.height,
      ));
    } catch (_) {}
  }

  Widget _buildAmbient(
    BuildContext context,
    dynamic current,
    dynamic snap,
    dynamic notifier, {
    Widget? lyricLine,
  }) {
    final hasLyrics = lyricLine != null;
    final artSize = hasLyrics ? 104.0 : 92.0;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Blurred cover glow + scrim so white text always reads.
        RepaintBoundary(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
                sigmaX: 30, sigmaY: 30, tileMode: ui.TileMode.clamp),
            child: _CoverFill(current: current, decodeSize: 160),
          ),
        ),
        ColoredBox(color: Colors.black.withValues(alpha: 0.38)),
        Padding(
          padding: EdgeInsets.fromLTRB(12, hasLyrics ? 10 : 12, 8, 10),
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.45),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: _artwork(current, artSize, radius: 10),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: hasLyrics
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: _titles(current,
                                      titleSize: 13.5,
                                      artistSize: 11.5,
                                      onDark: true),
                                ),
                              ),
                              AnimatedOpacity(
                                opacity: _hover ? 1 : 0.55,
                                duration: waveMotion(
                                    context, const Duration(milliseconds: 160)),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: _windowActions(onDark: true),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              ..._transport(snap, notifier,
                                  playSize: 32, onDark: true),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: RepaintBoundary(
                                  child: _MiniProgress(
                                      onDark: true, showTimes: true),
                                ),
                              ),
                              const SizedBox(width: 4),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: RepaintBoundary(child: lyricLine),
                          ),
                        ],
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: _titles(current,
                                      titleSize: 14,
                                      artistSize: 12,
                                      onDark: true),
                                ),
                              ),
                              AnimatedOpacity(
                                opacity: _hover ? 1 : 0.55,
                                duration: waveMotion(
                                    context, const Duration(milliseconds: 160)),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: _windowActions(onDark: true),
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              ..._transport(snap, notifier,
                                  playSize: 34, onDark: true),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: RepaintBoundary(
                                  child: _MiniProgress(
                                      onDark: true, showTimes: true),
                                ),
                              ),
                              const SizedBox(width: 4),
                            ],
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Cover scaled to cover the whole box (cropping the long side).
class _CoverFill extends StatelessWidget {
  final dynamic current;
  final double decodeSize;
  const _CoverFill({required this.current, this.decodeSize = 320});
  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: WaveArtwork(
          url: current.artworkUrl,
          videoId: current.videoId,
          size: decodeSize,
          radius: 0,
          label: current.title,
        ),
      ),
    );
  }
}

/// Accent disc + on-accent glyph (dock parity, scaled down). On artwork
/// backgrounds ([onDark]) it becomes a white disc with a dark glyph.
class _MiniPlay extends StatelessWidget {
  final bool playing;
  final bool buffering;
  final VoidCallback onTap;
  final double size;
  final bool onDark;
  const _MiniPlay({
    required this.playing,
    required this.buffering,
    required this.onTap,
    this.size = 32,
    this.onDark = false,
  });
  @override
  Widget build(BuildContext context) {
    // The dock renders the accent with a luminance-derived glyph; the mini
    // player used to hardcode off-white + black, which broke under the
    // off-white "LastWave neutral" accent and under light accents.
    final fill = onDark ? Colors.white : waveAccent(context);
    final glyph = onDark ? Colors.black : onAccentFor(fill);
    final iconSize = size * 0.44;
    return LWTooltip(
      message: playing ? 'Pause' : 'Play',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fill,
              boxShadow: onDark
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Center(
              child: buffering
                  ? SizedBox(
                      width: iconSize,
                      height: iconSize,
                      child: ProgressRing(
                        strokeWidth: 2.5,
                        activeColor: glyph,
                        backgroundColor: glyph.withValues(alpha: 0.25),
                      ),
                    )
                  : Icon(
                      playing ? WaveIcons.pause : WaveIcons.play,
                      size: iconSize,
                      color: glyph,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Sole position subscriber in the mini player with click-to-seek support.
class _MiniProgress extends ConsumerWidget {
  final bool onDark;
  final bool showTimes;
  final bool slim;
  const _MiniProgress({
    this.onDark = false,
    this.showTimes = false,
    this.slim = false,
  });
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final clock = ref.watch(playbackServiceProvider.select((s) => (
          position: s.position,
          duration: s.duration,
        )));
    final totalMs = clock.duration.inMilliseconds;
    final progress = totalMs > 0
        ? (clock.position.inMilliseconds / totalMs).clamp(0.0, 1.0)
        : 0.0;
    final track = onDark
        ? Colors.white.withValues(alpha: 0.22)
        : (dark ? Colors.white : Colors.black).withValues(alpha: 0.12);
    final fill = onDark ? Colors.white : WaveColors.defaultAccent;
    final barHeight = showTimes ? 3.0 : (slim ? 2.0 : 2.5);

    final bar = LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) {
          if (totalMs <= 0 || constraints.maxWidth <= 0) return;
          final ratio =
              (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
          ref
              .read(playbackServiceProvider.notifier)
              .seek(Duration(milliseconds: (ratio * totalMs).round()));
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            height: showTimes ? 14 : 4,
            alignment:
                showTimes ? Alignment.center : Alignment.bottomCenter,
            child: ClipRRect(
              borderRadius:
                  BorderRadius.circular(showTimes ? barHeight / 2 : 0),
              child: Container(
                height: barHeight,
                alignment: Alignment.centerLeft,
                color: track,
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: progress,
                  child: Container(color: fill),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!showTimes) return bar;

    final timeStyle = WaveType.meta.copyWith(
      fontSize: 10,
      height: 1,
      color: Colors.white.withValues(alpha: 0.7),
      fontFeatures: const [ui.FontFeature.tabularFigures()],
    );
    return Row(
      children: [
        Text(formatDuration(clock.position), style: timeStyle),
        const SizedBox(width: 8),
        Expanded(child: bar),
        const SizedBox(width: 8),
        Text(formatDuration(clock.duration), style: timeStyle),
      ],
    );
  }
}

class _MiniGlyph extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;
  final double size;

  /// White glyphs for artwork-backed styles, regardless of theme.
  final bool onDark;
  const _MiniGlyph({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.danger = false,
    this.size = 13,
    this.onDark = false,
  });

  @override
  State<_MiniGlyph> createState() => _MiniGlyphState();
}

class _MiniGlyphState extends State<_MiniGlyph> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dark = widget.onDark || waveIsDark(context);
    return LWTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration:
                waveMotion(context, const Duration(milliseconds: 120)),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hover
                  ? (widget.danger
                      ? WaveColors.danger.withValues(alpha: 0.85)
                      : (dark
                          ? Colors.white
                              .withValues(alpha: widget.onDark ? 0.18 : 0.1)
                          : Colors.black.withValues(alpha: 0.06)))
                  : Colors.transparent,
            ),
            child: Center(
              child: Icon(
                widget.icon,
                size: widget.size,
                color: _hover
                    ? (widget.danger
                        ? Colors.white
                        : (dark ? Colors.white : Colors.black))
                    : (widget.onDark
                        ? Colors.white.withValues(alpha: 0.85)
                        : waveTextSecondary(context)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The synced lyric line playing now, up to 2-3 lines, fading as lines change.
/// The only position subscriber besides the scrubber.
class _MiniLyricLine extends ConsumerWidget {
  final PlayableTrack track;
  final LyricsResult lyrics;
  const _MiniLyricLine({required this.track, required this.lyrics});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offset = ref.watch(lyricsOffsetProvider(track.queueKey));
    final positionMs = ref.watch(playbackServiceProvider
            .select((s) => s.position.inMilliseconds)) +
        offset;
    final index = miniLyricIndex(lyrics.lines, positionMs);
    final rawText = index < 0 ? '' : lyrics.lines[index].text.trim();
    final text = formatMiniLyric(rawText);
    final isEmpty = text.isEmpty;

    return Align(
      alignment: Alignment.topLeft,
      child: AnimatedSwitcher(
        duration: waveMotion(context, const Duration(milliseconds: 220)),
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topLeft,
          children: [...previous, ?current],
        ),
        child: Text(
          isEmpty ? '\u266A' : text,
          key: ValueKey(index),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: WaveType.body.copyWith(
            fontSize: 12.5,
            height: 1.25,
            fontWeight: FontWeight.w600,
            color: isEmpty
                ? Colors.white.withValues(alpha: 0.45)
                : Colors.white.withValues(alpha: 0.94),
          ),
        ),
      ),
    );
  }
}

/// Normalizes spacing around punctuation (commas, periods, purna viram) so
/// lines wrap cleanly across 2-3 lines and read naturally.
String formatMiniLyric(String raw) {
  var t = raw.trim();
  if (t.isEmpty) return '';
  t = t.replaceAll(RegExp(r'\s+'), ' ');
  t = t.replaceAllMapped(RegExp(r'\s+([,.:;!?।])'), (m) => m[1]!);
  t = t.replaceAllMapped(RegExp(r'([,;])(?=[^\s\d])'), (m) => '${m[1]} ');
  return t;
}

/// Index of the line playing at [positionMs]: the last line that has
/// started, or -1 before the first.
int miniLyricIndex(List<LyricLine> lines, int positionMs) {
  var lo = 0, hi = lines.length - 1, found = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (lines[mid].timeMs <= positionMs) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return found;
}

