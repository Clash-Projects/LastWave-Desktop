// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/app_database.dart';
import '../../core/storage/prefs.dart';
import '../innertube/innertube_api.dart';
import '../innertube/yt_library_providers.dart';
import '../search/shared_providers.dart';
import 'playlists.dart';

const _stateKey = 'yt_library_sync_v1';
const _legacyKey = 'yt_playlist_sync_v1';

String _trackKey(String name, String artist) =>
    '${name.toLowerCase()}|${artist.toLowerCase()}';

extension on StoredTrack {
  String get syncKey => _trackKey(name, artist);
}

StoredTrack _storedFrom(YouTubeMusicTrack t) => StoredTrack(
      name: t.title,
      artist: t.artist,
      album: t.album,
      artworkUrl: t.artworkUrl,
      videoId: t.videoId,
      durationSeconds: t.durationSeconds,
    );

/// What one merge wants done. [nextBase] is the agreed set assuming the
/// remote writes fail; the caller adds [addRemote] entries that succeed and
/// [removeRemote] entries that fail.
class SyncPlan {
  final List<StoredTrack> addLocal;
  final List<StoredTrack> removeLocal;
  final List<StoredTrack> addRemote;
  final List<StoredTrack> removeRemote;
  final Set<String> nextBase;

  const SyncPlan({
    this.addLocal = const [],
    this.removeLocal = const [],
    this.addRemote = const [],
    this.removeRemote = const [],
    this.nextBase = const {},
  });

  int get removals => removeLocal.length + removeRemote.length;
}

Iterable<String> baseEntries(StoredTrack t) => [
      if (t.videoId.isNotEmpty) t.videoId,
      'k:${t.syncKey}',
    ];

/// Three-way merge of a track list against the last agreed state.
///
/// [base] tells an addition from a deletion: a track on only one side was
/// deleted on the other if it was agreed before, and is new otherwise. Tracks
/// match by video id or name|artist, since the same song can carry a
/// different id on each side.
///
/// With [remoteComplete] false a track missing from [remote] may just be on
/// an unread page, so it is never treated as deleted. [grace] holds ids
/// written moments ago: YouTube's lists lag behind writes, and acting on the
/// stale read would undo the user's change.
SyncPlan planSync({
  required List<StoredTrack> local,
  required List<StoredTrack> remote,
  required Set<String> base,
  bool remoteComplete = true,
  Set<String> grace = const {},
}) {
  final localIds = {
    for (final t in local)
      if (t.videoId.isNotEmpty) t.videoId,
  };
  final localKeys = local.map((t) => t.syncKey).toSet();
  final remoteIds = remote.map((t) => t.videoId).toSet();
  final remoteKeys = remote.map((t) => t.syncKey).toSet();
  bool inBase(StoredTrack t) => baseEntries(t).any(base.contains);

  final next = <String>{};
  final addLocal = <StoredTrack>[];
  final removeLocal = <StoredTrack>[];
  final addRemote = <StoredTrack>[];
  final removeRemote = <StoredTrack>[];

  for (final r in remote) {
    if (localIds.contains(r.videoId) || localKeys.contains(r.syncKey)) {
      next.addAll(baseEntries(r));
    } else if (grace.contains(r.videoId)) {
      if (inBase(r)) next.addAll(baseEntries(r));
    } else if (inBase(r)) {
      removeRemote.add(r);
    } else {
      addLocal.add(r);
      next.addAll(baseEntries(r));
    }
  }
  for (final l in local) {
    if (remoteIds.contains(l.videoId) || remoteKeys.contains(l.syncKey)) {
      next.addAll(baseEntries(l));
    } else if (grace.contains(l.videoId)) {
      if (inBase(l)) next.addAll(baseEntries(l));
    } else if (inBase(l)) {
      if (remoteComplete) {
        removeLocal.add(l);
      } else {
        next.addAll(baseEntries(l));
      }
    } else if (l.videoId.isNotEmpty) {
      addRemote.add(l);
    }
  }
  return SyncPlan(
    addLocal: addLocal,
    removeLocal: removeLocal,
    addRemote: addRemote,
    removeRemote: removeRemote,
    nextBase: next,
  );
}

