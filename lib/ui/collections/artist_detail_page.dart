import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/track_actions.dart'
    show formatDuration, playGenerated, playableFromGenerated;
import '../../../features/feed/feed_repository.dart';
import '../../../features/innertube/innertube_api.dart';
import '../../../features/lastfm/auth_repository.dart'
    show lastFmApiProvider;
import '../../../features/player/playback_service.dart';
import '../../../features/search/shared_providers.dart'
    show prefsApiKeyProvider;
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip, WaveChip, WaveGhostButton, WavePrimaryButton;
import '../components/desktop_table.dart';
import '../components/states.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/wave_icons.dart';

class _ArtistDetail {
  final String name;
  final String artwork;
  final String bio;
  final List<GeneratedTrack> popular;
  final List<YouTubeMusicEntity> albums;
  final List<YouTubeMusicEntity> singles;
  final List<String> related;
  const _ArtistDetail(
      {required this.name,
      required this.artwork,
      this.bio = '',
      required this.popular,
      required this.albums,
      required this.singles,
      this.related = const []});
}

final _artistDetailProvider = FutureProvider.autoDispose
    .family<_ArtistDetail, String>((ref, name) async {
  final tube = ref.watch(innerTubeProvider);
  final q = name.trim();
  // Portrait.
  String art = '';
  try {
    final artists = await tube.searchArtists(q, limit: 3);
    if (artists.isNotEmpty) art = artists.first.artworkUrl;
  } catch (_) {}
  // Popular: real Last.fm artist.gettoptracks (20), resolved to YTM.
  List<GeneratedTrack> popular = const [];
  String bio = '';
  List<String> related = const [];
  try {
    final api = ref.watch(lastFmApiProvider);
    final apiKey = ref.watch(prefsApiKeyProvider);
    final json = await api.get({
      'method': 'artist.gettoptracks',
      'artist': q,
      'api_key': apiKey,
      'limit': '20',
      'autocorrect': '1',
    });
    final items = json['toptracks']?['track'];
    final list = items is List
        ? items.whereType<Map<String, dynamic>>().toList()
        : items is Map<String, dynamic>
            ? [items]
            : <Map<String, dynamic>>[];
    var bare = list
        .map((t) => _trackFromLastFm(t, q))
        .where((t) => t.name.isNotEmpty)
        .toList();
    try {
      final songs = await tube.searchSongs(q, limit: 25);
      bare = bare.map((t) => _fillFromYtm(t, songs)).toList();
    } catch (_) {}
    try {
      final repo = ref.watch(feedRepositoryProvider);
      popular = await repo.resolveVideos(bare, limit: 20);
      popular = [
        for (final t in popular) await repo.fillMissingMetadata(t),
      ];
    } catch (_) {
      popular = bare;
    }
    popular = popular
        .map((t) => GeneratedTrack(
              name: t.name,
              artist: t.artist,
              album: t.album,
              artworkUrl: t.artworkUrl,
              videoId: t.videoId,
              durationSeconds: t.durationSeconds,
            ))
        .toList();
  } catch (_) {}
  if (popular.isEmpty) {
    try {
      final songs = await tube.searchSongs(q, limit: 20);
      popular = songs
          .map((t) => GeneratedTrack(
              name: t.title,
              artist: t.artist.isNotEmpty ? t.artist : q,
              album: t.album,
              artworkUrl: t.artworkUrl,
              videoId: t.videoId,
              durationSeconds: t.durationSeconds))
          .toList();
    } catch (_) {}
  }
  // Bio + related (Last.fm artist.getinfo).
  try {
    final api = ref.watch(lastFmApiProvider);
    final apiKey = ref.watch(prefsApiKeyProvider);
    final json = await api.get({
      'method': 'artist.getinfo',
      'artist': q,
      'api_key': apiKey,
      'autocorrect': '1',
    });
    final artist = json['artist'] as Map?;
    final summary =
        ((artist?['bio'] as Map?)?['summary']?.toString() ?? '')
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .trim();
    if (summary.isNotEmpty) {
      bio = _cleanLastFmBio(summary);
    }
    final similar =
        (artist?['similar'] as Map?)?['artist'];
    final simList = similar is List
        ? similar.whereType<Map>().toList()
        : similar is Map
            ? [similar]
            : <Map>[];
    related = simList
        .map((m) => m['name']?.toString() ?? '')
        .where((s) => s.isNotEmpty && s != q)
        .take(8)
        .toList();
  } catch (_) {}
  // Albums + singles.
  List<YouTubeMusicEntity> albums = const [];
  try {
    albums = await tube.searchAlbums(q, limit: 12);
  } catch (_) {}
  final fullAlbums =
      albums.where((a) => !_isSingle(a.subtitle)).take(8).toList();
  final singles =
      albums.where((a) => _isSingle(a.subtitle)).take(8).toList();
  return _ArtistDetail(
      name: q,
      artwork: art,
      bio: bio,
      popular: popular,
      albums: fullAlbums,
      singles: singles,
      related: related);
});

