import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/audio/stream_models.dart';
import '../../core/network/dio_factory.dart';
import '../player/play_diag.dart';

/// Optional helper tools for music video links: yt-dlp, and Deno as the
/// JavaScript runtime yt-dlp needs for YouTube's player challenges.
///
/// With both installed, yt-dlp can use YouTube's web and TV clients (the
/// ones that need the player script solved), which carry every height up
/// to 4K and keep working when YouTube changes something: updating yt-dlp
/// picks up the fix without a new LastWave build.
///
/// Nothing is downloaded until the user asks for it in Settings. The files
/// live in the app's support folder under `tools/`.
class YtDlpTools extends ChangeNotifier {
  YtDlpTools({Dio? dio}) : _dio = dio ?? DioFactory.create();

  final Dio _dio;

  Directory? _dir;
  String? ytDlpVersion;
  String? denoVersion;
  String? latestYtDlp;
  String? latestDeno;

  /// What is happening right now, for the Settings row ('' when idle).
  String activity = '';

  /// 0–1 while a download runs, null otherwise.
  double? progress;
  String? error;
  bool _checked = false;
  bool _busy = false;

  bool get busy => _busy;
  bool get installed => ytDlpVersion != null;
  bool get hasDeno => denoVersion != null;
  bool get updateAvailable =>
      (latestYtDlp != null &&
          ytDlpVersion != null &&
          latestYtDlp != ytDlpVersion) ||
      (latestDeno != null && denoVersion != null && latestDeno != denoVersion);