/// Whether a merge removes enough to look like a broken read or a restored
/// backup rather than the user's own edits.
bool isBulkRemoval(int removals, int listSize) =>
    removals > 25 && removals * 10 > listSize * 3;

class YtSyncStatus {
  final bool running;
  final String message;
  final int heldRemovals;
  final Set<String> linkedRemoteIds;

  const YtSyncStatus({
    this.running = false,
    this.message = '',
    this.heldRemovals = 0,
    this.linkedRemoteIds = const {},
  });
}

class _Link {
  final String remoteId;
  Set<String> base;
  String title;
  String remoteCount;
  String localSig;

  _Link({
    required this.remoteId,
    Set<String>? base,
    this.title = '',
    this.remoteCount = '',
    this.localSig = '',
  }) : base = base ?? <String>{};

  Map<String, dynamic> toJson() => {
        'remoteId': remoteId,
        'base': base.toList(),
        'title': title,
        'remoteCount': remoteCount,
        'localSig': localSig,
      };

  factory _Link.fromJson(Map json) => _Link(
        remoteId: json['remoteId']?.toString() ?? '',
        base: {for (final e in (json['base'] as List? ?? const [])) '$e'},
        title: json['title']?.toString() ?? '',
        remoteCount: json['remoteCount']?.toString() ?? '',
        localSig: json['localSig']?.toString() ?? '',
      );
}

class _Account {
  Set<String> likedBase;
  bool likedSeeded;
  final Map<int, _Link> links;
  final Set<String> notOwned;

  _Account({
    Set<String>? likedBase,
    this.likedSeeded = false,
    Map<int, _Link>? links,
    Set<String>? notOwned,
  })  : likedBase = likedBase ?? <String>{},
        links = links ?? <int, _Link>{},
        notOwned = notOwned ?? <String>{};

  Map<String, dynamic> toJson() => {
        'likedBase': likedBase.toList(),
        'likedSeeded': likedSeeded,
        'links': {
          for (final e in links.entries) '${e.key}': e.value.toJson(),
        },
        'notOwned': notOwned.toList(),
      };

  factory _Account.fromJson(Map json) {
    final links = <int, _Link>{};
    final raw = json['links'];
    if (raw is Map) {
      raw.forEach((k, v) {
        final id = int.tryParse('$k');
        if (id != null && v is Map) links[id] = _Link.fromJson(v);
      });
    }
    return _Account(
      likedBase: {
        for (final e in (json['likedBase'] as List? ?? const [])) '$e',
      },
      likedSeeded: json['likedSeeded'] == true,
      links: links,
      notOwned: {
        for (final e in (json['notOwned'] as List? ?? const [])) '$e',
      },
    );
  }
}

/// Keeps Liked Songs and playlists the same locally and on YouTube Music.
///
/// YouTube offers no change feed, so this polls. Local edits are noticed
/// straight away through the repository and pushed after a short debounce;
/// remote edits arrive on the next tick. Between full reads a tick only makes
/// cheap probes (first page of Liked Music, playlist track counts), plus a
/// couple of round-robin playlists to catch same-size edits.
///
/// Mirrored playlists are ordinary `saved_playlists` rows, so every existing
/// screen and menu works on them. State is kept per YouTube channel, so one
/// channel's library is never uploaded to another.
class YtLibrarySync {
  static const tickEvery = Duration(seconds: 60);
  static const fullReadEvery = Duration(minutes: 10);
  static const _debounce = Duration(milliseconds: 1500);
  static const _graceFor = Duration(minutes: 5);
  static const _maxLikeWritesPerRun = 30;
  static const _maxResolvesPerRun = 20;
  static const _roundRobinPerTick = 2;
  static const _missesBeforeRemoteDelete = 2;

