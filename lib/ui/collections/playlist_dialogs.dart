import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/dio_factory.dart';
import '../../features/innertube/innertube_api.dart';
import '../../features/library/playlist_import.dart';
import '../../features/library/playlist_link.dart';
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

/// Import a public playlist from a pasted link (YouTube, Spotify or
/// Apple Music — no account needed). Paste, fetch a preview
/// ("<title>" - N of M tracks matched), then import.
Future<void> showWaveImportPlaylist(
  BuildContext context,
  WidgetRef ref,
) async {
  final controller = TextEditingController();
  PlaylistLinkSource? source;
  bool busy = false;
  PlaylistImportPreview? preview;
  String? error;

  String importErrorMessage(Object e) {
    if (e is FormatException) return e.message;
    if (e is StateError) return e.message;
    return 'Could not import that link. Check it is a public playlist and try again.';
  }

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        Future<void> fetch() async {
          final raw = controller.text.trim();
          if (raw.isEmpty || busy) return;
          setState(() {
            busy = true;
            preview = null;
            error = null;
          });
          try {
            final result = await previewPlaylistLink(
              api: ref.read(innerTubeProvider),
              dio: DioFactory.create(),
              rawLink: raw,
            );
            if (!context.mounted) return;
            setState(() {
              busy = false;
              preview = result;
            });
          } catch (e) {
            if (!context.mounted) return;
            setState(() {
              busy = false;
              error = importErrorMessage(e);
            });
          }
        }

        Future<void> doImport() async {
          final ready = preview;
          if (ready == null || busy) return;
          setState(() {
            busy = true;
            error = null;
          });
          try {
            final created = await importPreview(
              repo: ref.read(playlistRepositoryProvider.notifier),
              preview: ready,
            );
            if (!context.mounted) return;
            Navigator.of(context).pop();
            context.go('/playlists/${created.id}');
          } catch (e) {
            if (!context.mounted) return;
            setState(() {
              busy = false;
              error = importErrorMessage(e);
            });
          }
        }

        final ready = preview;
        return ContentDialog(
          title: const Text('Import playlist'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextBox(
                controller: controller,
                autofocus: true,
                placeholder:
                    'Paste a YouTube, Spotify or Apple Music playlist link...',
                onChanged: (v) => setState(() {
                  source = detectPlaylistLink(v);
                  preview = null;
                  error = null;
                }),
                onSubmitted: (_) => fetch(),
              ),
              if (source != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${source!.label} link',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
              if (busy) ...[
                const SizedBox(height: 12),
                const Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: ProgressRing(),
                    ),
                    SizedBox(width: 8),
                    Text('Fetching playlist...',
                        style: TextStyle(fontSize: 12)),
                  ],
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(
                  error!,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
              if (ready != null) ...[
                const SizedBox(height: 8),
                Text(
                  '"${ready.title}" - ${ready.matchedTracks.length} of ${ready.totalRows} tracks matched',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ],
          ),
          actions: [
            Button(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed:
                  busy ? null : (ready != null ? doImport : fetch),
              child: Text(ready != null ? 'Import' : 'Fetch'),
            ),
          ],
        );
      },
    ),
  );
  controller.dispose();
}
