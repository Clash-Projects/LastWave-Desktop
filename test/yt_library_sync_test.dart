import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/storage/app_database.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';
import 'package:lastwave_desktop/features/library/playlists.dart';
import 'package:lastwave_desktop/features/library/yt_library_sync.dart';

StoredTrack _t(String id, [String? name]) =>
    StoredTrack(name: name ?? 'Song $id', artist: 'A', videoId: id);

Set<String> _base(Iterable<StoredTrack> tracks) =>
    {for (final t in tracks) ...baseEntries(t)};

/// In-memory YouTube Music account.
class _FakeTube implements InnerTubeMusicApi {
  YtConnection conn = const YtConnection(
    connected: true,
    profileEmail: 'a@example.com',
  );
  final List<String> likes = [];
  final Map<String, ({String title, List<String> ids})> lists = {};
  final Set<String> notEditable = {};
  bool readsBroken = false;
  int created = 0;
  final List<String> deleted = [];

  @override
  YtConnection get connection => conn;

  YtOwnedPlaylistItem _item(String id) => YtOwnedPlaylistItem(
        videoId: id,
        setVideoId: 'set-$id',
        track: YouTubeMusicTrack(videoId: id, title: 'Song $id', artist: 'A'),
      );

  @override
  Future<YtOwnedPlaylist> fetchOwnedPlaylistItems(
    String playlistId, {
    bool firstPageOnly = false,
  }) async {
    if (readsBroken) return const YtOwnedPlaylist(items: [], complete: false);
    if (playlistId == 'LM') {
      return YtOwnedPlaylist(
        items: likes.map(_item).toList(),
        complete: likes.isNotEmpty,
      );
    }
    final list = lists[playlistId];
    if (list == null) return const YtOwnedPlaylist(items: [], complete: false);
    final editable = !notEditable.contains(playlistId);
    return YtOwnedPlaylist(
      items: list.ids.map(_item).toList(),
      complete: editable,
      editable: editable,
    );
  }

  @override
  Future<List<YouTubePlaylistSummary>?> fetchAccountPlaylistsOrNull() async {
    if (readsBroken) return null;
    return [
      for (final e in lists.entries)
        YouTubePlaylistSummary(
          id: 'VL${e.key}',
          title: e.value.title,
          trackCountText: '${e.value.ids.length} tracks',
        ),
    ];
  }

  @override
  Future<bool> likeVideo(String videoId) async {
    likes.insert(0, videoId);
    return true;
  }

  @override
  Future<bool> removeVideoLike(String videoId) async => likes.remove(videoId);

  @override
  Future<String?> createRemotePlaylist(String title) async {
    final id = 'PLnew${created++}';
    lists[id] = (title: title, ids: <String>[]);
    return id;
  }

  @override
  Future<bool> renameRemotePlaylist(String playlistId, String title) async {
    final list = lists[playlistId]!;
    lists[playlistId] = (title: title, ids: list.ids);
    return true;
  }

  @override
  Future<bool> deleteRemotePlaylist(String playlistId) async {
    deleted.add(playlistId);
    lists.remove(playlistId);
    return true;
  }

  @override
  Future<bool> addVideosToRemotePlaylist(
    String playlistId,
    List<String> videoIds,
  ) async {
    lists[playlistId]!.ids.addAll(videoIds);
    return true;
  }

  @override
  Future<bool> removeVideosFromRemotePlaylist(
    String playlistId,
    List<({String setVideoId, String videoId})> removals,
  ) async {
    final doomed = removals.map((r) => r.videoId).toSet();
    lists[playlistId]!.ids.removeWhere(doomed.contains);
    return true;
  }

  @override
  Future<YouTubeMusicTrack?> findBestMatchOrNull(
    String title,
    String artist, {
    Set<String> excludedVideoIds = const {},
    bool prefetchStreams = false,
  }) async =>
      null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('planSync', () {
    test('first sync is a union and removes nothing', () {
      final plan = planSync(
        local: [_t('a'), _t('b')],
        remote: [_t('b'), _t('c')],
        base: const {},
      );
      expect(plan.addRemote.map((t) => t.videoId), ['a']);
      expect(plan.addLocal.map((t) => t.videoId), ['c']);
      expect(plan.removals, 0);
    });

    test('a removal on either side carries to the other', () {
      final base = _base([_t('a'), _t('b'), _t('c')]);
      final plan = planSync(
        local: [_t('b'), _t('c')],
        remote: [_t('a'), _t('b')],
        base: base,
      );
      expect(plan.removeRemote.map((t) => t.videoId), ['a']);
      expect(plan.removeLocal.map((t) => t.videoId), ['c']);
      expect(plan.addLocal, isEmpty);
      expect(plan.addRemote, isEmpty);
    });

    test('an incomplete read never deletes local rows', () {
      final base = _base([_t('a'), _t('b')]);
      final plan = planSync(
        local: [_t('a'), _t('b')],
        remote: [_t('a')],
        base: base,
        remoteComplete: false,
      );
      expect(plan.removeLocal, isEmpty);
      expect(plan.nextBase, contains('b'));
    });

    test('same song with different ids stays and stays stable', () {
      final local = [_t('id1', 'Same')];
      final remote = [_t('id2', 'Same')];
      final first = planSync(local: local, remote: remote, base: const {});
      expect(first.addLocal, isEmpty);
      expect(first.addRemote, isEmpty);
      final second =
          planSync(local: local, remote: remote, base: first.nextBase);
      expect(second.removals, 0);
    });

    test('recent writes are not undone by a stale read', () {
      // Just liked: YouTube's list doesn't show it yet.
      final pushed = planSync(
        local: [_t('a')],
        remote: const [],
        base: _base([_t('a')]),
        grace: const {'a'},
      );
      expect(pushed.removeLocal, isEmpty);
      // Just unliked: YouTube's list still shows it.
      final removed = planSync(
        local: const [],
        remote: [_t('b')],
        base: const {},
        grace: const {'b'},
      );
      expect(removed.addLocal, isEmpty);
    });

    test('local files with no id are never uploaded', () {
      final plan = planSync(
        local: const [
          StoredTrack(name: 'File', artist: 'A', playbackUrl: 'C:/m.flac'),
        ],
        remote: const [],
        base: const {},
      );
      expect(plan.addRemote, isEmpty);
    });
  });

