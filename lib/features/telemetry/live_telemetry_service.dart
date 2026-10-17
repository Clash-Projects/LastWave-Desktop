// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/storage/prefs.dart';

final _topicSuffixRegex = RegExp(r'\s*-\s*topic$', caseSensitive: false);
final _vevoSuffixRegex = RegExp(r'\s*vevo$', caseSensitive: false);
final _titleSuffixRegex = RegExp(
  r'\s*[\(\[](official\s*(music\s*)?video|official\s*audio|visualizer|audio|lyric\s*video|lyrics|hd|4k|remastered|hq)[\)\]]',
  caseSensitive: false,
);

/// Clean raw track/artist names by stripping video/channel artifacts.
(String, String) cleanTrackMetadata(String title, String artist) {
  var cleanArtist = artist
      .trim()
      .replaceAll(_topicSuffixRegex, '')
      .replaceAll(_vevoSuffixRegex, '')
      .trim();

  final cleanTitle = title
      .trim()
      .replaceAll(_titleSuffixRegex, '')
      .trim();

  return (
    cleanTitle.isNotEmpty ? cleanTitle : title.trim(),
    cleanArtist.isNotEmpty ? cleanArtist : artist.trim(),
  );
}

/// Links native playback on LastWave Desktop to the LastWave Live Telemetry
/// platform (telemetry.clashprojects.qd.je).
///
/// Anonymous, zero-IP logging, ephemeral 60s RAM bucket:
/// Pings report currently playing track metadata so active listeners appear
/// on the global real-time vector map.
class LiveTelemetryService {
  static const String telemetryBaseUrl = 'https://telemetry.clashprojects.qd.je';
  static const String pingEndpoint = '$telemetryBaseUrl/api/telemetry/ping';

  final Dio _dio;
  final Prefs _prefs;

  int _lastPingAtMs = 0;
  String? _lastPingKey;

  LiveTelemetryService({
    required Prefs prefs,
    Dio? dio,
  })  : _prefs = prefs,
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 10),
                sendTimeout: const Duration(seconds: 10),
              ),
            );

  /// Submit an anonymous playback tick for the currently playing track.
  /// Pings are debounced to prevent spamming the backend rate limiter (max 10 req/min).
  Future<void> ping({
    required String title,
    required String artist,
    String? songId,
    String? artworkUrl,
    bool force = false,
  }) async {
    final t = title.trim();
    final a = artist.trim();
    if (t.isEmpty || a.isEmpty) return;
    if (!_prefs.liveTelemetryEnabled) return;

    final (cleanTitle, cleanArtist) = cleanTrackMetadata(t, a);
    final key = '${cleanArtist.toLowerCase()}|${cleanTitle.toLowerCase()}';
    final now = DateTime.now().millisecondsSinceEpoch;

    // Debounce: don't ping more than once every 30 seconds for the same song unless forced
    if (!force && key == _lastPingKey && (now - _lastPingAtMs) < 30000) {
      return;
    }

    final payload = <String, dynamic>{
      'song_id': (songId != null && songId.isNotEmpty) ? songId : key,
      'title': cleanTitle,
      'artist': cleanArtist,
      'cover_url': artworkUrl ?? '',
      'client': 'desktop',
    };

    try {
      final res = await _dio.post<dynamic>(
        pingEndpoint,
        data: payload,
        options: Options(
          headers: {
            'User-Agent': 'LastWave-Desktop/1.0',
            'Accept': 'application/json',
            'Content-Type': 'application/json; charset=utf-8',
          },
        ),
      );

      if (res.statusCode != null &&
          res.statusCode! >= 200 &&
          res.statusCode! < 300) {
        _lastPingAtMs = now;
        _lastPingKey = key;
        debugPrint(
            'Live telemetry acknowledged: $cleanTitle by $cleanArtist (HTTP ${res.statusCode})');
      } else {
        debugPrint('Live telemetry non-2xx status: ${res.statusCode}');
      }
    } catch (e) {
      debugPrint('Live telemetry ping error: $e');
    }
  }

  /// Opens the live map web application in the default browser.
  Future<bool> openLiveMap() async {
    try {
      final uri = Uri.parse(telemetryBaseUrl);
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Could not launch live map: $e');
    }
    return false;
  }
}

final liveTelemetryServiceProvider = Provider<LiveTelemetryService>((ref) {
  return LiveTelemetryService(prefs: ref.watch(prefsProvider));
});
