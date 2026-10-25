import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/backup/backup_file.dart';
import '../../features/library/playlists.dart';
import '../../features/search/shared_providers.dart';
import '../components/buttons.dart';

/// Saves the library as a LastWave-Native backup file.
Future<void> exportBackup(BuildContext context, WidgetRef ref) async {
  try {
    final bytes = Uint8List.fromList(
      utf8.encode(buildBackup(ref.read(databaseProvider))),
    );
    final uri = await FilePicker.saveFile(
      dialogTitle: 'Export backup',
      fileName: 'lastwave-backup-${DateTime.now().millisecondsSinceEpoch}.json',
      bytes: bytes,
      mimeType: 'application/json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (uri == null || !context.mounted) return;
    await _message(
      context,
      'Backup exported',
      'Restore it in the LastWave phone app (Backup & Restore > Restore) '
          'or on another computer.',
    );
  } catch (e) {
    if (context.mounted) await _message(context, 'Could not export', '$e');
  }
}

/// Picks a backup file, confirms, then replaces playlists and exclusions.
Future<void> restoreBackupFromFile(BuildContext context, WidgetRef ref) async {
  final String content;
  try {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Select a LastWave backup',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (file == null) return;
    // Real backups are a few MB at most; the cap keeps a stray file out.
    if (await file.length() > 50 * 1024 * 1024) {
      throw const BackupException('That file is too large.');
    }
    content = utf8.decode(await file.readAsBytes(), allowMalformed: true);
  } catch (e) {
    if (context.mounted) {
      await _message(context, 'Could not read the file', '$e');
    }
    return;
  }
  if (!context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => ContentDialog(
      title: const Text('Restore this backup?'),
      content: const Text(
        'Your saved playlists and "don\'t recommend" list will be replaced '
        'by the ones in the file. Settings on this computer are kept.',
      ),
      actions: [
        WaveButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        WaveFilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Restore'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    final summary = restoreBackup(ref.read(databaseProvider), content);
    ref.read(playlistRepositoryProvider.notifier)
      ..refresh()
      ..collapseDuplicateLikedRows();
    if (!context.mounted) return;
    await _message(
      context,
      'Backup restored',
      '${summary.playlists} playlists and ${summary.exclusions} '
          '"don\'t recommend" entries.',
    );
  } on BackupException catch (e) {
    if (context.mounted) {
      await _message(context, 'Could not restore', e.message);
    }
  }
}

Future<void> _message(BuildContext context, String title, String body) =>
    showDialog<void>(
      context: context,
      builder: (dialogContext) => ContentDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          WaveFilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
