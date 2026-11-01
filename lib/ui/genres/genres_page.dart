import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/track_actions.dart' show playGenerated;
import '../../features/feed/feed_repository.dart';
import '../../features/feed/genre_source.dart';
import '../components/states.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

/// One page of top genres. A row starts a tag mix through Mix Lab's
/// existing generator.
class WaveGenresPage extends ConsumerStatefulWidget {
  /// Drawn inside Stats. The page title and the side-rail route stay off.
  final bool embedded;
  const WaveGenresPage({super.key, this.embedded = false});

  @override
  ConsumerState<WaveGenresPage> createState() => _WaveGenresPageState();
}

class _WaveGenresPageState extends ConsumerState<WaveGenresPage> {
  static const _periods = <(String, String)>[
    ('7day', '7 days'),
    ('1month', '30 days'),
    ('overall', 'All time'),
  ];

  String _period = '1month';
  String? _busy;
  String? _error;

  Future<void> _play(String genre) async {
    if (_busy != null) return;
    setState(() {
      _busy = genre;
      _error = null;
    });
    try {
      final tracks = await ref.read(feedRepositoryProvider).generate(
            mode: MixMode.tag,
            tag: genre,
            total: 25,
          );
      if (!mounted) return;
      if (tracks.isEmpty) {
        setState(() {
          _busy = null;
          _error = 'Nothing to play for $genre.';
        });
        return;
      }
      await playGenerated(
        ref,
        context,
        tracks.first,
        sourceLabel: genre,
        queueAll: tracks,
      );
      if (mounted) setState(() => _busy = null);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final chart = ref.watch(genreChartProvider(_period));
    final body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!widget.embedded) ...[
            Text('GENRES',
                style: WaveType.overline.copyWith(
                  color: waveAccent(context),
                )),
            const SizedBox(height: 4),
            Text('Genres', style: WaveType.pageTitle.copyWith(fontSize: 24)),
            const SizedBox(height: 4),
          ],
          Text(
            'Styles from your Last.fm listening. A tap plays songs in that style, not a track named after it.',
            style: WaveType.meta.copyWith(
              color: waveTextSecondary(context),
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final period in _periods)
                ToggleButton(
                  checked: _period == period.$1,
                  onChanged: (_) => setState(() {
                    _period = period.$1;
                    _error = null;
                  }),
                  child: Text(period.$2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          chart.when(
              loading: () => const WaveLoading(label: 'Loading genres…'),
              error: (e, _) => WaveError(
                title: 'Could not load genres',
                message: '$e',
                onRetry: () => ref.invalidate(genreChartProvider(_period)),
              ),
              data: (data) {
                if (data.bars.isEmpty) {
                  return WaveEmpty(
                    icon: WaveIcons.genres,
                    title: 'No genres yet',
                    subtitle: data.fromLastFm
                        ? 'Last.fm tags for this period were places and labels, not music styles.'
                        : 'Play a few songs whose names mention a style, or connect Last.fm for a tag chart.',
                  );
                }
                final max = data.bars.first.weight;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.fromLastFm
                          ? 'From your Last.fm tags'
                          : 'From track names in your play log',
                      style: WaveType.meta.copyWith(
                        color: waveTextTertiary(context),
                      ),
                    ),
                    const SizedBox(height: 12),
                    for (final bar in data.bars)
                      _GenreRow(
                        name: bar.name,
                        weight: bar.weight,
                        fraction: max <= 0 ? 0 : bar.weight / max,
                        busy: _busy == bar.name,
                        onTap: () => _play(bar.name),
                      ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: WaveType.meta.copyWith(
                          color: waveTextSecondary(context),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
        ],
      );
    if (widget.embedded) return body;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 22, 28, 16),
      child: body,
    );
  }
}

class _GenreRow extends StatefulWidget {
  final String name;
  final int weight;
  final double fraction;
  final bool busy;
  final VoidCallback onTap;

  const _GenreRow({
    required this.name,
    required this.weight,
    required this.fraction,
    required this.busy,
    required this.onTap,
  });

  @override
  State<_GenreRow> createState() => _GenreRowState();
}

class _GenreRowState extends State<_GenreRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent = waveAccent(context);
    final width = widget.fraction.clamp(0.04, 1.0);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.busy ? null : widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (widget.busy)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: ProgressRing(strokeWidth: 2),
                    )
                  else
                    Icon(
                      FluentIcons.play,
                      size: 12,
                      color: _hover ? accent : waveTextTertiary(context),
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.body.copyWith(
                        color: _hover ? accent : null,
                      ),
                    ),
                  ),
                  Text(
                    '${widget.weight}',
                    style: WaveType.meta.copyWith(
                      color: waveTextTertiary(context),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                height: 6,
                decoration: BoxDecoration(
                  color: (waveIsDark(context) ? Colors.white : Colors.black)
                      .withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: width,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: _hover ? 1 : 0.8),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