  test('isBulkRemoval only trips on large, proportionally big removals', () {
    expect(isBulkRemoval(25, 26), isFalse);
    expect(isBulkRemoval(26, 40), isTrue);
    expect(isBulkRemoval(26, 500), isFalse);
  });

  group('engine', () {
    late AppDatabase db;
    late PlaylistRepository repo;
    late _FakeTube tube;
    late YtLibrarySync sync;
    var now = DateTime(2026, 11, 2);

    setUp(() {
      db = AppDatabase.inMemory();
      repo = PlaylistRepository(db);
      tube = _FakeTube();
      now = DateTime(2026, 11, 2);
      sync = YtLibrarySync(
        db,
        tube,
        repo,
        enabled: () => true,
        likePacing: Duration.zero,
        now: () => now,
      );
    });

    tearDown(() => sync.dispose());

    Future<void> pass() async {
      // Past the write grace window, as a later poll would be.
      now = now.add(const Duration(minutes: 6));
      await sync.run(force: true);
    }

    List<String> likedIds() => repo.all
        .firstWhere((p) => p.isLikedSongs)
        .tracks
        .map((t) => t.videoId)
        .toList();

    test('likes flow both ways, including removals', () async {
      tube.likes.addAll(['remote']);
      await repo.toggleLiked(_t('local'));
      await pass();
      expect(likedIds(), containsAll(['remote', 'local']));
      expect(tube.likes, containsAll(['remote', 'local']));

      await repo.toggleLiked(_t('local'));
      await pass();
      expect(tube.likes, ['remote']);

      tube.likes.add('other');
      tube.likes.remove('remote');
      await pass();
      expect(likedIds(), ['other']);
    });

    test('a dropped session deletes nothing on either side', () async {
      tube.likes.add('a');
      tube.lists['PLx'] = (title: 'Mix', ids: ['a']);
      await pass();
      tube.readsBroken = true;
      await pass();
      await pass();
      expect(likedIds(), ['a']);
      expect(repo.all.any((p) => p.title == 'Mix'), isTrue);
      expect(tube.deleted, isEmpty);
    });

    test('playlists are imported, created and edited both ways', () async {
      tube.lists['PLyt'] = (title: 'From YT', ids: ['a']);
      final mine = await repo.createCustom('From App');
      await repo.addTrack(mine.id, _t('b'));
      await pass();

      final imported = repo.all.firstWhere((p) => p.title == 'From YT');
      expect(imported.tracks.map((t) => t.videoId), ['a']);
      final uploaded =
          tube.lists.values.firstWhere((l) => l.title == 'From App');
      expect(uploaded.ids, ['b']);

      await repo.addTrack(imported.id, _t('c'));
      tube.lists['PLyt']!.ids.add('d');
      await pass();
      expect(tube.lists['PLyt']!.ids, containsAll(['a', 'c', 'd']));
      expect(
        repo.all.firstWhere((p) => p.id == imported.id).tracks.map((t) => t.videoId),
        containsAll(['a', 'c', 'd']),
      );

      await repo.removeTrack(imported.id, 'song a|a');
      await pass();
      expect(tube.lists['PLyt']!.ids, isNot(contains('a')));
    });

    test('a playlist deleted here is deleted there, and vice versa', () async {
      tube.lists['PLone'] = (title: 'One', ids: ['a']);
      tube.lists['PLtwo'] = (title: 'Two', ids: ['b']);
      await pass();

      await repo.delete(repo.all.firstWhere((p) => p.title == 'One').id);
      await pass();
      expect(tube.deleted, ['PLone']);

      tube.lists['PLthree'] = (title: 'Three', ids: ['c']);
      await pass();
      tube.lists.remove('PLtwo');
      await pass();
      expect(repo.all.any((p) => p.title == 'Two'), isTrue,
          reason: 'one missed read is not a deletion');
      await pass();
      expect(repo.all.any((p) => p.title == 'Two'), isFalse);
    });

    test('playlists saved from others stay read-only and unmirrored', () async {
      tube.lists['PLother'] = (title: 'Theirs', ids: ['a']);
      tube.notEditable.add('PLother');
      await pass();
      expect(repo.all.any((p) => p.title == 'Theirs'), isFalse);
    });

    test('switching channel uploads nothing from the previous one', () async {
      tube.likes.add('a');
      tube.lists['PLa'] = (title: 'A list', ids: ['a']);
      await pass();

      tube
        ..conn = const YtConnection(
          connected: true,
          profileEmail: 'b@example.com',
        )
        ..likes.clear()
        ..likes.add('b')
        ..lists.clear();
      await pass();
      expect(tube.likes, ['b']);
      expect(tube.lists, isEmpty);
      expect(likedIds(), ['b']);
    });

    test('a mass removal is held until approved', () async {
      final ids = [for (var i = 0; i < 40; i++) 'id$i'];
      tube.likes.addAll(ids);
      await pass();
      tube.likes
        ..clear()
        ..add('id0');
      await pass();
      expect(likedIds().length, 40);

      sync.applyHeldRemovals();
      await pumpEventQueue();
      await pass();
      expect(likedIds(), ['id0']);
    });
  });
}
