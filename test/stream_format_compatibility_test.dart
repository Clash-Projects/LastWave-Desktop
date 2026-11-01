import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/core/network/dio_factory.dart';
import 'package:lastwave_desktop/core/storage/secure_store.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';

/// Regression coverage for issue #79: YouTube now answers the ANDROID
/// player client with SABR-only adaptive audio (no direct URL). The only
/// direct URL left is the muxed itag 18 MP4, so the resolver must accept
/// muxed audio as a fallback instead of returning "no playable URL" and
/// skipping every track.
void main() {
  late InnerTubeMusicApi tube;
  late _PlayerAdapter adapter;
  late HttpServer probeServer;

  InnerTubeMusicApi build(Map<String, dynamic> playerResponse) {
    final dio = DioFactory.create();
    adapter = _PlayerAdapter(playerResponse);
    dio.httpClientAdapter = adapter;
    return InnerTubeMusicApi(dio, SecureStore());
  }

  setUp(() async {
    // The download path validates the winner with a direct HttpClient
    // probe, so point the candidates at a local server that answers 200.
    probeServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    probeServer.listen((request) {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType('audio', 'mp4')
        ..add([0, 1, 2, 3]);
      request.response.close();
    });
  });

  tearDown(() async {
    await probeServer.close(force: true);
  });

  test('falls back to muxed itag 18 when adaptive audio is SABR-only',
      () async {
    tube = build(_playerResponse());
    final stream = await tube.resolveAudioStream('dQw4w9WgXcQ');

    expect(stream, isNotNull);
    expect(stream!.url, contains('itag=18'));
    expect(stream.mimeType, 'video/mp4');
    expect(stream.audioCodec, 'AAC');
    expect(stream.bitrateKbps, 118);
  });

  test('prefers a direct audio-only URL over the muxed fallback', () async {
    tube = build(_playerResponse(directAudio: true));
    final stream = await tube.resolveAudioStream('dQw4w9WgXcQ');

    expect(stream, isNotNull);
    expect(stream!.url, contains('itag=251'));
    expect(stream.mimeType, 'audio/webm');
    expect(stream.audioCodec, 'OPUS');
  });

  test('never selects a sabr: URL', () async {
    tube = build(_playerResponse());
    final stream = await tube.resolveAudioStream('dQw4w9WgXcQ');

    expect(stream, isNotNull);
    expect(stream!.url.startsWith('sabr:'), isFalse);
  });

  test('downloads prefer audio-only even when muxed has higher bitrate',
      () async {
    final base = 'http://127.0.0.1:${probeServer.port}/media';
    tube = build(
      _playerResponse(
        downloadMuxedUrl: '$base?itag=18&expire=4102444800',
        downloadAudioUrl: '$base?itag=140&expire=4102444800',
      ),
    );
    final stream = await tube.resolveDownloadStream('dQw4w9WgXcQ');

    expect(stream, isNotNull);
    expect(stream!.url, contains('itag=140'));
    expect(stream.mimeType, startsWith('audio/'));
  });
}

/// One canned player response for every client. The ANDROID client is
/// tried first, so the assertions exercise the production parse/sort
/// path rather than a reimplementation of it.
Map<String, dynamic> _playerResponse({
  bool directAudio = false,
  String? downloadMuxedUrl,
  String? downloadAudioUrl,
}) =>
    {
      'playabilityStatus': {'status': 'OK'},
      'streamingData': {
        'formats': [
          {
            'itag': 18,
            'mimeType': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
            // Higher than the audio-only bitrate on purpose: the download
            // path must still pick audio-only.
            'bitrate': downloadMuxedUrl != null ? 400000 : 117607,
            'url': downloadMuxedUrl ??
                'https://rr1---sn-test.googlevideo.com/videoplayback'
                    '?itag=18&expire=4102444800',
          },
        ],
        'adaptiveFormats': [
          // SABR-only adaptive audio: no url, no signatureCipher.
          {
            'itag': 140,
            'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
            'bitrate': 131199,
            'url': ?downloadAudioUrl,          },
          {
            'itag': 251,
            'mimeType': 'audio/webm; codecs="opus"',
            'bitrate': 148439,
            'url': 'sabr:https://rr1---sn-test.googlevideo.com/sabr',
          },
          if (directAudio)
            {
              'itag': 251,
              'mimeType': 'audio/webm; codecs="opus"',
              'bitrate': 148439,
              'url': 'https://rr1---sn-test.googlevideo.com/videoplayback'
                  '?itag=251&expire=4102444800',
            },
        ],
      },
    };

class _PlayerAdapter implements HttpClientAdapter {
  _PlayerAdapter(this.playerResponse);

  final Map<String, dynamic> playerResponse;
  int playerRequests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path.contains('/youtubei/v1/player')) {
      playerRequests++;
      return ResponseBody.fromString(
        jsonEncode(playerResponse),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    // Config scrape / signature script: an empty page keeps the
    // resolver on its fallback constants without touching the network.
    return ResponseBody.fromString('<html></html>', 200);
  }

  @override
  void close({bool force = false}) {}
}
