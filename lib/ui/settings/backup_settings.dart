import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/prefs.dart';
import '../../features/backup/backup_repository.dart';
import '../../features/feed/home_shelf_layout.dart';
import '../../features/library/playlists.dart';
import '../../features/settings/theme_controller.dart';
import '../components/buttons.dart';
import '../../features/search/shared_providers.dart';
import '../theme/tokens.dart';

/// Settings → General JSON backup. Secrets stay out of the file.
class BackupSettings extends ConsumerStatefulWidget {
  const BackupSettings({super.key});

  @override
  ConsumerState<BackupSettings> createState() => _BackupSettingsState();
}

class _BackupSettingsState extends ConsumerState<BackupSettings> {
  String _status = '';
  bool _busy = false;

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final json = ref.read(backupRepositoryProvider).build(
            prefs: ref.read(prefsProvider),
            db: ref.read(databaseProvider),
            playlists: ref.read(playlistRepositoryProvider),
          );
      final saved = await FilePicker.saveFile(
        dialogTitle: 'Export backup',
        fileName: 'lastwave-backup.json',
        bytes: utf8.encode(json),
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (saved != null) _status = 'Saved backup.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = error.toString();
      });
    }
  }

  Future<void> _import() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Import backup',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (picked == null) return;
    final content =
        utf8.decode(await picked.readAsBytes(), allowMalformed: true);
    final repo = ref.read(backupRepositoryProvider);
    final playlists = ref.read(playlistRepositoryProvider.notifier);
    final parsed = repo.read(content, playlists.all);
    if (!mounted) return;
    if (parsed is BackupReadInvalid) {
      setState(() => _status = 'That file is not a LastWave backup.');
      return;
    }
    if (parsed is BackupReadUnsupported) {
      setState(() => _status = 'That backup is from a newer app.');
      return;
    }
    if (parsed is! BackupReadOk) return;
    var overwrite = false;
    if (parsed.preview.newerLocal.isNotEmpty) {
      final names = parsed.preview.newerLocal.map((p) => p.title).join(', ');
      final answer = await showDialog<bool>(
        context: context,
        builder: (context) => ContentDialog(
          title: const Text('Import backup'),
          content: Text(
            'These playlists are newer on this device and will be kept '
            'unless you overwrite them: $names',
          ),
          actions: [
            WaveButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep newer'),
            ),
            WaveFilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Overwrite'),
            ),
          ],
        ),
      );
      if (answer == null) return;
      overwrite = answer;
    }
    setState(() => _busy = true);
    try {
      await repo.restoreFile(
        content: content,
        prefs: ref.read(prefsProvider),
        db: ref.read(databaseProvider),
        playlists: playlists,
        overwriteNewer: overwrite,
      );
      ref.read(themeControllerProvider.notifier).refresh();
      ref.invalidate(homeShelfLayoutProvider);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = overwrite
            ? 'Backup restored, including newer local playlists.'
            : 'Backup merged. Newer local playlists were kept.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Backup', style: WaveType.trackTitle),
        const SizedBox(height: 4),
        Text(
          'Playlists, hidden recommendations, home layout and settings. '
          'Accounts, cookies and keys are never included.',
          style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            WaveFilledButton(
              onPressed: _busy ? null : _export,
              child: const Text('Export backup'),
            ),
            WaveButton(
              onPressed: _busy ? null : _import,
              child: const Text('Import backup'),
            ),
          ],
        ),
        if (_status.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            _status,
            style: WaveType.meta.copyWith(color: waveTextSecondary(context)),
          ),
        ],
      ],
    );
  }
}
