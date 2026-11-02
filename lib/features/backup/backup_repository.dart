import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_info.dart';
import '../../core/storage/app_database.dart';
import '../../core/storage/prefs.dart';
import '../feed/home_shelf_layout.dart';
import '../library/playlists.dart';

const backupType = 'lastwave-backup';
const backupSchema = 8;

class BackupPlaylist {
  final int id;
  final String title;
  final String subtitle;
  final String mode;
  final String tracksJson;
  final int createdAtMillis;
  final String? discoverSignature;
  final String? customCoverUri;
  final bool isPinned;

  const BackupPlaylist({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.mode,
    required this.tracksJson,
    required this.createdAtMillis,
    this.discoverSignature,
    this.customCoverUri,
    this.isPinned = false,
  });

  factory BackupPlaylist.fromJson(Map<String, dynamic> json) => BackupPlaylist(
        id: json['id'] is num ? (json['id'] as num).toInt() : 0,
        title: json['title']?.toString() ?? '',
        subtitle: json['subtitle']?.toString() ?? '',
        mode: json['mode']?.toString() ?? 'custom',
        tracksJson: json['tracksJson']?.toString() ?? '[]',
        createdAtMillis: json['createdAtMillis'] is num
            ? (json['createdAtMillis'] as num).toInt()
            : 0,
        discoverSignature: json['discoverSignature']?.toString(),
        customCoverUri: json['customCoverUri']?.toString(),
        isPinned: json['isPinned'] == true,
      );
}

class BackupPreview {
  final List<BackupPlaylist> playlists;
  final List<BackupPlaylist> newerLocal;
  final int exclusionCount;
  final String? homeShelfLayout;
  final Map<String, dynamic> prefs;
  const BackupPreview({
    required this.playlists,
    required this.newerLocal,
    required this.exclusionCount,
    required this.homeShelfLayout,
    required this.prefs,
  });
}

sealed class BackupRead {
  const BackupRead();
}

class BackupReadOk extends BackupRead {
  final BackupPreview preview;
  const BackupReadOk(this.preview);
}

class BackupReadInvalid extends BackupRead {
  const BackupReadInvalid();
}

class BackupReadUnsupported extends BackupRead {
  const BackupReadUnsupported();
}

class BackupRepository {
  String build({
    required Prefs prefs,
    required AppDatabase db,
    required List<SavedPlaylist> playlists,
  }) {
    final strings = <String, String>{};
    final booleans = <String, bool>{};
    final integers = <String, int>{};
    final doubles = <String, double>{};
    final lists = <String, List<String>>{};
    for (final key in prefs.portablePrefKeys) {
      final value = prefs.portablePref(key);
      switch (value) {
        case String s:
          strings[key] = s;
        case bool b:
          booleans[key] = b;
        case int i:
          integers[key] = i;
        case double d:
          doubles[key] = d;
        case List list:
          lists[key] = [for (final item in list) item.toString()];
        default:
          break;
      }
    }
    final exclusions = db.raw.select(
      'SELECT track_key, excluded_at_millis, track_name, artist_name '
      'FROM recommendation_exclusions;',
    );
    final file = {
      'type': backupType,
      'schemaVersion': backupSchema,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'appVersion': appVersion,
      'prefs': {
        'strings': strings,
        'booleans': booleans,
        'integers': integers,
        'doubles': doubles,
        'stringSets': lists,
      },
      'playlists': [
        for (final playlist in playlists)
          {
            'id': playlist.id,
            'title': playlist.title,
            'subtitle': playlist.subtitle,
            'mode': playlist.mode,
            'tracksJson': jsonEncode(
              playlist.tracks.map((t) => t.toJson()).toList(),
            ),
            'createdAtMillis': playlist.createdAtMillis,
            'discoverSignature': null,
            'customCoverUri': playlist.customCoverUri,
            'isPinned': playlist.isPinned,
          },
      ],
      'recommendationExclusions': [
        for (final row in exclusions)
          {
            'trackKey': row['track_key'] ?? '',
            'excludedAtMillis': row['excluded_at_millis'] ?? 0,
            'trackName': row['track_name'] ?? '',
            'artistName': row['artist_name'] ?? '',
          },
      ],
      'homeShelfLayout': db.kvGet(homeShelfLayoutKey) ?? '',
    };
    return const JsonEncoder.withIndent('  ').convert(file);
  }

