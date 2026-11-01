import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Sample rate used for alignment captures. Onsets only need ~20 hops a
/// second, so 8 kHz mono keeps captures tiny and decoding cheap.
const int alignmentSampleRate = 8000;

/// Decodes the first [seconds] of a stream to raw PCM using a throwaway
/// libmpv instance writing through `ao=pcm` (untimed, so faster than
/// realtime and never audible). Works for every source the audio player
/// itself can open: YouTube Opus, lossless FLAC, DASH manifests, files.
///
/// Returns null on any failure; alignment is best effort.
Future<Uint8List?> capturePcm16Mono({
  required String url,
  Map<String, String> headers = const {},
  required int seconds,
  Duration timeout = const Duration(seconds: 40),
}) async {
  Player? player;
  File? out;
  try {
    final dir = await getTemporaryDirectory();
    out = File(
      p.join(dir.path, 'lw_align_${DateTime.now().microsecondsSinceEpoch}.pcm'),
    );
    player = Player(
      configuration: const PlayerConfiguration(
        title: 'LastWave alignment',
        logLevel: MPVLogLevel.error,
        bufferSize: 8 * 1024 * 1024,
      ),
    );
    final native = player.platform;
    if (native is! NativePlayer) return null;
    final props = <String, String>{
      'ao': 'pcm',
      'ao-pcm-file': out.path,
      'ao-pcm-waveheader': 'no',
      'audio-format': 's16',
      'audio-channels': 'mono',
      'audio-samplerate': '$alignmentSampleRate',
      'end': '$seconds',
      'vid': 'no',
      'sid': 'no',
      'volume': '100',
      'replaygain': 'no',
      'af': '',
    };
    for (final e in props.entries) {
      await native.setProperty(e.key, e.value);
    }
    // Safety: only start when libmpv accepted the file writer. A build
    // without ao_pcm would otherwise play this capture out loud.
    String ao = '';
    try {
      ao = await native.getProperty('ao');
    } catch (_) {}
    if (!ao.startsWith('pcm')) return null;

    final targetBytes = seconds * alignmentSampleRate * 2;
    await player.open(
      Media(url, httpHeaders: headers.isEmpty ? null : headers),
      play: true,
    );

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      String current = '';
      try {
        current = await native.getProperty('current-ao');
      } catch (_) {}
      // Second guard: the driver actually opened must be the writer.
      if (current.isNotEmpty && current != 'pcm') return null;
      final size = await out.exists() ? await out.length() : 0;
      if (size >= targetBytes || player.state.completed) break;
    }
    try {
      await player.stop();
    } catch (_) {}
    if (!await out.exists()) return null;
    final bytes = await out.readAsBytes();
    // Too little audio cannot be aligned reliably (20s minimum overlap).
    if (bytes.lengthInBytes < 22 * alignmentSampleRate * 2) return null;
    return bytes.lengthInBytes > targetBytes
        ? Uint8List.sublistView(bytes, 0, targetBytes)
        : bytes;
  } catch (e) {
    if (kDebugMode) debugPrint('[video-sync] pcm capture failed: $e');
    return null;
  } finally {
    try {
      await player?.dispose();
    } catch (_) {}
    try {
      if (out != null && await out.exists()) await out.delete();
    } catch (_) {}
  }
}
