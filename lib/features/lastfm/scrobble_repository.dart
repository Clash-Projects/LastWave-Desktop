import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/env/app_env.dart';
import '../../core/network/lastfm_api.dart';
import '../../core/network/lastfm_crypto.dart';
import '../../core/storage/prefs.dart';
import 'auth_repository.dart';

/// Scrobble result classification.
enum ScrobbleOutcome { success, queued, noSession, failed }

/// Last.fm scrobbling repository.
///
/// Ported from LastWave-native `data/repository/ScrobbleRepository.kt`:
/// - `track.updateNowPlaying` (deduped) + `track.scrobble`
/// - `track.love` / `track.unlove`
/// - write cooldown + offline queue (max 200) flushed on next scrobble
class ScrobbleRepository {
  final LastFmApiService _api;
  final Prefs _prefs;

  String _lastNowPlayingKey = '';
  DateTime _lastWrite = DateTime.fromMillisecondsSinceEpoch(0);
  final List<Map<String, String>> _offlineQueue = [];

  ScrobbleRepository(this._api, this._prefs);

  String get _apiKey => AppEnv.lastfmApiKey;
  String get _apiSecret => AppEnv.lastfmApiSecret;
  String get _sessionKey => _prefs.sessionKey;

  bool get _canWrite => _sessionKey.isNotEmpty;

  Future<Map<String, String>> _signed(
    String method,
    Map<String, String> extra,
  ) async {
    // Drop empty values so the POST body and the signed string agree
    // (server includes only sent params; sending `album=` while signing
    // without it yields error 13).
    final filteredExtra = {
      for (final e in extra.entries)
        if (e.value.isNotEmpty) e.key: e.value,
    };
    final params = {
      'method': method,
      'api_key': _apiKey,
      'sk': _sessionKey,
      ...filteredExtra,
    };
    return {
      ...params,
      'api_sig': LastFmSigner.sign(params, _apiSecret),
      'format': 'json',
    };
  }

  Future<void> _paceWrites() async {
    final elapsed = DateTime.now().difference(_lastWrite);
    if (elapsed < const Duration(milliseconds: 700)) {
      await Future<void>.delayed(
          const Duration(milliseconds: 700) - elapsed);
    }
    _lastWrite = DateTime.now();
  }

  Future<ScrobbleOutcome> updateNowPlaying({
    required String artist,
    required String track,
    String album = '',
  }) async {
    if (!_prefs.scrobblerEnabled ||
        !_prefs.scrobbleNowPlaying ||
        !_canWrite) {
      return ScrobbleOutcome.noSession;
    }
    final key = '${artist.toLowerCase()}|${track.toLowerCase()}';
    if (key == _lastNowPlayingKey) return ScrobbleOutcome.success;
    _lastNowPlayingKey = key;
    try {
      await _paceWrites();
      final json = await _api.post(await _signed(
        'track.updateNowPlaying',
        {
          'artist': artist,
          'track': track,
          if (album.isNotEmpty) 'album': album,
        },
      ));
      if (json.containsKey('error')) return ScrobbleOutcome.failed;
      return ScrobbleOutcome.success;
    } catch (_) {
      return ScrobbleOutcome.failed;
    }
  }

  /// Scrobble a fully-played track. `timestampSec` = playback start (UTC).
  Future<ScrobbleOutcome> scrobble({
    required String artist,
    required String track,
    String album = '',
    required int timestampSec,
  }) async {
    if (!_prefs.scrobblerEnabled) return ScrobbleOutcome.noSession;
    final entry = {
      'artist': artist,
      'track': track,
      'album': album,
      'timestamp': timestampSec.toString(),
    };
    if (!_canWrite) {
      _enqueue(entry);
      return ScrobbleOutcome.queued;
    }
    await _flushQueue();
    try {
      await _paceWrites();
      final json = await _api.post(await _signed(
        'track.scrobble',
        {
          'artist[0]': artist,
          'track[0]': track,
          'timestamp[0]': timestampSec.toString(),
          if (album.isNotEmpty) 'album[0]': album,
        },
      ));
      if (json.containsKey('error')) {
        final code = (json['error'] as num?)?.toInt();
        if (code == 29 || code == 11 || code == 16) {
          _enqueue(entry);
          return ScrobbleOutcome.queued;
        }
        return ScrobbleOutcome.failed;
      }
      return ScrobbleOutcome.success;
    } catch (_) {
      _enqueue(entry);
      return ScrobbleOutcome.queued;
    }
  }

  Future<bool> setLoved({
    required String artist,
    required String track,
    required bool loved,
  }) async {
    if (!_canWrite) return false;
    try {
      await _paceWrites();
      final json = await _api.post(await _signed(
        loved ? 'track.love' : 'track.unlove',
        {'artist': artist, 'track': track},
      ));
      return !json.containsKey('error');
    } catch (_) {
      return false;
    }
  }

  void _enqueue(Map<String, String> entry) {
    if (_offlineQueue.length >= 200) _offlineQueue.removeAt(0);
    _offlineQueue.add(entry);
  }

  Future<void> _flushQueue() async {
    if (_offlineQueue.isEmpty || !_canWrite) return;
    final pending = List.of(_offlineQueue);
    _offlineQueue.clear();
    for (final e in pending) {
      try {
        await _paceWrites();
        await _api.post(await _signed('track.scrobble', {
          'artist[0]': e['artist'] ?? '',
          'track[0]': e['track'] ?? '',
          'timestamp[0]': e['timestamp'] ?? '',
          if ((e['album'] ?? '').isNotEmpty) 'album[0]': e['album']!,
        }));
      } catch (_) {
        _enqueue(e);
        break;
      }
    }
  }

  int get queuedCount => _offlineQueue.length;
}

final scrobbleRepositoryProvider = Provider<ScrobbleRepository>((ref) {
  return ScrobbleRepository(
    ref.watch(lastFmApiProvider),
    ref.watch(prefsProvider),
  );
});
