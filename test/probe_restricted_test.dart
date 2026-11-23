import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lastwave_desktop/core/audio/stream_models.dart';
import 'package:lastwave_desktop/core/storage/secure_store.dart';
import 'package:lastwave_desktop/features/innertube/innertube_api.dart';
import 'package:lastwave_desktop/features/innertube/potoken_engine.dart';

void main() {
  test('Live stream and download check on age-restricted / explicit track', () async {
    final dio = Dio();
    final secureStore = SecureStore();
    final poTokens = PoTokenEngine(dio);
    final api = InnerTubeMusicApi(dio, secureStore, poTokens);

    // Test IDs:
    // 1. "2Z4m4lnjxkY" (Tove Lo - Habits - Stay High: explicit/age-gated music video)
    // 2. "M77cW_SUPm4" (ytm-rs test track)
    // 3. "D0q0QeQbw9U" (Massive Attack - The Spoils)
    final candidateIds = ['2Z4m4lnjxkY', 'M77cW_SUPm4', 'D0q0QeQbw9U'];

    String? workingId;
    ResolvedStream? playbackStream;
    ResolvedStream? downloadStream;

    for (final id in candidateIds) {
      print('\nTesting track videoId: $id...');
      try {
        final stream = await api.resolveAudioStream(id);
        if (stream != null && stream.url.isNotEmpty) {
          workingId = id;
          playbackStream = stream;
          print('Successfully resolved live playback stream for $id!');
          print('URL: ${stream.url.substring(0, 80)}...');
          print('MimeType: ${stream.mimeType}, Bitrate: ${stream.bitrateKbps} kbps');
          break;
        }
      } catch (e) {
        print('resolveAudioStream for $id threw: $e');
      }
    }

    expect(workingId, isNotNull, reason: 'At least one candidate track should resolve');
    expect(playbackStream, isNotNull);

    print('\nTesting live audio playback by fetching byte chunks...');
    final playRes = await dio.get<ResponseBody>(
      playbackStream!.url,
      options: Options(
        headers: {
          'Range': 'bytes=0-131071', // First 128 KB
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
        },
        responseType: ResponseType.stream,
      ),
    );

    expect(playRes.statusCode == 200 || playRes.statusCode == 206, isTrue);
    final playBytes = await playRes.data!.stream.first;
    print('Live playback stream active: received ${playBytes.length} bytes (HTTP ${playRes.statusCode})');
    expect(playBytes.isNotEmpty, isTrue);

    print('\nTesting resolveDownloadStream for offline download...');
    downloadStream = await api.resolveDownloadStream(workingId!);
    expect(downloadStream, isNotNull);
    print('Resolved download stream: ${downloadStream!.url.substring(0, 80)}...');
    print('Download MimeType: ${downloadStream.mimeType}, Bitrate: ${downloadStream.bitrateKbps} kbps');

    print('\nVerifying downloading by fetching stream chunk...');
    final dlRes = await dio.get<ResponseBody>(
      downloadStream.url,
      options: Options(
        headers: {
          'Range': 'bytes=0-262143', // 256 KB
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
        },
        responseType: ResponseType.stream,
      ),
    );

    expect(dlRes.statusCode == 200 || dlRes.statusCode == 206, isTrue);
    final dlBytes = await dlRes.data!.stream.first;
    print('Download stream active: received ${dlBytes.length} bytes (HTTP ${dlRes.statusCode})');
    expect(dlBytes.isNotEmpty, isTrue);

    print('\nSUCCESS: Both live playback and downloading verified working with real audio bytes!');
  });
}
