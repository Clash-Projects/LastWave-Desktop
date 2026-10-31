import 'dart:convert';
import 'dart:io';
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
      'Keep it somewhere both devices reach (Drive, OneDrive…) and use '
          '"Sync with file" on each of them.',
    );
  } catch (e) {
    if (context.mounted) await _message(context, 'Could not export', '$e');
  }
}

/// Picks the shared backup file, merges it both ways and writes it back.
Future<void> syncWithFile(BuildContext context, WidgetRef ref) async {
  final String path;
  final String content;
  try {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Select the LastWave backup to sync with',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (file == null) return;
    final picked = file.path;
    if (picked == null) {
      throw const BackupException('Pick a file on this computer.');
    }
    // Real backups are a few MB at most; the cap keeps a stray file out.
    if (await file.length() > 50 * 1024 * 1024) {
      throw const BackupException('That file is too large.');
    }
    path = picked;
    content = utf8.decode(await file.readAsBytes(), allowMalformed: true);
  } catch (e) {
    if (context.mounted) {
      await _message(context, 'Could not read the file', '$e');
    }
    return;
  }
  try {
    final summary = await syncBackup(
      ref.read(databaseProvider),
      content,
      (merged) => File(path).writeAsString(merged, flush: true),
    );
    ref.read(playlistRepositoryProvider.notifier)
      ..refresh()
      ..collapseDuplicateLikedRows();
    if (!context.mounted) return;
    await _message(
      context,
      'Synced',
      '${summary.playlists} playlists and ${summary.exclusions} '
          '"don\'t recommend" entries. The file now holds both sides: sync '
          'it in the phone app too.',
    );
  } catch (e) {
    if (context.mounted) await _message(context, 'Could not sync', '$e');
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
