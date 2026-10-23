import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_info.dart';
import '../../core/diagnostics/diagnostics_log.dart';
import '../../core/diagnostics/log_bundle.dart';
import '../../core/storage/app_database.dart';
import '../../core/storage/prefs.dart';
import '../../features/audio_output/output_controller.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/player/playback_service.dart';
import '../../features/player/player_state.dart';
import '../../features/search/shared_providers.dart';
import '../components/buttons.dart';
import '../theme/tokens.dart';

/// Plain-text summary shipped as `diagnostics.txt` inside the export.
///
/// Names *states*, never values: no URLs, no cookies/tokens, no account
/// e-mail. Track titles are kept (a "wrong song" report needs them), the
/// addon host is only counted, and every row is something a support reply
/// would otherwise have to ask for.
Future<String> buildDiagnosticsReport(WidgetRef ref) async {
  final prefs = ref.read(prefsProvider);
  final player = ref.read(playbackServiceProvider);
  final out = ref.read(audioOutputProvider);
  final yt = ref.read(ytConnectionProvider);
  final b = StringBuffer();

  b.writeln('LastWave Desktop diagnostics');
  b.writeln('generated: ${DateTime.now().toIso8601String()}');
  b.writeln('version: $appVersion');
  b.writeln('mode: ${kReleaseMode ? 'release' : 'debug'}');
  b.writeln('platform: ${Platform.operatingSystem} '
      '${Platform.operatingSystemVersion}');
  b.writeln('dart: ${Platform.version}');
  b.writeln('locale: ${Platform.localeName}');
  b.writeln('processors: ${Platform.numberOfProcessors}');
  b.writeln('previous_exit: '
      '${DiagnosticsLog.previousExitClean ? 'clean' : 'unclean'}');
  b.writeln();

  b.writeln('audio output');
  b.writeln('  device: '
      '${out.path.deviceName.isEmpty ? '(none)' : out.path.deviceName}');
  b.writeln('  devices_visible: ${out.devices.length}');
  b.writeln('  mode: ${out.path.mode.name}, '
      'exclusive_requested=${out.exclusiveRequested}, '
      'exclusive_active=${out.path.exclusiveActive}');
  b.writeln('  source=${out.path.sourceLabel} -> '
      'output=${out.path.outputLabel}, '
      'resampling=${out.path.resampling}, '
      'dsp=${out.path.dspActive}, eq=${out.path.peqActive}, '
      'software_volume=${out.path.softwareVolume}');
  b.writeln('  bit_perfect: ${out.path.reason.name} '
      '(${out.path.reason.label})');
  if (out.path.error != null) {
    b.writeln('  error: ${out.path.error}');
  }
  b.writeln('  prefer_lossless: ${prefs.preferLossless}, '
      'lossless_quality: ${prefs.losslessQuality}, '
      'download_quality: ${prefs.downloadQuality}');
  b.writeln('  crossfade: ${prefs.crossfadeEnabled} '
      '(${prefs.crossfadeSeconds}s), scrobbling: ${prefs.scrobblerEnabled}');
  b.writeln();

  final track = player.current;
  final stream = player.stream;
  b.writeln('playback');
  b.writeln('  state: ${_stateLabel(player)}, queue: ${player.queue.length} '
      '@ ${player.currentIndex}');
  if (track != null) {
    b.writeln('  current: ${track.title} - ${track.artist}'
        '${track.album.isEmpty ? '' : ' | album=${track.album}'}'
        '${track.duration.inSeconds == 0 ? '' : ' | ${_mmss(track.duration)}'}');
  }
  b.writeln('  repeat: ${player.repeatMode.name}, '
      'shuffle: ${player.shuffleEnabled}, speed: ${player.speed}');
  b.writeln('  position: ${_mmss(player.position)} / '
      '${_mmss(player.duration)}, buffering: ${player.isBuffering}');
  if (stream != null) {
    b.writeln('  source: ${player.sourceLabel}, '
        'codec=${stream.audioCodec}, lossless=${stream.isLossless}, '
        'bit_depth=${stream.bitDepth}, rate_khz=${stream.samplingRateKhz}, '
        'bitrate_kbps=${stream.bitrateKbps}');
  }
  if (player.error != null) b.writeln('  error: ${player.error}');
  b.writeln();

  b.writeln('accounts and sources');
  b.writeln('  lastfm_signed_in: ${prefs.isAuthenticated}');
  b.writeln('  youtube_connected: ${yt.connected}');
  b.writeln('  addon_hosts: ${prefs.addonUrls.length}');
  b.writeln('  lyrics_provider: ${prefs.lyricsProviderId}');
  b.writeln();

  b.writeln('library (sqlite schema ${AppDatabase.schemaVersion})');
  for (final table in const [
    'downloaded_tracks',
    'saved_playlists',
    'artwork_cache',
    'stream_cache',
    'match_cache',
    'addon_match_cache',
    'search_history',
    'local_plays',
  ]) {
    b.writeln('  $table: ${_count(ref, table)}');
  }
  b.writeln();

  b.writeln('logs');
  final files = DiagnosticsLog.sessionFiles();
  b.writeln('  session_files: ${files.length} '
      '(${DiagnosticsLog.directory?.path ?? 'unavailable'})');
  for (final f in files.take(5)) {
    final size = _size(f);
    b.writeln('    ${_basename(f.path)} $size');
  }
  b.writeln('  verbose: ${DiagnosticsLog.verbose}');
  return b.toString();
}

