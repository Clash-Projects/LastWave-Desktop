import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/track_actions.dart'
    show formatDuration, playGenerated, playableFromGenerated;
import '../../../features/feed/feed_repository.dart';
import '../../../features/innertube/innertube_api.dart';
import '../../../features/lastfm/auth_repository.dart'
    show lastFmApiProvider;
import '../../../features/player/playback_service.dart';
import '../../../features/search/shared_providers.dart'
    show databaseProvider, prefsApiKeyProvider;
import '../components/ambient.dart';
import '../components/artwork.dart';
import '../components/buttons.dart' show LWTooltip, WaveChip, WaveGhostButton, WaveLink, WavePrimaryButton;
import '../components/desktop_table.dart';
import '../components/shelf.dart';
import '../components/skeletons.dart';
import '../components/states.dart';
import '../navigation/flight.dart';
import '../navigation/wave_nav.dart';
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

  /// Sections still loading: `art`, `bio`, `popular`, `albums`. Empty once
  /// everything has landed (and for a stored snapshot).
  final Set<String> pending;
  const _ArtistDetail(
      {required this.name,
      required this.artwork,
      this.bio = '',
      required this.popular,
      required this.albums,
      required this.singles,
      this.related = const [],
      this.pending = const {}});
}

/// kv_store key prefix for the on-disk artist page snapshot.
const _artistCachePrefix = 'artist_detail_v1|';

/// A snapshot younger than this is served as-is; an older one is still
/// shown instantly but refreshed in the background (stale-while-revalidate).
const _artistCacheFresh = Duration(hours: 6);

/// Past this the snapshot is ignored and the page loads from the network.
const _artistCacheMaxAge = Duration(days: 30);

Map<String, dynamic> _trackToJson(GeneratedTrack t) => {
      'n': t.name,
      'a': t.artist,
      'al': t.album,
      'art': t.artworkUrl,
      'v': t.videoId,
      'd': t.durationSeconds,
    };