  final AppDatabase _db;
  final InnerTubeMusicApi _tube;
  final PlaylistRepository _repo;
  final bool Function() _enabled;
  final void Function(YtSyncStatus) _onStatus;
  final void Function({required bool libraryChanged}) _onSynced;
  final Duration _likePacing;
  final DateTime Function() _now;

  YtLibrarySync(
    this._db,
    this._tube,
    this._repo, {
    required bool Function() enabled,
    void Function(YtSyncStatus)? onStatus,
    void Function({required bool libraryChanged})? onSynced,
    Duration likePacing = const Duration(milliseconds: 150),
    DateTime Function()? now,
  })  : _enabled = enabled,
        _onStatus = onStatus ?? _noStatus,
        _onSynced = onSynced ?? _noSynced,
        _likePacing = likePacing,
        _now = now ?? DateTime.now;

  static void _noStatus(YtSyncStatus _) {}
  static void _noSynced({required bool libraryChanged}) {}

  Timer? _ticker;
  Timer? _debouncer;
  bool _running = false;
  bool _rerun = false;
  bool _applyingLocal = false;
  bool _localDirty = true;
  bool _bulkApproved = false;
  bool _forceFull = false;
  int _held = 0;
  int _cursor = 0;
  int _failures = 0;
  DateTime? _lastLikedFull;
  String _likedHead = '';
  Set<String> _linkedIds = const {};
  final Map<String, DateTime> _grace = {};
  final Map<String, int> _misses = {};
  final Set<String> _unresolvable = {};
  bool _disposed = false;

  static String bareId(String id) =>
      id.startsWith('VL') ? id.substring(2) : id;

