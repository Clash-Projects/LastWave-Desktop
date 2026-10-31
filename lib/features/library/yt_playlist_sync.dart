import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/app_database.dart';
import '../innertube/innertube_api.dart';
import '../search/shared_providers.dart';
import 'playlists.dart';

const _syncKey = 'yt_playlist_sync_v1';

class YtPlaylistMapping {
  final int localId;
  final String remoteId;
  final bool deleteRemoteWithLocal;

  const YtPlaylistMapping({
    required this.localId,
    required this.remoteId,
    this.deleteRemoteWithLocal = false,
  });
}

class YtSyncConfig {
  final Set<int> selectedIds;
  final Map<int, YtPlaylistMapping> mappings;

  const YtSyncConfig({
    this.selectedIds = const {},
    this.mappings = const {},
  });
}

class YtSyncResult {
  final int created;
  final int updated;
  final int removed;
  final int failed;
  final String message;

  const YtSyncResult({
    this.created = 0,
    this.updated = 0,
    this.removed = 0,
    this.failed = 0,
    this.message = '',
  });
}

/// Manual YouTube Music playlist sync.
///
/// Liked Songs and Local songs are never mirrored. A remote playlist is
/// deleted only when that local playlist is gone and the user opted in.
class YtPlaylistSync {
  final AppDatabase _db;
  final InnerTubeMusicApi _tube;
  final PlaylistRepository _playlists;

  YtPlaylistSync(this._db, this._tube, this._playlists);

  YtSyncConfig load() {
    final raw = _db.kvGet(_syncKey);
    if (raw == null || raw.isEmpty) return const YtSyncConfig();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const YtSyncConfig();
      final selected = <int>{
        for (final id in (decoded['selected'] as List? ?? const []))
          if (id is int) id
          else if (int.tryParse('$id') != null) int.parse('$id'),
      };
      final mappings = <int, YtPlaylistMapping>{};
      final rawMaps = decoded['mappings'];
      if (rawMaps is Map) {
        rawMaps.forEach((key, value) {
          final id = int.tryParse('$key');
          if (id == null || value is! Map) return;
          final remote = value['remoteId']?.toString() ?? '';
          if (remote.isEmpty) return;
          mappings[id] = YtPlaylistMapping(
            localId: id,
            remoteId: remote,
            deleteRemoteWithLocal: value['deleteRemote'] == true,
          );
        });
      }
      return YtSyncConfig(selectedIds: selected, mappings: mappings);
    } catch (_) {
      return const YtSyncConfig();
    }
  }

  void save(YtSyncConfig config) {
    _db.kvSet(
      _syncKey,
      jsonEncode({
        'selected': config.selectedIds.toList(),
        'mappings': {
          for (final entry in config.mappings.entries)
            '${entry.key}': {
              'remoteId': entry.value.remoteId,
              'deleteRemote': entry.value.deleteRemoteWithLocal,
            },
        },
      }),
    );
  }

  void setSelected(Set<int> ids) {
    final current = load();
    save(YtSyncConfig(selectedIds: ids, mappings: current.mappings));
  }

  void setDeleteRemote(int localId, bool value) {
    final current = load();
    final existing = current.mappings[localId];
    final mappings = Map<int, YtPlaylistMapping>.from(current.mappings);
    if (existing == null) {
      mappings[localId] = YtPlaylistMapping(
        localId: localId,
        remoteId: '',
        deleteRemoteWithLocal: value,
      );
    } else {
      mappings[localId] = YtPlaylistMapping(
        localId: localId,
        remoteId: existing.remoteId,
        deleteRemoteWithLocal: value,
      );
    }
    mappings.removeWhere((key, mapping) =>
        mapping.remoteId.isEmpty && !mapping.deleteRemoteWithLocal);
    save(YtSyncConfig(selectedIds: current.selectedIds, mappings: mappings));
  }

  Future<YtSyncResult> syncNow() async {
    if (!_tube.connection.connected) {
      return const YtSyncResult(
        message: 'Sign in to YouTube Music before syncing playlists.',
      );
    }
    final config = load();
    final live = _playlists.all.where((p) => _syncable(p)).toList();
    final liveIds = live.map((p) => p.id).toSet();
    final mappings = Map<int, YtPlaylistMapping>.from(config.mappings);
    var created = 0;
    var updated = 0;
    var removed = 0;
    var failed = 0;

    final orphans = mappings.keys.where((id) => !liveIds.contains(id)).toList();
    for (final id in orphans) {
      final mapping = mappings.remove(id);
      final remote = mapping?.remoteId ?? '';
      if (mapping?.deleteRemoteWithLocal == true && remote.isNotEmpty) {
        final ok = await _tube.deleteRemotePlaylist(remote);
        if (ok) {
          removed++;
        } else {
          failed++;
        }
      }
    }

    final selected = live.where((p) => config.selectedIds.contains(p.id));
    for (final playlist in selected) {
      try {
        var remote = mappings[playlist.id]?.remoteId ?? '';
        final deleteRemote =
            mappings[playlist.id]?.deleteRemoteWithLocal ?? false;
        if (remote.isEmpty) {
          final createdId = await _tube.createRemotePlaylist(playlist.title);
          if (createdId == null || createdId.isEmpty) {
            failed++;
            continue;
          }
          remote = createdId;
          created++;
        } else {
          await _tube.renameRemotePlaylist(remote, playlist.title);
        }
        final owned = await _tube.fetchOwnedPlaylistItems(remote);
        final localIds = playlist.tracks
            .map((t) => t.videoId)
            .where((id) => id.length == 11)
            .toSet();
        final remoteIds = owned.items.map((item) => item.videoId).toSet();
        final missing = localIds.difference(remoteIds).toList();
        if (missing.isNotEmpty) {
          final ok = await _tube.addVideosToRemotePlaylist(remote, missing);
          if (!ok) failed++;
        }
        if (owned.complete) {
          final extras = owned.items
              .where((item) =>
                  item.setVideoId.isNotEmpty &&
                  !localIds.contains(item.videoId))
              .map((item) => (setVideoId: item.setVideoId, videoId: item.videoId))
              .toList();
          if (extras.isNotEmpty) {
            final ok = await _tube.removeVideosFromRemotePlaylist(remote, extras);
            if (!ok) failed++;
          }
        }
        mappings[playlist.id] = YtPlaylistMapping(
          localId: playlist.id,
          remoteId: remote,
          deleteRemoteWithLocal: deleteRemote,
        );
        updated++;
      } catch (_) {
        failed++;
      }
    }

    save(YtSyncConfig(selectedIds: config.selectedIds, mappings: mappings));
    final message = failed == 0
        ? 'Synced $updated playlist${updated == 1 ? '' : 's'}.'
        : 'Synced with $failed problem${failed == 1 ? '' : 's'}.';
    return YtSyncResult(
      created: created,
      updated: updated,
      removed: removed,
      failed: failed,
      message: message,
    );
  }

  static bool _syncable(SavedPlaylist playlist) =>
      !playlist.isLikedSongs && !playlist.isLocal && playlist.mode != 'local';
}

final ytPlaylistSyncProvider = Provider<YtPlaylistSync>((ref) {
  return YtPlaylistSync(
    ref.watch(databaseProvider),
    ref.watch(innerTubeProvider),
    ref.watch(playlistRepositoryProvider.notifier),
  );
});