  static bool get supported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Future<Directory> _toolsDir() async {
    final existing = _dir;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'tools'));
    await dir.create(recursive: true);
    return _dir = dir;
  }

  String get _ytName => Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp';
  String get _denoName => Platform.isWindows ? 'deno.exe' : 'deno';

  Future<String> _ytPath() async => p.join((await _toolsDir()).path, _ytName);
  Future<String> _denoPath() async =>
      p.join((await _toolsDir()).path, _denoName);

  /// Reads the installed versions once (cheap; runs each tool's --version).
  Future<void> ensureChecked() async {
    if (_checked || !supported) return;
    _checked = true;
    await _readVersions();
  }

  Future<void> _readVersions() async {
    final yt = await _ytPath();
    final deno = await _denoPath();
    ytDlpVersion = File(yt).existsSync()
        ? (await _run(yt, [
            '--version',
          ], const Duration(seconds: 20)))?.trim().split('\n').first.trim()
        : null;
    if (ytDlpVersion != null && ytDlpVersion!.isEmpty) ytDlpVersion = null;
    final denoOut = File(deno).existsSync()
        ? await _run(deno, ['--version'], const Duration(seconds: 20))
        : null;
    denoVersion = RegExp(r'deno\s+(\S+)').firstMatch(denoOut ?? '')?.group(1);
    notifyListeners();
  }

  // -- install / update ---------------------------------------------------

  /// Looks up the newest releases on GitHub.
  Future<void> checkForUpdates() async {
    if (_busy) return;
    _setBusy('Checking for updates…');
    try {
      await _readVersions();
      final results = await Future.wait([
        _latestTag('yt-dlp/yt-dlp'),
        _latestTag('denoland/deno'),
      ]);
      latestYtDlp = results[0];
      latestDeno = results[1]?.replaceFirst(RegExp('^v'), '');
      error = null;
    } catch (e) {
      error = 'Could not reach GitHub: $e';
    } finally {
      _setIdle();
    }
  }

  /// Downloads (or replaces with the newest) yt-dlp and Deno.
  Future<void> installOrUpdate() async {
    if (_busy || !supported) return;
    error = null;
    _setBusy('Preparing…');
    try {
      final dir = await _toolsDir();
      // Left behind by an earlier build's failed unpack.
      final stale = File(p.join(dir.path, 'deno.zip.part'));
      if (stale.existsSync()) await stale.delete();
      final latest = await Future.wait([
        _latestTag('yt-dlp/yt-dlp'),
        _latestTag('denoland/deno'),
      ]).catchError((_) => <String?>[null, null]);
      latestYtDlp = latest[0];
      latestDeno = latest[1]?.replaceFirst(RegExp('^v'), '');
      await _readVersions();

      if (ytDlpVersion == null || ytDlpVersion != latestYtDlp) {
        _setBusy('Downloading yt-dlp…');
        final target = await _ytPath();
        final part = '$target.part';
        await _download(
          'https://github.com/yt-dlp/yt-dlp/releases/latest/download/'
          '${_ytAsset()}',
          part,
        );
        await _replace(part, target);
      }

      if (denoVersion == null || denoVersion != latestDeno) {
        _setBusy('Downloading Deno…');
        final zip = p.join(dir.path, 'deno-download.zip');
        await _download(
          'https://github.com/denoland/deno/releases/latest/download/'
          'deno-${_denoTriple()}.zip',
          zip,
        );
        _setBusy('Unpacking Deno…');
        final unpack = Directory(p.join(dir.path, 'deno_unpack'));
        if (unpack.existsSync()) await unpack.delete(recursive: true);
        await unpack.create();
        await extractFileToDisk(zip, unpack.path);
        await File(zip).delete();
        final extracted = File(p.join(unpack.path, _denoName));
        if (!extracted.existsSync()) {
          throw StateError('the Deno download did not contain $_denoName');
        }
        await _replace(extracted.path, await _denoPath());
        await unpack.delete(recursive: true);
      }

      _setBusy('Checking…');
      await _readVersions();
      if (!installed) throw StateError('yt-dlp did not start after install');
      PlayDiag.log(
        'video: tools ready — yt-dlp $ytDlpVersion, deno ${denoVersion ?? 'none'}',
      );
    } catch (e) {
      error = 'Install failed: $e';
      PlayDiag.log('video: tools install failed: $e');
    } finally {
      progress = null;
      _setIdle();
    }
  }

  /// Removes both tools.
  Future<void> remove() async {
    if (_busy) return;
    _setBusy('Removing…');
    try {
      for (final path in [await _ytPath(), await _denoPath()]) {
        final f = File(path);
        if (f.existsSync()) await f.delete();
      }
      final cache = Directory(p.join((await _toolsDir()).path, 'cache'));
      if (cache.existsSync()) await cache.delete(recursive: true);
    } catch (e) {
      error = 'Could not remove: $e';
    } finally {
      ytDlpVersion = null;
      denoVersion = null;
      _setIdle();
    }
  }

  Future<String?> _latestTag(String repo) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'https://api.github.com/repos/$repo/releases/latest',
      options: Options(headers: {'Accept': 'application/vnd.github+json'}),
    );
    return res.data?['tag_name']?.toString();
  }

  Future<void> _download(String url, String path) async {
    final f = File(path);
    if (f.existsSync()) await f.delete();
    progress = 0;
    notifyListeners();
    await _dio.download(
      url,
      path,
      options: Options(receiveTimeout: const Duration(minutes: 5)),
      onReceiveProgress: (received, total) {
        if (total > 0) {
          progress = received / total;
          notifyListeners();
        }
      },
    );
    progress = null;
  }

  Future<void> _replace(String from, String to) async {
    final dest = File(to);
    if (dest.existsSync()) await dest.delete();
    await File(from).rename(to);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', to]);
    }
  }

  String _ytAsset() {
    if (Platform.isWindows) {
      return Abi.current() == Abi.windowsArm64
          ? 'yt-dlp_arm64.exe'
          : 'yt-dlp.exe';
    }
    if (Platform.isMacOS) return 'yt-dlp_macos';
    return Abi.current() == Abi.linuxArm64
        ? 'yt-dlp_linux_aarch64'
        : 'yt-dlp_linux';
  }

  String _denoTriple() {
    if (Platform.isWindows) return 'x86_64-pc-windows-msvc';
    if (Platform.isMacOS) {
      return Abi.current() == Abi.macosArm64
          ? 'aarch64-apple-darwin'
          : 'x86_64-apple-darwin';
    }
    return Abi.current() == Abi.linuxArm64
        ? 'aarch64-unknown-linux-gnu'
        : 'x86_64-unknown-linux-gnu';
  }

  void _setBusy(String what) {
    _busy = true;
    activity = what;
    notifyListeners();
  }

  void _setIdle() {
    _busy = false;
    activity = '';
    notifyListeners();
  }

  // -- extraction -----------------------------------------------------------

  /// Every playable https link yt-dlp finds for [videoId] (pictures and
  /// soundtracks), or empty when the tools are missing or it fails.
  Future<List<MusicVideoStream>> formatsFor(String videoId) async {
    if (!supported || videoId.isEmpty) return const [];
    await ensureChecked();
    if (!installed || _busy) return const [];
    final dir = await _toolsDir();
    final deno = await _denoPath();
    final clock = Stopwatch()..start();
    final out = await _run(await _ytPath(), [
      '-J',
      '--no-playlist',
      '--no-warnings',
      '--no-progress',
      '--ignore-config',
      '--cache-dir',
      p.join(dir.path, 'cache'),
      if (File(deno).existsSync()) ...['--js-runtimes', 'deno:$deno'],
      // tv and web_safari carry the tallest pictures once the player
      // challenge is solved; android_vr is the no-JS backstop.
      '--extractor-args',
      'youtube:player_client=default,tv,web_safari,android_vr',
      'https://www.youtube.com/watch?v=$videoId',
    ], const Duration(seconds: 40));
    if (out == null || out.isEmpty) {
      PlayDiag.log('video: yt-dlp gave nothing for $videoId');
      return const [];
    }
    try {
      final streams = parseYtDlpFormats(jsonDecode(out));
      final tallest = streams.isEmpty
          ? 0
          : streams.map((s) => s.height).reduce((a, b) => a > b ? a : b);
      PlayDiag.log(
        'video: yt-dlp for $videoId → ${streams.where((s) => !s.audioOnly).length} '
        'links, tallest ${tallest}p in ${clock.elapsedMilliseconds}ms',
      );
      return streams;
    } catch (e) {
      PlayDiag.log('video: yt-dlp output unreadable for $videoId: $e');
      return const [];
    }
  }

  /// Runs a tool without a console window and returns its stdout, or null
  /// on failure or timeout.
  Future<String?> _run(String exe, List<String> args, Duration timeout) async {
    Process? proc;
    try {
      // Normal mode on Windows creates the child with CREATE_NO_WINDOW: a
      // hidden console that yt-dlp's own helper process and Deno inherit.
      // (Detached mode gives the child no console at all, so each of those
      // grandchildren opened a visible window of its own.)
      proc = await Process.start(exe, args);
      final stdout = proc.stdout.transform(utf8.decoder).join();
      final stderr = proc.stderr.transform(utf8.decoder).join();
      final text = await stdout.timeout(timeout);
      final err = await stderr.timeout(
        const Duration(seconds: 2),
        onTimeout: () => '',
      );
      if (text.trim().isEmpty && err.trim().isNotEmpty) {
        final line = err.trim().split('\n').last;
        PlayDiag.log(
          'video: ${p.basename(exe)} — ${line.length > 200 ? line.substring(0, 200) : line}',
        );
      }
      return text;
    } on TimeoutException {
      PlayDiag.log('video: ${p.basename(exe)} timed out');
      final pid = proc?.pid;
      if (pid != null) Process.killPid(pid);
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[yt-dlp] $e');
      return null;
    }
  }
}

