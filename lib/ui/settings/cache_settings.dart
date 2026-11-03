import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/app_database.dart';
import '../../features/search/shared_providers.dart';
import '../components/buttons.dart';
import '../theme/tokens.dart';

/// Settings → General → Cached data: what the app keeps on disk so pages
/// open instantly (Home, artist pages, lyrics, …), and a way to drop it.
///
/// Only the capped `snapshot_cache` table is shown and cleared here. Audio
/// streams, artwork and downloads have their own stores and are untouched.
class CacheSettings extends ConsumerStatefulWidget {
  const CacheSettings({super.key});

  @override
  ConsumerState<CacheSettings> createState() => _CacheSettingsState();
}

/// Display names for the cache groups ([AppDatabase.cacheCaps]).
const _groupLabels = {
  'home': 'Home',
  'artist': 'Artist pages',
  'album': 'Albums',
  'playlist': 'Playlists',
  'library': 'Library',
  'lyrics': 'Lyrics',
  'lastfm': 'Last.fm',
  'genre': 'Genres',
};

String _size(int chars) {
  if (chars < 1024) return '$chars B';
  if (chars < 1024 * 1024) return '${(chars / 1024).toStringAsFixed(0)} KB';
  return '${(chars / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _CacheSettingsState extends ConsumerState<CacheSettings> {
  Map<String, ({int entries, int chars})> _stats = const {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    try {
      _stats = ref.read(databaseProvider).cacheStats();
    } catch (_) {
      _stats = const {};
    }
  }

  void _clear() {
    try {
      ref.read(databaseProvider).cacheClear();
    } catch (_) {}
    setState(_refresh);
  }

  @override
  Widget build(BuildContext context) {
    final entries = _stats.values.fold<int>(0, (a, s) => a + s.entries);
    final chars = _stats.values.fold<int>(0, (a, s) => a + s.chars);
    final groups = _stats.keys.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          entries == 0
              ? 'Nothing cached yet.'
              : '$entries saved items · ${_size(chars)}',
          style: WaveType.body,
        ),
        if (groups.isNotEmpty) ...[
          const SizedBox(height: 6),
          for (final g in groups)
            Text(
              '${_groupLabels[g] ?? g}: ${_stats[g]!.entries} '
              '(${_size(_stats[g]!.chars)}, up to '
              '${AppDatabase.cacheCaps[g] ?? AppDatabase.defaultCacheCap})',
              style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
            ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            WaveButton(
              onPressed: entries == 0 ? null : _clear,
              child: const Text('Clear cached data'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Saved copies of pages so they open instantly and refresh in the '
          'background. Clearing them only makes the next open slower once. '
          'Downloads, artwork and your library are not affected.',
          style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
        ),
      ],
    );
  }
}