/// Export flow: build the report, let the user pick a path, confirm.
Future<void> exportDiagnostics(BuildContext context, WidgetRef ref) async {
  final String path;
  try {
    final report = await buildDiagnosticsReport(ref);
    final saved = await LogBundle.export(report: report);
    if (saved == null) return; // cancelled
    path = saved;
  } catch (error) {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => ContentDialog(
        title: const Text('Could not export logs'),
        content: Text('$error'),
        actions: [
          WaveFilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => ContentDialog(
      constraints: const BoxConstraints(maxWidth: 520),
      title: const Text('Diagnostic logs exported'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(path, style: WaveType.meta),
          const SizedBox(height: 10),
          Text(
            'URLs, cookies and tokens were stripped. Attach this file to a '
            'bug report — nothing was uploaded.',
            style: WaveType.meta.copyWith(
              color: waveTextSecondary(dialogContext),
            ),
          ),
        ],
      ),
      actions: [
        WaveButton(
          onPressed: () => LogBundle.revealFile(path),
          child: const Text('Show in folder'),
        ),
        WaveFilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

/// Opens the folder the session logs live in (created on first boot).
Future<void> openLogFolder() async {
  final dir = DiagnosticsLog.directory;
  if (dir == null) return;
  try {
    if (!dir.existsSync()) dir.createSync(recursive: true);
  } catch (_) {}
  await LogBundle.openFolder(dir.path);
}

String _stateLabel(PlayerSnapshot s) {
  if (s.error != null) return 'error';
  if (s.isBuffering) return 'buffering';
  if (s.isPlaying) return 'playing';
  return s.current == null ? 'idle' : 'paused';
}

String _mmss(Duration d) {
  final total = d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final sec = total % 60;
  final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

String _size(File file) {
  try {
    final bytes = file.lengthSync();
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  } catch (_) {
    return '?';
  }
}

String _basename(String path) {
  final i = path.lastIndexOf(Platform.pathSeparator);
  return i < 0 ? path : path.substring(i + 1);
}

/// Row count for [table], or -1 when the table/DB is unavailable (a fresh
/// install prunes nothing, so an absent table is informational, not fatal).
int _count(WidgetRef ref, String table) {
  try {
    final rows =
        ref.read(databaseProvider).raw.select('SELECT COUNT(*) AS c FROM $table');
    if (rows.isEmpty) return 0;
    final value = rows.first['c'];
    return value is int ? value : int.tryParse('$value') ?? 0;
  } catch (_) {
    return -1;
  }
}