  void start() {
    _ticker ??= Timer.periodic(tickEvery, (_) => unawaited(run()));
    kick();
  }

  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _debouncer?.cancel();
  }

  /// Sync as soon as possible and read everything: app regained focus, the
  /// connection changed, or the user pressed Sync now.
  void kick() {
    unawaited(run(force: true));
  }

  /// Called for every repository change. The engine's own writes are ignored.
  void onLocalChanged() {
    if (_applyingLocal || _disposed) return;
    _localDirty = true;
    _debouncer?.cancel();
    _debouncer = Timer(_debounce, () => unawaited(run()));
  }

  /// The user confirmed the removals a bulk guard held back.
  void applyHeldRemovals() {
    _bulkApproved = true;
    kick();
  }

  void _local(void Function() write) {
    _applyingLocal = true;
    try {
      write();
    } finally {
      _applyingLocal = false;
    }
  }

  Set<String> _activeGrace() {
    final now = _now();
    _grace.removeWhere((_, at) => now.difference(at) > _graceFor);
    return _grace.keys.toSet();
  }

  void _markWritten(String videoId) => _grace[videoId] = _now();

  void _publish({required bool running, String message = ''}) {
    if (_disposed) return;
    _onStatus(YtSyncStatus(
      running: running,
      message: message,
      heldRemovals: _held,
      linkedRemoteIds: _linkedIds,
    ));
  }

  /// One sync pass. Concurrent calls collapse into one follow-up pass.
  Future<void> run({bool force = false}) async {
    if (force) _forceFull = true;
    if (_disposed || !_enabled() || !_tube.connection.connected) return;
    if (_running) {
      _rerun = true;
      return;
    }
    _running = true;
    _publish(running: true);
    var message = '';
    var libraryChanged = false;
    try {
      final force = _forceFull;
      final localDirty = _localDirty;
      _forceFull = false;
      _localDirty = false;
      _held = 0;
      _failures = 0;
      final state = _loadState();
      final key = _accountKey(_tube.connection);
      final accounts = state.accounts;
      _adoptLegacyEmptyEmailKey(state, key);
      final account = accounts.putIfAbsent(key, _Account.new);
      await _handleAccountSwitch(state, key);
      state.lastAccount = key;

      final moreLikes = await _syncLiked(
        account,
        force: force || localDirty,
      );
      final playlistsChanged = await _syncPlaylists(
        state,
        account,
        key,
        force: force || localDirty,
      );
      libraryChanged = playlistsChanged;
      _linkedIds = {
        for (final link in account.links.values) bareId(link.remoteId),
      };
      _saveState(state);
      if (moreLikes) {
        _localDirty = true;
        _rerun = true;
      }
      if (_bulkApproved) _bulkApproved = false;
      message = _held > 0
          ? 'Held back $_held removals because that is a lot at once. Nothing was deleted.'
          : _failures > 0
              ? "Some changes didn't reach YouTube Music. Retrying."
              : 'Up to date.';
    } catch (e) {
      if (kDebugMode) debugPrint('YtLibrarySync: run failed ${e.runtimeType}');
      message = 'Sync failed. Retrying shortly.';
      _localDirty = true;
    } finally {
      _running = false;
      _publish(running: false, message: message);
      if (!_disposed) _onSynced(libraryChanged: libraryChanged);
    }
    if (_rerun && !_disposed) {
      _rerun = false;
      _debouncer?.cancel();
      _debouncer = Timer(const Duration(seconds: 5), () => unawaited(run()));
    }
  }

  // ---- Liked Songs ------------------------------------------------------

  /// Returns true when more like writes are queued for a later pass.
  Future<bool> _syncLiked(_Account account, {required bool force}) async {
    final now = _now();
    final due = _lastLikedFull == null ||
        now.difference(_lastLikedFull!) >= fullReadEvery;
    if (!force && !due) {
      final probe =
          await _tube.fetchOwnedPlaylistItems('LM', firstPageOnly: true);
      if (probe.items.isEmpty) return false;
      if (_headOf(probe.items) == _likedHead) return false;
    }
    final owned = await _tube.fetchOwnedPlaylistItems('LM');
    if (owned.items.isEmpty && !owned.complete && account.likedSeeded) {
      // Nothing readable. Local additions wait for a good read.
      _failures++;
      return false;
    }
    _lastLikedFull = now;
    _likedHead = _headOf(owned.items);

    var liked = await _repo.ensureLikedSongs();
    liked = await _resolveMissingIds(liked);
    final remote = [
      for (final item in owned.items)
        if (item.track != null) _storedFrom(item.track!),
    ];
    final plan = planSync(
      local: liked.tracks,
      remote: remote,
      base: account.likedBase,
      remoteComplete: owned.complete,
      grace: _activeGrace(),
    );
    final hold = !_bulkApproved &&
        isBulkRemoval(
          plan.removals,
          liked.tracks.length > remote.length
              ? liked.tracks.length
              : remote.length,
        );
    final next = {...plan.nextBase};
    if (hold) {
      _held += plan.removals;
      for (final t in [...plan.removeLocal, ...plan.removeRemote]) {
        next.addAll(baseEntries(t));
      }
    }

    _local(() {
      _repo.applyBatch(
        liked.id,
        add: plan.addLocal,
        removeKeys: hold
            ? const {}
            : plan.removeLocal.map((t) => t.syncKey).toSet(),
      );
    });

    var writes = 0;
    var queued = false;
    Future<bool> write(Future<bool> Function() call) async {
      if (writes >= _maxLikeWritesPerRun) {
        queued = true;
        return false;
      }
      if (writes > 0) await Future<void>.delayed(_likePacing);
      writes++;
      final ok = await call();
      if (!ok) _failures++;
      return ok;
    }

    for (final t in plan.addRemote) {
      if (await write(() => _tube.likeVideo(t.videoId))) {
        next.addAll(baseEntries(t));
        _markWritten(t.videoId);
      }
    }
    if (!hold) {
      for (final t in plan.removeRemote) {
        if (await write(() => _tube.removeVideoLike(t.videoId))) {
          _markWritten(t.videoId);
        } else {
          next.addAll(baseEntries(t));
        }
      }
    }
    account.likedBase = next;
    account.likedSeeded = true;
    return queued;
  }

  static String _headOf(List<YtOwnedPlaylistItem> items) =>
      items.take(30).map((i) => i.videoId).join(',');

  /// Finds a YouTube id for rows that have none (Last.fm imports, lossless
  /// plays) so they can sync. Local files stay out: they are never uploaded.
  Future<SavedPlaylist> _resolveMissingIds(SavedPlaylist playlist) async {
    var budget = _maxResolvesPerRun;
    var changed = false;
    final tracks = <StoredTrack>[];
    for (final t in playlist.tracks) {
      if (t.videoId.isNotEmpty ||
          t.playbackUrl.isNotEmpty ||
          budget <= 0 ||
          _unresolvable.contains(t.syncKey)) {
        tracks.add(t);
        continue;
      }
      budget--;
      YouTubeMusicTrack? hit;
      try {
        hit = await _tube.findBestMatchOrNull(t.name, t.artist);
      } catch (_) {}
      if (hit == null || hit.videoId.isEmpty) {
        _unresolvable.add(t.syncKey);
        tracks.add(t);
        continue;
      }
      changed = true;
      tracks.add(StoredTrack(
        name: t.name,
        artist: t.artist,
        artworkUrl: t.artworkUrl,
        videoId: hit.videoId,
        album: t.album,
        durationSeconds: t.durationSeconds,
        playbackUrl: t.playbackUrl,
        addedAtMillis: t.addedAtMillis,
      ));
    }
    if (!changed) return playlist;
    _applyingLocal = true;
    try {
      await _repo.replaceTracks(playlist.id, tracks);
    } finally {
      _applyingLocal = false;
    }
    return _repo.all.firstWhere((p) => p.id == playlist.id);
  }

  // ---- Playlists --------------------------------------------------------

  static bool _mirrorable(SavedPlaylist p) =>
      p.mode == 'custom' && !p.isLikedSongs && !p.isLocal;

  static String _localSig(SavedPlaylist p) =>
      '${p.title}\n${p.tracks.map((t) => t.videoId.isEmpty ? t.syncKey : t.videoId).join(',')}';

  /// Returns true when the set of linked playlists changed.
  Future<bool> _syncPlaylists(
    _SyncState state,
    _Account account,
    String key, {
    required bool force,
  }) async {
    final summaries = await _tube.fetchAccountPlaylistsOrNull();
    if (summaries == null) {
      _failures++;
      return false;
    }
    var changed = false;
    final rowsById = {for (final p in _repo.all) p.id: p};

    // Deleted here: delete there too. An all-empty table is a wiped or
    // restored database, not the user deleting everything.
    final anyMirrorable = rowsById.values.any(_mirrorable);
    if (!anyMirrorable) {
      // Wiped database: forget links to rows that no longer exist (the
      // remote playlists stay untouched). Left in place they hid the
      // remote from the YouTube section AND blocked re-importing it below.
      for (final id in account.links.keys.toList()) {
        if (rowsById.containsKey(id)) continue;
        account.links.remove(id);
        changed = true;
      }
    } else {
      for (final id in account.links.keys.toList()) {
        if (rowsById.containsKey(id)) continue;
        final link = account.links[id]!;
        if (await _tube.deleteRemotePlaylist(link.remoteId)) {
          account.links.remove(id);
          changed = true;
        } else {
          _failures++;
        }
      }
    }

    final byBareId = {for (final s in summaries) bareId(s.id): s};
    final linkedRemote = {
      for (final l in account.links.values) bareId(l.remoteId),
    };
    final fresh = <int>{};

    // New here: link to a same-named playlist of ours, else create one.
    for (final row in rowsById.values.where(_mirrorable)) {
      if (account.links.containsKey(row.id)) continue;
      if (state.ownedByOther(row.id, key)) continue;
      String? remote;
      for (final s in summaries) {
        final bare = bareId(s.id);
        if (linkedRemote.contains(bare) ||
            account.notOwned.contains(bare) ||
            s.title.toLowerCase() != row.title.toLowerCase()) {
          continue;
        }
        final probe =
            await _tube.fetchOwnedPlaylistItems(bare, firstPageOnly: true);
        if (probe.editable) {
          remote = bare;
          break;
        }
        account.notOwned.add(bare);
      }
      remote ??= state.legacyRemoteFor(row.id);
      if (remote == null) {
        final created = await _tube.createRemotePlaylist(row.title);
        if (created == null || created.isEmpty) {
          _failures++;
          continue;
        }
        remote = bareId(created);
      }
      account.links[row.id] = _Link(remoteId: remote, title: row.title);
      linkedRemote.add(remote);
      fresh.add(row.id);
      changed = true;
    }

    // New there: bring our own playlists in as rows.
    for (final s in summaries) {
      final bare = bareId(s.id);
      if (!bare.startsWith('PL') ||
          linkedRemote.contains(bare) ||
          account.notOwned.contains(bare)) {
        continue;
      }
      // A local row with these titles is read as the Liked Songs list
      // (`SavedPlaylist.isLikedSongs`), so importing would merge into it.
      // Such a playlist stays in the YouTube section instead.
      final lowered = s.title.toLowerCase();
      if (lowered == SavedPlaylist.likedTitle.toLowerCase() || lowered == 'liked music') {
        continue;
      }
      final owned = await _tube.fetchOwnedPlaylistItems(bare);
      if (!owned.editable) {
        account.notOwned.add(bare);
        continue;
      }
      if (!owned.complete) continue;
      final tracks = [
        for (final item in owned.items)
          if (item.track != null) _storedFrom(item.track!),
      ];
      late final SavedPlaylist row;
      _applyingLocal = true;
      try {
        row = await _repo.createCustom(s.title);
        _repo.applyBatch(row.id, add: tracks);
      } finally {
        _applyingLocal = false;
      }
      final base = <String>{};
      for (final t in tracks) {
        base.addAll(baseEntries(t));
      }
      final added = _repo.all.firstWhere((p) => p.id == row.id);
      account.links[row.id] = _Link(
        remoteId: bare,
        base: base,
        title: s.title,
        remoteCount: s.trackCountText,
        localSig: _localSig(added),
      );
      linkedRemote.add(bare);
      changed = true;
    }

    // Keep each linked pair in step.
    final ids = account.links.keys.toList()..sort();
    if (ids.isEmpty) return changed;
    final roundRobin = <int>{};
    for (var i = 0; i < _roundRobinPerTick && i < ids.length; i++) {
      roundRobin.add(ids[(_cursor + i) % ids.length]);
    }
    _cursor = (_cursor + _roundRobinPerTick) % ids.length;

    for (final id in ids) {
      final row = _repo.all.where((p) => p.id == id).firstOrNull;
      if (row == null) continue;
      final link = account.links[id]!;
      final summary = byBareId[bareId(link.remoteId)];
      final justCreated = fresh.contains(id);

      if (summary == null && !justCreated) {
        if (await _handleMissingRemote(account, id, link, summaries)) {
          changed = true;
        }
        continue;
      }
      _misses.remove(link.remoteId);

      if (summary != null) {
        // Renamed on YouTube only. If both sides changed, the local name wins
        // and is pushed below.
        if (summary.title != link.title && row.title == link.title) {
          _applyingLocal = true;
          try {
            await _repo.rename(id, summary.title);
          } finally {
            _applyingLocal = false;
          }
          link.title = summary.title;
        }
      }
      final current = _repo.all.firstWhere((p) => p.id == id);
      if (current.title != link.title) {
        if (await _tube.renameRemotePlaylist(link.remoteId, current.title)) {
          link.title = current.title;
        } else {
          _failures++;
        }
      }

      final sig = _localSig(current);
      final count = summary?.trackCountText ?? '';
      final needsRead = force ||
          justCreated ||
          roundRobin.contains(id) ||
          sig != link.localSig ||
          count != link.remoteCount;
      if (!needsRead) continue;
      await _syncPair(current, link);
      link.remoteCount = count;
    }
    return changed;
  }

  /// A linked playlist is gone from the library list. Confirm before
  /// deleting our copy: it must miss repeated reads and fail a direct read
  /// while the list itself is plainly working.
  Future<bool> _handleMissingRemote(
    _Account account,
    int id,
    _Link link,
    List<YouTubePlaylistSummary> summaries,
  ) async {
    if (summaries.isEmpty) return false;
    final misses = (_misses[link.remoteId] ?? 0) + 1;
    _misses[link.remoteId] = misses;
    if (misses < _missesBeforeRemoteDelete) return false;
    final direct = await _tube.fetchOwnedPlaylistItems(
      link.remoteId,
      firstPageOnly: true,
    );
    if (direct.editable) {
      _misses.remove(link.remoteId);
      return false;
    }
    _applyingLocal = true;
    try {
      await _repo.delete(id);
    } finally {
      _applyingLocal = false;
    }
    account.links.remove(id);
    _misses.remove(link.remoteId);
    return true;
  }

  Future<void> _syncPair(SavedPlaylist row, _Link link) async {
    final owned = await _tube.fetchOwnedPlaylistItems(link.remoteId);
    if (!owned.editable) {
      // Unreadable right now. Never merge against a list we can't trust.
      _failures++;
      return;
    }
    final resolved = await _resolveMissingIds(row);
    final remote = [
      for (final item in owned.items)
        if (item.track != null) _storedFrom(item.track!),
    ];
    final plan = planSync(
      local: resolved.tracks,
      remote: remote,
      base: link.base,
      remoteComplete: owned.complete,
      grace: _activeGrace(),
    );
    final size = resolved.tracks.length > remote.length
        ? resolved.tracks.length
        : remote.length;
    final hold = !_bulkApproved && isBulkRemoval(plan.removals, size);
    final next = {...plan.nextBase};
    if (hold) {
      _held += plan.removals;
      for (final t in [...plan.removeLocal, ...plan.removeRemote]) {
        next.addAll(baseEntries(t));
      }
    }
    _local(() {
      _repo.applyBatch(
        row.id,
        add: plan.addLocal,
        removeKeys: hold
            ? const {}
            : plan.removeLocal.map((t) => t.syncKey).toSet(),
      );
    });
    if (plan.addRemote.isNotEmpty) {
      final ok = await _tube.addVideosToRemotePlaylist(
        link.remoteId,
        plan.addRemote.map((t) => t.videoId).toList(),
      );
      if (ok) {
        for (final t in plan.addRemote) {
          next.addAll(baseEntries(t));
          _markWritten(t.videoId);
        }
      } else {
        _failures++;
      }
    }
    if (!hold && plan.removeRemote.isNotEmpty) {
      final doomed = plan.removeRemote.map((t) => t.videoId).toSet();
      final removals = [
        for (final item in owned.items)
          if (doomed.contains(item.videoId) && item.setVideoId.isNotEmpty)
            (setVideoId: item.setVideoId, videoId: item.videoId),
      ];
      final ok = removals.isNotEmpty &&
          await _tube.removeVideosFromRemotePlaylist(link.remoteId, removals);
      if (ok) {
        doomed.forEach(_markWritten);
      } else {
        _failures++;
        for (final t in plan.removeRemote) {
          next.addAll(baseEntries(t));
        }
      }
    }
    link.base = next;
    link.localSig =
        _localSig(_repo.all.firstWhere((p) => p.id == row.id));
  }

  // ---- Persistence and account handling ---------------------------------

  static String _accountKey(YtConnection c) {
    final who = c.profileEmail.isNotEmpty ? c.profileEmail : c.accountName;
    return '$who|${c.activePageId}';
  }

  /// The email can arrive after the first sync of a pasted-cookie login.
  /// That is the same account, not a switch.
  void _adoptLegacyEmptyEmailKey(_SyncState state, String key) {
    final last = state.lastAccount;
    if (last == null || last == key || !last.startsWith('|')) return;
    if (last.substring(1) != key.substring(key.indexOf('|') + 1)) return;
    final old = state.accounts.remove(last);
    if (old != null) state.accounts.putIfAbsent(key, () => old);
    state.lastAccount = key;
  }

  /// Liked Songs is one row shared by all channels. Before merging a new
  /// channel, take out what came from the previous one, or its likes would
  /// be uploaded here. Both channels re-read their likes on the next merge.
  Future<void> _handleAccountSwitch(_SyncState state, String key) async {
    final last = state.lastAccount;
    if (last == null || last == key) return;
    final previous = state.accounts[last];
    if (previous == null) return;
    final liked = await _repo.ensureLikedSongs();
    final strip = {
      for (final t in liked.tracks)
        if (baseEntries(t).any(previous.likedBase.contains)) t.syncKey,
    };
    _local(() => _repo.applyBatch(liked.id, removeKeys: strip));
    previous.likedBase = <String>{};
    previous.likedSeeded = false;
    final incoming = state.accounts[key];
    if (incoming != null) {
      incoming.likedBase = <String>{};
      incoming.likedSeeded = false;
    }
    _likedHead = '';
    _lastLikedFull = null;
  }

  _SyncState _loadState() {
    final state = _SyncState();
    final raw = _db.kvGet(_stateKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          state.lastAccount = decoded['lastAccount']?.toString();
          final accounts = decoded['accounts'];
          if (accounts is Map) {
            accounts.forEach((k, v) {
              if (v is Map) state.accounts['$k'] = _Account.fromJson(v);
            });
          }
        }
      } catch (_) {}
    }
    final legacy = _db.kvGet(_legacyKey);
    if (legacy != null && legacy.isNotEmpty) {
      try {
        final decoded = jsonDecode(legacy);
        final maps = decoded is Map ? decoded['mappings'] : null;
        if (maps is Map) {
          maps.forEach((k, v) {
            final id = int.tryParse('$k');
            final remote = v is Map ? v['remoteId']?.toString() ?? '' : '';
            if (id != null && remote.isNotEmpty) {
              state.legacyRemotes[id] = bareId(remote);
            }
          });
        }
      } catch (_) {}
    }
    return state;
  }

  void _saveState(_SyncState state) {
    final encoded = jsonEncode({
      'lastAccount': state.lastAccount,
      'accounts': {
        for (final e in state.accounts.entries) e.key: e.value.toJson(),
      },
    });
    if (_db.kvGet(_stateKey) != encoded) _db.kvSet(_stateKey, encoded);
  }
}

