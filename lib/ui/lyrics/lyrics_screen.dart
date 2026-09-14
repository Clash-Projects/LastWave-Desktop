import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design_system/fluent/lw_viewport.dart';
import '../../features/player/playback_service.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip;
import '../components/states.dart';
import 'lyrics_panel.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

class WaveLyricsScreen extends ConsumerStatefulWidget {
  const WaveLyricsScreen({super.key});

  @override
  ConsumerState<WaveLyricsScreen> createState() => _WaveLyricsScreenState();
}

class _WaveLyricsScreenState extends ConsumerState<WaveLyricsScreen> {
  bool _artwork = true;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(
      playbackServiceProvider.select((state) => state.current),
    );
    if (current == null) {
      return const WaveEmpty(
        icon: WaveIcons.lyrics,
        title: 'Nothing playing',
        subtitle: 'Play a track to see synced lyrics here.',
      );
    }

    return LayoutBuilder(builder: (context, viewport) {
      final gutter = LwViewport.pageGutter(viewport.maxWidth);
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: LwViewport.contentMax),
          child: Padding(
            padding: EdgeInsets.fromLTRB(gutter, 20, gutter, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    LWTooltip(
                      message: 'Back to Now Playing',
                      child: IconButton(
                        onPressed: () => context.go('/now'),
                        icon: const Icon(WaveIcons.back, size: 18),
                      ),
                    ),
                    const SizedBox(width: 10),
                    if (_artwork && !_focus &&
                        (viewport.maxWidth - gutter * 2 < 760 ||
                            viewport.maxHeight < 480)) ...[
                      WaveArtwork(
                        url: current.artworkUrl,
                        videoId: current.videoId,
                        size: 40,
                        label: current.title,
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Lyrics', style: WaveType.sectionTitle),
                          Text(
                            '${current.title} · ${current.artist}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.meta.copyWith(
                              color: waveTextSecondary(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!_focus)
                      _ModeGlyph(
                        tooltip: _artwork ? 'Hide artwork' : 'Show artwork',
                        icon: FluentIcons.picture,
                        active: _artwork,
                        onTap: () => setState(() => _artwork = !_artwork),
                      ),
                    _ModeGlyph(
                      tooltip: _focus ? 'Exit focus mode' : 'Focus on lyrics',
                      icon: _focus ? FluentIcons.mini_contract : WaveIcons.expand,
                      active: _focus,
                      onTap: () => setState(() => _focus = !_focus),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Container(height: 1, color: waveDivider(context)),
                const SizedBox(height: 12),
                Expanded(
                  child: LayoutBuilder(builder: (context, content) {
                    final split = _artwork && !_focus &&
                        content.maxWidth >= 760 && content.maxHeight >= 360;
                    final reader = WaveLyricsPanel(
                      key: ValueKey(current.queueKey),
                      track: current,
                    );
                    if (!split) {
                      return Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 760),
                          child: reader,
                        ),
                      );
                    }
                    final artSize = (content.maxWidth * 0.28)
                        .clamp(200.0, 300.0).toDouble();
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: artSize,
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                WaveArtwork(
                                  url: current.artworkUrl,
                                  videoId: current.videoId,
                                  size: artSize,
                                  label: current.title,
                                ),
                                const SizedBox(height: 24),
                                Text(current.title,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: WaveType.pageTitle.copyWith(fontSize: 24)),
                                const SizedBox(height: 6),
                                Text(current.artist,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: WaveType.body.copyWith(
                                      color: waveTextSecondary(context),
                                    )),
                                if (current.album.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(current.album,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: WaveType.meta.copyWith(
                                        color: waveTextTertiary(context),
                                      )),
                                ],
                                const SizedBox(height: 20),
                                HyperlinkButton(
                                  onPressed: () => context.go('/now'),
                                  child: const Text('Open Now Playing'),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 28),
                        Container(width: 1, color: waveDivider(context)),
                        const SizedBox(width: 12),
                        Expanded(child: reader),
                      ],
                    );
                  }),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

class _ModeGlyph extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _ModeGlyph({
    required this.tooltip,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return LWTooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon, size: 18,
            color: active ? waveAccent(context) : waveTextSecondary(context)),
      ),
    );
  }
}