GeneratedTrack _trackFromJson(Map<String, dynamic> j) => GeneratedTrack(
      name: j['n']?.toString() ?? '',
      artist: j['a']?.toString() ?? '',
      album: j['al']?.toString() ?? '',
      artworkUrl: j['art']?.toString() ?? '',
      videoId: j['v']?.toString() ?? '',
      durationSeconds: (j['d'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _entityToJson(YouTubeMusicEntity e) => {
      'k': e.kind.name,
      'n': e.name,
      'a': e.artist,
      's': e.subtitle,
      'b': e.browseId,
      'p': e.playlistId,
      'art': e.artworkUrl,
    };

YouTubeMusicEntity _entityFromJson(Map<String, dynamic> j) =>
    YouTubeMusicEntity(
      kind: YouTubeEntityKind.values.firstWhere(
        (k) => k.name == j['k'],
        orElse: () => YouTubeEntityKind.album,
      ),
      name: j['n']?.toString() ?? '',
      artist: j['a']?.toString() ?? '',
      subtitle: j['s']?.toString() ?? '',
      browseId: j['b']?.toString() ?? '',
      playlistId: j['p']?.toString() ?? '',
      artworkUrl: j['art']?.toString() ?? '',
    );

String _encodeArtist(_ArtistDetail d) => jsonEncode({
      't': DateTime.now().millisecondsSinceEpoch,
      'art': d.artwork,
      'bio': d.bio,
      'popular': [for (final t in d.popular) _trackToJson(t)],
      'albums': [for (final e in d.albums) _entityToJson(e)],
      'singles': [for (final e in d.singles) _entityToJson(e)],
      'related': d.related,
    });

/// Decodes a stored snapshot, or null when it is missing, too old or
/// unreadable. [ageOut] receives the snapshot's age.
_ArtistDetail? _decodeArtist(String name, String? raw,
    {required void Function(Duration age) ageOut}) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    final age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch((j['t'] as num).toInt()));
    if (age > _artistCacheMaxAge) return null;
    List<Map<String, dynamic>> list(String k) =>
        ((j[k] as List?) ?? const []).whereType<Map<String, dynamic>>().toList();
    ageOut(age);
    return _ArtistDetail(
      name: name,
      artwork: j['art']?.toString() ?? '',
      bio: j['bio']?.toString() ?? '',
      popular: list('popular').map(_trackFromJson).toList(),
      albums: list('albums').map(_entityFromJson).toList(),
      singles: list('singles').map(_entityFromJson).toList(),
      related: ((j['related'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
  } catch (_) {
    return null;
  }
}

/// Streams the artist page as its sources land: every source that finishes
/// emits a fresh snapshot, so the portrait, bio, tracks and shelves each
/// appear as soon as THEIR data is ready instead of waiting for the slowest.
/// `pending` names the sections still in flight (page shows a skeleton
/// for those only). A stored snapshot is emitted once, complete.
final _artistDetailProvider = StreamProvider.autoDispose
    .family<_ArtistDetail, String>((ref, name) {
  final tube = ref.watch(innerTubeProvider);
  final api = ref.watch(lastFmApiProvider);
  final apiKey = ref.watch(prefsApiKeyProvider);
  final repo = ref.watch(feedRepositoryProvider);
  final db = ref.watch(databaseProvider);
  final q = name.trim();
  final cacheKey = '$_artistCachePrefix${q.toLowerCase()}';

  final ctrl = StreamController<_ArtistDetail>();
  ref.onDispose(ctrl.close);

  // [onUpdate] null = silent background refresh (cache only, no emissions).
  Future<_ArtistDetail> load(void Function(_ArtistDetail d)? onUpdate) async {
    Future<T> guarded<T>(Future<T> Function() run, T fallback) async {
      try {
        return await run();
      } catch (_) {
        return fallback;
      }
    }

    var art = '';
    var bio = '';
    var related = <String>[];
    var popular = <GeneratedTrack>[];
    var albums = <YouTubeMusicEntity>[];
    final pending = <String>{'art', 'bio', 'popular', 'albums'};

    _ArtistDetail snap() => _ArtistDetail(
        name: q,
        artwork: art,
        bio: bio,
        popular: popular,
        albums: albums.where((a) => !_isSingle(a.subtitle)).take(8).toList(),
        singles: albums.where((a) => _isSingle(a.subtitle)).take(8).toList(),
        related: related,
        pending: Set.of(pending));

    void done(String section) {
      pending.remove(section);
      onUpdate?.call(snap());
    }

    // Every source is independent, so all start at once and each publishes
    // the moment it lands. Each leg swallows its own failure — one dead
    // source must not blank the page.
    final artF = guarded(() async {
      final artists = await tube.searchArtists(q, limit: 3);
      art = artists.isNotEmpty ? artists.first.artworkUrl : '';
    }, null).whenComplete(() => done('art'));
    final infoF = guarded(() async {
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
      final similar = (artist?['similar'] as Map?)?['artist'];
      final simList = similar is List
          ? similar.whereType<Map>().toList()
          : similar is Map
              ? [similar]
              : <Map>[];
      bio = summary.isNotEmpty ? _cleanLastFmBio(summary) : '';
      related = simList
          .map((m) => m['name']?.toString() ?? '')
          .where((s) => s.isNotEmpty && s != q)
          .take(8)
          .toList();
    }, null).whenComplete(() => done('bio'));
    final albumsF = guarded(() async {
      albums = await tube.searchAlbums(q, limit: 12);
    }, null).whenComplete(() => done('albums'));

    final topF = guarded(() async {
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
      return list
          .map((t) => _trackFromLastFm(t, q))
          .where((t) => t.name.isNotEmpty)
          .toList();
    }, <GeneratedTrack>[]);
    final songsF = guarded(
        () => tube.searchSongs(q, limit: 25), <YouTubeMusicTrack>[]);

    final popularF = () async {
      final top = await topF;
      final songs = await songsF;
      if (top.isNotEmpty) {
        final bare = top.map((t) => _fillFromYtm(t, songs)).toList();
        GeneratedTrack plain(GeneratedTrack t) => GeneratedTrack(
              name: t.name,
              artist: t.artist,
              album: t.album,
              artworkUrl: t.artworkUrl,
              videoId: t.videoId,
              durationSeconds: t.durationSeconds,
            );
        try {
          popular = (await repo.resolveVideos(bare, limit: 20))
              .map(plain)
              .toList();
          // Rows are playable now; show them, then enrich in place.
          pending.remove('popular');
          onUpdate?.call(snap());
          // Missing album/duration lookups run in small parallel batches
          // rather than one serial search per track.
          const batch = 5;
          for (var i = 0; i < popular.length; i += batch) {
            final end = i + batch < popular.length ? i + batch : popular.length;
            final filled = await Future.wait(
                popular.sublist(i, end).map(repo.fillMissingMetadata));
            popular = [
              ...popular.sublist(0, i),
              ...filled.map(plain),
              ...popular.sublist(end),
            ];
            onUpdate?.call(snap());
          }
        } catch (_) {
          if (popular.isEmpty) popular = bare;
        }
      }
      if (popular.isEmpty) {
        // The song search already ran in parallel above — reuse it.
        popular = songs
            .take(20)
            .map((t) => GeneratedTrack(
                name: t.title,
                artist: t.artist.isNotEmpty ? t.artist : q,
                album: t.album,
                artworkUrl: t.artworkUrl,
                videoId: t.videoId,
                durationSeconds: t.durationSeconds))
            .toList();
      }
    }().whenComplete(() => done('popular'));

    await Future.wait([artF, infoF, albumsF, popularF]);
    final detail = snap();
    // Never persist an all-empty result (offline / rate-limited): it would
    // pin an empty page until the snapshot ages out.
    if (detail.popular.isNotEmpty || detail.albums.isNotEmpty) {
      try {
        db.kvSet(cacheKey, _encodeArtist(detail));
      } catch (_) {}
    }
    return detail;
  }

  void emit(_ArtistDetail d) {
    if (!ctrl.isClosed) ctrl.add(d);
  }

  // Stale-while-revalidate: a stored snapshot renders instantly; an old one
  // is refreshed in the background so the NEXT visit is current.
  Duration? age;
  String? raw;
  try {
    raw = db.kvGet(cacheKey);
  } catch (_) {}
  final cached = _decodeArtist(q, raw, ageOut: (a) => age = a);
  if (cached != null &&
      (cached.popular.isNotEmpty || cached.albums.isNotEmpty)) {
    emit(cached);
    ctrl.close();
    if (age! > _artistCacheFresh) {
      unawaited(load(null).then<void>((_) {}, onError: (_) {}));
    }
    return ctrl.stream;
  }

  // First frame: everything pending, so the skeleton shows while it loads.
  emit(_ArtistDetail(
      name: q,
      artwork: '',
      popular: const [],
      albums: const [],
      singles: const [],
      pending: const {'art', 'bio', 'popular', 'albums'}));
  load(emit).then<void>((_) {
    if (!ctrl.isClosed) ctrl.close();
  }, onError: (Object e, StackTrace s) {
    if (!ctrl.isClosed) {
      ctrl.addError(e, s);
      ctrl.close();
    }
  });
  return ctrl.stream;
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

  /// Decided on the first built frame: did the page open with everything
  /// already loaded? Gates the cover flight (see [_body]).
  bool? _flightOk;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_artistDetailProvider(widget.name));
    return async.when(
      // The name *is* the route, so the header can be real on the first frame:
      // only the portrait, bio, transport and track list have to be fetched.
      // That is what the route entrance animates — over a spinner it played on
      // an empty page and the artist looked like it never faded in, just
      // arrived late. `_body` is shared with the loaded path.
      loading: () => _body(
        _ArtistDetail(
          name: widget.name,
          artwork: '',
          popular: const [],
          albums: const [],
          singles: const [],
          pending: const {'art', 'bio', 'popular', 'albums'},
        ),
      ),
      error: (e, _) => WaveError(
        title: 'Could not load artist',
        message: '$e',
        onRetry: () => ref
            .invalidate(_artistDetailProvider(widget.name)),
      ),
      data: _body,
    );
  }

  /// Artist layout: portrait + name/meta over Popular, Albums, Singles and
  /// Related. [loading] means the detail has not answered yet — the name is
  /// already right (it came in on the route) and skeleton blocks stand in for
  /// the bio, the transport row and the track list, so the entrance animates
  /// the page the user asked for.
  Widget _body(_ArtistDetail d) {
    // Sections land independently (see the provider): each skeleton below
    // stays only until ITS data arrives.
    // The pressed cover only flies into a header that opens complete (a
    // stored snapshot). When the portrait lands a beat after the page, the
    // header is already on screen and a flight would come out of nowhere —
    // there it just fades in instead.
    _flightOk ??= d.pending.isEmpty;
    final artLoading = d.pending.contains('art');
    final bioLoading = d.pending.contains('bio');
    final listLoading = d.pending.contains('popular');
    final playingKey = ref.watch(
      playbackServiceProvider.select((s) => s.current?.queueKey),
    );
    final visiblePopular = _showAllPopular
        ? d.popular
        : d.popular.take(5).toList();
    // The provider only ever resolves a YouTube channel avatar, and the
    // resolver demotes YouTube hosts to its fallback tier anyway — so the
    // primary slot stays empty and the avatar rides along as a fallback. This
    // tile is mounted several times while the artist loads, and each fresh
    // tile paints the generic cover until its own press photo answers — that
    // is what read as the portrait blinking. The skeleton covers that window,
    // and leaving `url` unchanged keeps the photo that already resolved when
    // the detail lands, instead of invalidating it for the thumbnail.
    Widget portrait(double size) => WaveFlightTarget(
          kind: 'artist',
          id: widget.name,
          enabled: _flightOk == true && d.artwork.isNotEmpty,
          // Artist portraits are circles; the flight morphs into one.
          radius: size / 2,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              WaveArtwork.circle(
                url: '',
                fallbackUrls: [if (d.artwork.isNotEmpty) d.artwork],
                size: size,
                label: d.name,
                title: d.name,
                artist: d.name,
              ),
              if (artLoading)
                SkeletonBox(width: size, height: size, radius: size / 2),
            ],
          ),
        );
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
                    index: 0,
                    rise: 10,
                    child: WaveAmbientBand(
                      artworkUrl: d.artwork,
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
                        if (bioLoading) ...[
                          const SizedBox(height: 8),
                          const SkeletonBox(width: 240, height: 10),
                          const SizedBox(height: 6),
                          const SkeletonBox(width: 180, height: 10),
                        ] else if (d.bio.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          _ExpandableBio(
                            text: d.bio,
                            expanded: _bioExpanded,
                            onToggle: () => setState(
                                () => _bioExpanded = !_bioExpanded),
                          ),
                        ],
                        const SizedBox(height: 14),
                        if (listLoading)
                          // Reserve the transport row: the buttons only exist
                          // once there are tracks, so without this the header
                          // would jump when they land.
                          const SizedBox(height: 32)
                        else
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
                          portrait(140),
                          const SizedBox(height: 16),
                          meta,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment:
                          CrossAxisAlignment.end,
                      children: [
                        portrait(168),
                        const SizedBox(width: 22),
                        Expanded(child: meta),
                      ],
                    );
                    }),
                      ),
                    ),
                  // Skeleton track list while the artist loads; the real
                  // sections below are data-guarded, so they simply take over.
                  if (listLoading) ...[
                    const SizedBox(height: 26),
                    const SkeletonRow(count: 6),
                  ],
                  if (d.popular.isNotEmpty) ...[
                    const SizedBox(height: 26),
                    WaveEntrance(
                      index: 1,
                      rise: 8,
                      child: Row(
                      children: [
                        Text('Popular',
                            style: WaveType.sectionTitle),
                        const Spacer(),
                        if (d.popular.length > 5)
                          WaveLink(
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
                    ),
                    const SizedBox(height: 6),
                    WaveEntrance(
                      index: 2,
                      rise: 10,
                      child: WaveDesktopTable<GeneratedTrack>(
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
                    ),
                  ],
                  if (d.albums.isNotEmpty) ...[
                    const SizedBox(height: 26),
                    WaveEntrance(
                      index: 3,
                      rise: 8,
                      child: Text('Albums',
                          style: WaveType.sectionTitle),
                    ),
                    const SizedBox(height: 10),
                    WaveRail(
                      height: 196,
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
                            onTap: () => waveOpen(
                                context,
                                waveAlbumLocation(
                                  browseId: a.browseId,
                                  title: a.name,
                                  artist: d.name,
                                  artworkUrl: a.artworkUrl,
                                )),
                          ),
                        );
                      },
                    ),
                  ],
                  if (d.singles.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    WaveEntrance(
                      index: 4,
                      rise: 8,
                      child: Text('Singles & EPs',
                          style: WaveType.sectionTitle),
                    ),
                    const SizedBox(height: 10),
                    WaveRail(
                      height: 168,
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
                            subtitle: a.subtitle,
                            width: 118,
                            artSize: 118,
                            titleSize: 12,
                            artist: d.name,
                            onTap: () => waveOpen(
                                context,
                                waveAlbumLocation(
                                  browseId: a.browseId,
                                  title: a.name,
                                  artist: d.name,
                                  artworkUrl: a.artworkUrl,
                                )),
                          ),
                        );
                      },
                    ),
                  ],
                  if (d.related.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    WaveEntrance(
                      index: 5,
                      rise: 8,
                      child: Text('Related artists',
                          style: WaveType.sectionTitle),
                    ),
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
                                  waveOpen(
                                      context,
                                      '/artist/${Uri.encodeComponent(r)}');
                                  return KeyEventResult.handled;
                                }
                                return KeyEventResult.ignored;
                              },
                              child: MouseRegion(
                                cursor:
                                    SystemMouseCursors.click,
                                child: GestureDetector(
                                  onTap: () => waveOpen(
                                      context,
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
  bool _pressed = false;
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    void play() {
      _focus.requestFocus();
      widget.onTap();
    }
    return LWTooltip(
      message: widget.title,
      child: Focus(
        focusNode: _focus,
        onFocusChange: (_) => setState(() {}),
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.space)) {
            play();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
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
            onTap: play,
            child: AnimatedScale(
              scale: _pressed ? 0.97 : (_hover ? 1.03 : 1.0),
              duration: waveMotion(context, WaveMotion.fast),
              curve: Curves.easeOutCubic,
              child: AnimatedContainer(
                duration: waveMotion(context, WaveMotion.normal),
                curve: Curves.easeOutCubic,
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
                          color: waveFocusRing(context),
                          width: WaveState.focusRing)
                      : Border.all(color: Colors.transparent),
                  boxShadow: [
                    if (_hover) ...WaveElevation.lift(dark),
                  ],
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
                        Positioned.fill(
                          child: AnimatedOpacity(
                            opacity: _hover ? 1 : 0,
                            duration: waveMotion(context, WaveMotion.fast),
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Colors.black.withValues(alpha: 0.55),
                                  ],
                                ),
                                borderRadius:
                                    BorderRadius.circular(WaveRadius.artwork),
                              ),
                              child: Center(
                                child: AnimatedScale(
                                  scale: _hover ? 1.0 : 0.70,
                                  duration: waveMotion(context, WaveMotion.fast),
                                  curve: Curves.easeOutBack,
                                  child: GestureDetector(
                                    onTap: play,
                                    child: Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: waveAccent(context),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black
                                                .withValues(alpha: 0.4),
                                            blurRadius: 12,
                                          ),
                                        ],
                                      ),
                                      child: Icon(
                                          WaveIcons.play,
                                          size: 18,
                                          color: waveOnAccent(context)),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WaveType.trackTitle.copyWith(
                            fontSize: widget.titleSize,
                            color: dark
                                ? WaveColors.textPrimary
                                : WaveColors.lightTextPrimary)),
                    if (widget.subtitle.isNotEmpty)
                      Text(widget.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WaveType.meta.copyWith(
                              fontSize: 11,
                              color: dark
                                  ? WaveColors.textSecondary
                                  : WaveColors.lightTextSecondary)),
                  ],
                ),
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
              child: WaveLink(
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