/// yt-dlp `-J` output → links the video player can use. Only plain https
/// files (no HLS/DASH manifests, no storyboards); headers come along
/// because googlevideo checks the User-Agent of the client that made them.
@visibleForTesting
List<MusicVideoStream> parseYtDlpFormats(Object? json) {
  if (json is! Map) return const [];
  final formats = json['formats'];
  if (formats is! List) return const [];
  final out = <MusicVideoStream>[];
  for (final f in formats.whereType<Map>()) {
    final url = f['url']?.toString() ?? '';
    final protocol = f['protocol']?.toString() ?? '';
    if (url.isEmpty || (protocol != 'https' && protocol != 'http')) continue;
    final vcodec = f['vcodec']?.toString() ?? 'none';
    final acodec = f['acodec']?.toString() ?? 'none';
    final hasVideo = vcodec != 'none' && vcodec.isNotEmpty;
    final hasAudio = acodec != 'none' && acodec.isNotEmpty;
    if (!hasVideo && !hasAudio) continue;
    final height = (f['height'] as num?)?.toInt() ?? 0;
    if (hasVideo && height < 144) continue;
    final ext = f['ext']?.toString() ?? '';
    final headers = <String, String>{};
    final h = f['http_headers'];
    if (h is Map) {
      h.forEach((k, v) {
        final key = k.toString();
        // Accept headers describe the request, not the client; leave them
        // to the player.
        if (key.toLowerCase().startsWith('accept')) return;
        headers[key] = v.toString();
      });
    }
    out.add(
      MusicVideoStream(
        label: hasVideo ? '${height}p' : 'audio',
        height: hasVideo ? height : 0,
        bitrate: (((f['tbr'] as num?) ?? 0) * 1000).round(),
        url: url,
        mimeType: hasVideo ? 'video/$ext' : 'audio/$ext',
        codec: hasVideo ? vcodec : acodec,
        fps: (f['fps'] as num?)?.round() ?? 0,
        client: 'yt-dlp/${_clientFromAgent(headers['User-Agent'] ?? '')}',
        muxed: hasVideo && hasAudio,
        audioOnly: !hasVideo,
        requestHeaders: headers,
      ),
    );
  }
  return out;
}

/// Which YouTube client a yt-dlp link came from, told by the User-Agent it
/// must be fetched with. Links from one client fail or play together, so
/// the player groups them by this name.
String _clientFromAgent(String ua) {
  final l = ua.toLowerCase();
  if (l.contains('oculus') || l.contains('.vr')) return 'android_vr';
  if (l.contains('cobalt') || l.contains('smart-tv') || l.contains('tv ')) {
    return 'tv';
  }
  if (l.contains('android')) return 'android';
  if (l.contains('iphone') || l.contains('ios')) return 'ios';
  if (l.contains('safari') && !l.contains('chrome')) return 'web_safari';
  return 'web';
}

final ytDlpToolsProvider = ChangeNotifierProvider<YtDlpTools>((ref) {
  final tools = YtDlpTools();
  unawaited(tools.ensureChecked());
  return tools;
});
