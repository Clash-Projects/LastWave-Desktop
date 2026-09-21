import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/library/playlists.dart';

/// Shared playlist dialogs (create / rename / delete), used by the
/// playlists browser and the local playlist detail page.
Future<void> showWaveCreatePlaylist(
  BuildContext context,
  WidgetRef ref,
) async {
  final controller = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (context) => ContentDialog(
      title: const Text('New playlist'),
      content: TextBox(
        controller: controller,
        placeholder: 'Playlist name',
        autofocus: true,
        onSubmitted: (v) =>
            Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context)
              .pop(controller.text.trim()),
          child: const Text('Create'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (name != null && name.isNotEmpty && context.mounted) {
    final created = await ref
        .read(playlistRepositoryProvider.notifier)
        .createCustom(name);
    if (context.mounted) {
      context.go('/playlists/${created.id}');
    }
  }
}

Future<void> showWaveRenamePlaylist(
  BuildContext context,
  WidgetRef ref,
  SavedPlaylist playlist,
) async {
  final controller =
      TextEditingController(text: playlist.title);
  final name = await showDialog<String>(
    context: context,
    builder: (context) => ContentDialog(
      title: const Text('Rename playlist'),
      content: TextBox(
        controller: controller,
        autofocus: true,
        onSubmitted: (v) =>
            Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context)
              .pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (name != null && name.isNotEmpty) {
    await ref
        .read(playlistRepositoryProvider.notifier)
        .rename(playlist.id, name);
  }
}

Future<void> showWaveDeletePlaylist(
  BuildContext context,
  WidgetRef ref,
  SavedPlaylist playlist,
) async {
  final confirm = await showDialog<bool>(
    context: context,
    builder: (context) => ContentDialog(
      title: const Text('Delete playlist?'),
      content: Text(
        '"${playlist.title}" will be removed from your library.',
      ),
      actions: [
        Button(
          onPressed: () =>
              Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirm == true && context.mounted) {
    await ref
        .read(playlistRepositoryProvider.notifier)
        .delete(playlist.id);
    if (context.mounted) {
      context.go('/playlists');
    }
  }
}
