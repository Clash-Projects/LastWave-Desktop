import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/file.dart' as f;
import 'package:file/local.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Single disk cache + provider factory for every piece of artwork.
///
/// Why this exists (see the perf audit):
/// - The default cache manager keeps only 200 files. With disk-resized
///   variants (`maxWidthDiskCache` / provider `maxWidth`) every cover took
///   2+ slots, so a Home visit evicted the Now Playing cover from disk and
///   reopening the page re-downloaded it.
/// - Disk resizing re-encodes the copy as PNG (3–8× a JPEG) — it is never
///   used here: one original per URL on disk, downsampled only at decode
///   time via [ResizeImage].
/// - The default location is `%TEMP%`, which Windows Storage Sense purges.
///
/// Every widget, preload and palette decode must build its provider through
/// [ArtworkCache.provider] so they all share one memory key per (url, size).
class ArtworkCache {
  ArtworkCache._();

  static const String _key = 'lw_artwork_v2';

  /// ~2500 covers at 50–250 KB each ≈ 125–600 MB worst case on disk.
  static const int maxObjects = 2500;

  static final CacheManager instance = CacheManager(
    Config(
      _key,
      stalePeriod: const Duration(days: 60),
      maxNrOfCacheObjects: maxObjects,
      fileSystem: _SupportDirFileSystem(_key),
    ),
  );

  /// Decode edges every artwork request snaps UP to (physical px).
  ///
  /// A coarse ladder (not a fine grid) keeps one URL + one decoded image per
  /// size class, so an animating or resizing tile never mints a new network
  /// request or a new decode per frame.
  static const List<int> ladder = [64, 128, 256, 384, 512, 640, 768, 1024];

  /// [needed] physical px → the ladder step at or above it (capped at the
  /// top step). Returns null for non-positive input.
  static int? bucket(num needed) {
    if (needed <= 0) return null;
    for (final step in ladder) {
      if (needed <= step) return step;
    }
    return ladder.last;
  }

  /// The one provider for [url] decoded at [decodePx] (already bucketed).
  /// Equality ignores the cache manager, so this key matches the one
  /// `CachedNetworkImage(memCacheWidth: decodePx)` builds internally.
  static ImageProvider<Object> provider(String url, {int? decodePx}) {
    final base = CachedNetworkImageProvider(url, cacheManager: instance);
    if (decodePx == null) return base;
    return ResizeImage(base, width: decodePx, height: decodePx);
  }
}

/// [IOFileSystem] clone rooted at the app-support dir instead of temp.
class _SupportDirFileSystem implements FileSystem {
  _SupportDirFileSystem(this._cacheKey);

  final String _cacheKey;

  /// Resolved on first file access, not at construction: touching
  /// [ArtworkCache.instance] (e.g. in tests, with no path_provider) must
  /// not start an unawaited platform call that can fail.
  Future<f.Directory>? _dirFuture;
  Future<f.Directory> get _dir => _dirFuture ??= _create(_cacheKey);

  static Future<f.Directory> _create(String key) async {
    final base = await getApplicationSupportDirectory();
    const fs = LocalFileSystem();
    final directory = fs.directory(p.join(base.path, 'cache', key));
    await directory.create(recursive: true);
    return directory;
  }

  @override
  Future<f.File> createFile(String name) async {
    final directory = await _dir;
    if (!(await directory.exists())) {
      await _create(_cacheKey);
    }
    return directory.childFile(name);
  }
}