  BackupRead read(String content, List<SavedPlaylist> local) {
    Object? decoded;
    try {
      decoded = jsonDecode(content);
    } catch (_) {
      return const BackupReadInvalid();
    }
    if (decoded is! Map || decoded['type'] != backupType) {
      return const BackupReadInvalid();
    }
    final schema = decoded['schemaVersion'];
    final version = schema is num ? schema.toInt() : 0;
    if (version > backupSchema) return const BackupReadUnsupported();
    final playlistsRaw = decoded['playlists'];
    final playlists = <BackupPlaylist>[];
    if (playlistsRaw is List) {
      for (final item in playlistsRaw) {
        if (item is Map) {
          playlists.add(BackupPlaylist.fromJson(
            item.map((k, v) => MapEntry(k.toString(), v)),
          ));
        }
      }
    }
    final byId = {for (final playlist in local) playlist.id: playlist};
    final newer = <BackupPlaylist>[];
    for (final incoming in playlists) {
      final existing = byId[incoming.id];
      if (existing != null &&
          existing.createdAtMillis > incoming.createdAtMillis) {
        newer.add(incoming);
      }
    }
    final exclusions = decoded['recommendationExclusions'];
    final prefs = decoded['prefs'];
    return BackupReadOk(BackupPreview(
      playlists: playlists,
      newerLocal: newer,
      exclusionCount: exclusions is List ? exclusions.length : 0,
      homeShelfLayout: decoded['homeShelfLayout']?.toString(),
      prefs: prefs is Map
          ? prefs.map((k, v) => MapEntry(k.toString(), v))
          : const {},
    ));
  }

  Future<int> restore({
    required BackupPreview preview,
    required Prefs prefs,
    required AppDatabase db,
    required PlaylistRepository playlists,
    required bool overwriteNewer,
  }) async {
    await _restorePrefs(prefs, preview.prefs);
    final blocked = {
      for (final playlist in preview.newerLocal) playlist.id,
    };
    var applied = 0;
    for (final playlist in preview.playlists) {
      if (playlist.id == 0) continue;
      if (!overwriteNewer && blocked.contains(playlist.id)) continue;
      playlists.upsertBackupRow(
        id: playlist.id,
        title: playlist.title,
        subtitle: playlist.subtitle,
        mode: playlist.mode,
        tracksJson: playlist.tracksJson,
        createdAtMillis: playlist.createdAtMillis,
        isPinned: playlist.isPinned,
        discoverSignature: playlist.discoverSignature,
        customCoverUri: playlist.customCoverUri,
      );
      applied++;
    }
    playlists.refresh();
    final layout = preview.homeShelfLayout;
    if (layout != null && layout.trim().isNotEmpty) {
      db.kvSet(homeShelfLayoutKey, layout);
    }
    return applied;
  }

  Future<void> restoreFile({
    required String content,
    required Prefs prefs,
    required AppDatabase db,
    required PlaylistRepository playlists,
    required bool overwriteNewer,
  }) async {
    final readResult = read(content, playlists.all);
    if (readResult is! BackupReadOk) {
      throw StateError('That file is not a LastWave backup.');
    }
    await restore(
      preview: readResult.preview,
      prefs: prefs,
      db: db,
      playlists: playlists,
      overwriteNewer: overwriteNewer,
    );
    final decoded = jsonDecode(content);
    if (decoded is! Map) return;
    final exclusions = decoded['recommendationExclusions'];
    if (exclusions is List) {
      for (final item in exclusions) {
        if (item is! Map) continue;
        final key = item['trackKey']?.toString() ?? '';
        if (key.isEmpty) continue;
        db.raw.execute(
          'INSERT INTO recommendation_exclusions('
          'track_key, excluded_at_millis, track_name, artist_name) '
          'VALUES(?, ?, ?, ?) '
          'ON CONFLICT(track_key) DO UPDATE SET '
          'excluded_at_millis = excluded.excluded_at_millis, '
          'track_name = excluded.track_name, '
          'artist_name = excluded.artist_name;',
          [
            key,
            item['excludedAtMillis'] is num
                ? (item['excludedAtMillis'] as num).toInt()
                : 0,
            item['trackName']?.toString() ?? '',
            item['artistName']?.toString() ?? '',
          ],
        );
      }
    }
  }

  Future<void> _restorePrefs(Prefs prefs, Map<String, dynamic> raw) async {
    Future<void> apply(Object? bucket) async {
      if (bucket is! Map) return;
      for (final entry in bucket.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value == null) continue;
        await prefs.setPortablePref(key, value);
      }
    }

    await apply(raw['strings']);
    await apply(raw['booleans']);
    await apply(raw['integers']);
    await apply(raw['longs']);
    await apply(raw['doubles']);
    final sets = raw['stringSets'];
    if (sets is Map) {
      for (final entry in sets.entries) {
        final value = entry.value;
        if (value is List) {
          await prefs.setPortablePref(entry.key.toString(), value);
        }
      }
    }
  }

  Future<void> writeFile(String path, String json) async {
    final file = File(path);
    await file.writeAsString(json);
  }
}

final backupRepositoryProvider =
    Provider<BackupRepository>((ref) => BackupRepository());