bool _isSingle(String subtitle) {
  final s = subtitle.toLowerCase();
  return s.contains('single') || s.contains('ep');
}

GeneratedTrack _trackFromLastFm(Map<String, dynamic> t, String artist) {
  final albumNode = t['album'];
  var album = '';
  if (albumNode is Map) {
    album = albumNode['name']?.toString() ??
        albumNode['#text']?.toString() ??
        '';
  }
  return GeneratedTrack(
    name: t['name']?.toString() ?? '',
    artist: (t['artist'] as Map?)?['name']?.toString() ?? artist,
    album: album.trim(),
    durationSeconds: _parseLastFmDuration(t['duration']),
  );
}

int _parseLastFmDuration(Object? raw) {
  var n = 0;
  if (raw is num) {
    n = raw.toInt();
  } else {
    n = int.tryParse(raw?.toString() ?? '') ?? 0;
  }
  if (n <= 0) return 0;
  if (n > 10000) n = (n / 1000).round();
  if (n > 24 * 3600) return 0;
  return n;
}

String _cleanLastFmBio(String raw) {
  var s = raw.replaceAll(RegExp(r'<[^>]*>'), ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  s = s.replaceAll(
      RegExp(r'Read more on Last\.fm\.?', caseSensitive: false), '');
  s = s.replaceAll(
      RegExp(r'User-contributed text is available under.+',
          caseSensitive: false),
      '');
  return s.trim();
}

GeneratedTrack _fillFromYtm(
    GeneratedTrack t, List<YouTubeMusicTrack> songs) {
  YouTubeMusicTrack? hit;
  var best = -1;
  for (final s in songs) {
    final titleSim = InnerTubeMusicApi.similarity(
      InnerTubeMusicApi.baseTitle(s.title),
      InnerTubeMusicApi.baseTitle(t.name),
    );
    if (titleSim < 85) continue;
    if (t.artist.isNotEmpty &&
        InnerTubeMusicApi.similarity(s.artist, t.artist) < 50) {
      continue;
    }
    if (titleSim > best) {
      best = titleSim;
      hit = s;
    }
  }
  if (hit == null) return t;
  return GeneratedTrack(
    name: t.name,
    artist: t.artist,
    album: t.album.isNotEmpty ? t.album : hit.album,
    artworkUrl: t.artworkUrl.isNotEmpty ? t.artworkUrl : hit.artworkUrl,
    videoId: t.videoId,
    durationSeconds:
        t.durationSeconds > 0 ? t.durationSeconds : hit.durationSeconds,
  );
}

/// Artist page — 168px circle + ARTIST overline + 30px name +
/// Play/Shuffle + full Popular (See-all) + Albums 136px +
/// Singles 118px + Related.
class WaveArtistPage extends ConsumerStatefulWidget {
  final String name;
  const WaveArtistPage({super.key, required this.name});
  @override
  ConsumerState<WaveArtistPage> createState() =>
      _WaveArtistPageState();
}

class _WaveArtistPageState extends ConsumerState<WaveArtistPage> {
  bool _showAllPopular = false;
  bool _bioExpanded = false;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_artistDetailProvider(widget.name));
    return async.when(
      loading: () =>
          const WaveLoading(label: 'Loading artist…'),
      error: (e, _) => WaveError(
        title: 'Could not load artist',
        message: '$e',
        onRetry: () => ref
            .invalidate(_artistDetailProvider(widget.name)),
      ),
      data: (d) {
        final playingKey = ref.watch(
          playbackServiceProvider.select((s) => s.current?.queueKey),
        );
        final visiblePopular = _showAllPopular
            ? d.popular
            : d.popular.take(5).toList();
        return WaveEntranceGroup(
          child: ListView(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(
                  maxWidth: WaveDensity.contentMax),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  WaveEntrance(
                    rise: 10,
                    child: LayoutBuilder(builder: (context, c) {
                    final meta = Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text('ARTIST',
                            style: WaveType.overline.copyWith(
                                fontSize: 10,
                                color: waveTextTertiary(
                                    context))),
                        const SizedBox(height: 6),
                        Text(d.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: WaveType.pageTitle
                                .copyWith(fontSize: 30)),
                        if (d.bio.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          _ExpandableBio(
                            text: d.bio,
                            expanded: _bioExpanded,
                            onToggle: () => setState(
                                () => _bioExpanded = !_bioExpanded),
                          ),
                        ],
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            if (d.popular.isNotEmpty)
                              WavePrimaryButton(
                                label: 'Play',
                                icon: FluentIcons.play,
                                onPressed: () =>
                                    playGenerated(
                                        ref,
                                        context,
                                        d.popular.first,
                                        sourceLabel: d.name,
                                        queueAll: d.popular),
                              ),
                            if (d.popular.isNotEmpty)
                              WaveGhostButton(
                                label: 'Shuffle',
                                icon: WaveIcons.shuffle,
                                onPressed: () {
                                  final s = List.of(
                                      d.popular)
                                    ..shuffle();
                                  playGenerated(
                                      ref, context, s.first,
                                      sourceLabel: d.name,
                                      queueAll: s);
                                },
                              ),
                          ],
                        ),
                      ],
                    );
                    if (c.maxWidth < 640) {
                      return Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          WaveArtwork.circle(
                              url: d.artwork,
                              size: 140,
                              label: d.name,
                              title: d.name,
                              artist: d.name),
                          const SizedBox(height: 16),
                          meta,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment:
                          CrossAxisAlignment.end,
                      children: [
                        WaveArtwork.circle(
                            url: d.artwork,
                            size: 168,
                            label: d.name,
                            title: d.name,
                            artist: d.name),
                        const SizedBox(width: 22),
                        Expanded(child: meta),
                      ],
                    );
                    }),
                  ),
                  if (d.popular.isNotEmpty) ...[
                    const SizedBox(height: 26),
                    Row(
                      children: [
                        Text('Popular',
                            style: WaveType.sectionTitle),
                        const Spacer(),
                        if (d.popular.length > 5)
                          HyperlinkButton(
                            onPressed: () => setState(() =>
                                _showAllPopular =
                                    !_showAllPopular),
                            child: Text(
                                _showAllPopular
                                    ? 'Show less'
                                    : 'See all (${d.popular.length})',
                                style: WaveType.label),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    WaveDesktopTable<GeneratedTrack>(
                      items: visiblePopular,
                      keyOf: (t) => t.key,
                      titleOf: (t) => t.name,
                      subtitleOf: (t) => t.artist,
                      albumOf: (t) => t.album,
                      albumSortOf: (t) => t.album.toLowerCase(),
                      artworkOf: (t) => t.artworkUrl,
                      playableOf: playableFromGenerated,
                      durationOf: (t) => t.durationSeconds > 0
                          ? formatDuration(
                              Duration(seconds: t.durationSeconds))
                          : '',
                      durationSortOf: (t) => t.durationSeconds,
                      titleSortOf: (t) => t.name.toLowerCase(),
                      artistSortOf: (t) => t.artist.toLowerCase(),
                      isCurrent: (t) => playingKey == t.key,
                      isPlaying: (t) {
                        final playing = ref.watch(
                          playbackServiceProvider.select(
                              (p) => p.isPlaying),
                        );
                        return playingKey == t.key && playing;
                      },
                      showArtistColumn: false,
                      shrinkWrap: true,
                      onPlay: (i) => playGenerated(
                          ref,
                          context,
                          visiblePopular[i],
                          sourceLabel: d.name,
                          queueAll: d.popular,
                          startIndex: d.popular
                              .indexOf(visiblePopular[i])),
                    ),
                  ],
                  if (d.albums.isNotEmpty) ...[
                    const SizedBox(height: 26),
                    Text('Albums',
                        style: WaveType.sectionTitle),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 196,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: d.albums.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(width: 12),
                        itemBuilder: (context, i) {
                          final a = d.albums[i];
                          return WaveEntrance(
                            index: i,
                            rise: 10,
                            child: _ArtistAlbumCard(
                              artworkUrl: a.artworkUrl,
                              title: a.name,
                              subtitle: a.subtitle,
                              width: 136,
                              artSize: 136,
                              artist: d.name,
                              onTap: () => context.go(
                                  '/album/${Uri.encodeComponent(a.browseId)}'),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                  if (d.singles.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    Text('Singles & EPs',
                        style: WaveType.sectionTitle),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 168,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: d.singles.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(width: 12),
                        itemBuilder: (context, i) {
                          final a = d.singles[i];
                          return WaveEntrance(
                            index: i,
                            rise: 10,
                            child: _ArtistAlbumCard(
                              artworkUrl: a.artworkUrl,
                              title: a.name,
                              subtitle: '',
                              width: 118,
                              artSize: 118,
                              titleSize: 12,
                              artist: d.name,
                              onTap: () => context.go(
                                  '/album/${Uri.encodeComponent(a.browseId)}'),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                  if (d.related.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    Text('Related artists',
                        style: WaveType.sectionTitle),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final r in d.related)
                          LWTooltip(
                            message: 'Open $r',
                            child: Focus(
                              canRequestFocus: true,
                              onKeyEvent: (node, event) {
                                if (event is KeyDownEvent &&
                                    (event.logicalKey ==
                                            LogicalKeyboardKey
                                                .enter ||
                                        event.logicalKey ==
                                            LogicalKeyboardKey
                                                .space)) {
                                  context.go(
                                      '/artist/${Uri.encodeComponent(r)}');
                                  return KeyEventResult.handled;
                                }
                                return KeyEventResult.ignored;
                              },
                              child: MouseRegion(
                                cursor:
                                    SystemMouseCursors.click,
                                child: GestureDetector(
                                  onTap: () => context.go(
                                      '/artist/${Uri.encodeComponent(r)}'),
                                  child: WaveChip(label: r),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
          ),
        );
      },
    );
  }
}

/// Hover/focus/keyboard album card shared by Albums + Singles shelves.
class _ArtistAlbumCard extends StatefulWidget {
  final String artworkUrl;
  final String title;
  final String subtitle;
  final double width;
  final double artSize;
  final double titleSize;
  final VoidCallback onTap;
  final String artist;
  const _ArtistAlbumCard({
    required this.artworkUrl,
    required this.title,
    required this.subtitle,
    required this.width,
    required this.artSize,
    this.titleSize = 12.5,
    required this.onTap,
    this.artist = '',
  });
  @override
  State<_ArtistAlbumCard> createState() => _ArtistAlbumCardState();
}

class _ArtistAlbumCardState extends State<_ArtistAlbumCard> {
  bool _hover = false;
  final FocusNode _focus = FocusNode();
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LWTooltip(
      message: widget.title,
      child: Focus(
        focusNode: _focus,
        onFocusChange: (_) => setState(() {}),
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.space)) {
            widget.onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: () {
              _focus.requestFocus();
              widget.onTap();
            },
            child: AnimatedContainer(
              duration: WaveMotion.fast,
              width: widget.width,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: _hover || _focus.hasFocus
                    ? (waveIsDark(context)
                            ? const Color(0xFFFFFFFF)
                            : const Color(0xFF000000))
                        .withValues(alpha: 0.05)
                    : Colors.transparent,
                borderRadius:
                    BorderRadius.circular(WaveRadius.artwork),
                border: _focus.hasFocus
                    ? Border.all(
                        color: WaveColors.accentDim,
                        width: WaveState.focusRing)
                    : Border.all(color: Colors.transparent),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      WaveArtwork(
                          url: widget.artworkUrl,
                          size: widget.artSize,
                          radius: WaveRadius.artwork,
                          label: widget.title,
                          title: widget.title,
                          artist: widget.artist,
                          kind: ArtworkKind.album),
                      if (_hover)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black
                                  .withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(
                                  WaveRadius.artwork),
                            ),
                            child: const Icon(WaveIcons.play,
                                size: 24, color: Colors.white),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: WaveType.trackTitle
                          .copyWith(fontSize: widget.titleSize)),
                  if (widget.subtitle.isNotEmpty)
                    Text(widget.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            WaveType.meta.copyWith(fontSize: 11)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExpandableBio extends StatelessWidget {
  final String text;
  final bool expanded;
  final VoidCallback onToggle;
  const _ExpandableBio({
    required this.text,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final style = WaveType.body.copyWith(
      color: waveTextSecondary(context),
    );
    return LayoutBuilder(builder: (context, c) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        maxLines: 3,
        ellipsis: '…',
        textDirection: Directionality.of(context),
      )..layout(maxWidth: c.maxWidth.isFinite ? c.maxWidth : 640);
      final overflows = painter.didExceedMaxLines;
      painter.dispose();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            maxLines: expanded ? null : 3,
            overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            style: style,
          ),
          if (overflows)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: HyperlinkButton(
                onPressed: onToggle,
                child: Text(
                  expanded ? 'Show less' : 'Read more',
                  style: WaveType.label,
                ),
              ),
            ),
        ],
      );
    });
  }
}