class _SyncState {
  String? lastAccount;
  final Map<String, _Account> accounts = {};
  final Map<int, String> legacyRemotes = {};

  bool ownedByOther(int localId, String key) => accounts.entries
      .any((e) => e.key != key && e.value.links.containsKey(localId));

  /// A playlist the old manual "Sync now" already uploaded.
  String? legacyRemoteFor(int localId) => legacyRemotes[localId];
}

/// Live sync state for Settings and the Playlists page.
final ytSyncStatusProvider =
    StateProvider<YtSyncStatus>((_) => const YtSyncStatus());

final ytLibrarySyncProvider = Provider<YtLibrarySync>((ref) {
  final sync = YtLibrarySync(
    ref.watch(databaseProvider),
    ref.watch(innerTubeProvider),
    ref.watch(playlistRepositoryProvider.notifier),
    enabled: () => ref.read(prefsProvider).syncYtLibrary,
    onStatus: (status) =>
        ref.read(ytSyncStatusProvider.notifier).state = status,
    onSynced: ({required libraryChanged}) {
      ref.invalidate(ytHistoryProvider);
      if (libraryChanged) ref.invalidate(ytAccountPlaylistsProvider);
    },
  );
  ref.listen(playlistRepositoryProvider, (_, _) => sync.onLocalChanged());
  ref.listen(ytConnectionProvider, (previous, next) {
    if (next.connected &&
        (previous?.connected != true ||
            previous?.profileEmail != next.profileEmail ||
            previous?.activePageId != next.activePageId)) {
      sync.kick();
    }
  });
  ref.onDispose(sync.dispose);
  return sync;
});
