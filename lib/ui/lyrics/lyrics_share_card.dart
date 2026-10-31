import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/rendering.dart';

import '../../core/audio/stream_models.dart';

/// Logical card size. [pixelRatio] 2 writes a 1080×1080 PNG.
const double _kCardLogical = 540;
const double _kCardPixelRatio = 2;

/// Renders artwork, title, artist, and [lines] to a 1080px PNG and
/// saves it with the same [FilePicker.saveFile] call playlists use.
Future<void> exportLyricsShareCard(
  BuildContext context, {
  required PlayableTrack track,
  required List<String> lines,
}) async {
  final bytes = await _renderCard(context, track: track, lines: lines);
  if (!context.mounted) return;
  if (bytes == null) {
    _note(context, 'Couldn’t render the lyrics card', error: true);
    return;
  }
  final safe = track.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  final base = safe.isEmpty ? 'lyrics' : safe;
  final saved = await FilePicker.saveFile(
    dialogTitle: 'Save lyrics card',
    fileName: '$base.png',
    bytes: bytes,
    mimeType: 'image/png',
    type: FileType.custom,
    allowedExtensions: const ['png'],
  );
  if (!context.mounted || saved == null) return;
  _note(context, 'Lyrics card saved');
}

void _note(BuildContext context, String message, {bool error = false}) {
  displayInfoBar(
    context,
    builder: (context, close) => InfoBar(
      title: Text(message),
      severity: error ? InfoBarSeverity.error : InfoBarSeverity.success,
      onClose: close,
    ),
  );
}

Future<Uint8List?> _renderCard(
  BuildContext context, {
  required PlayableTrack track,
  required List<String> lines,
}) async {
  final url = track.artworkUrl;
  ImageProvider<Object>? art;
  if (url.startsWith('http')) {
    art = CachedNetworkImageProvider(url);
  } else if (url.startsWith('file:')) {
    final file = File(Uri.parse(url).toFilePath());
    if (file.existsSync()) art = FileImage(file);
  } else if (url.isNotEmpty && File(url).existsSync()) {
    art = FileImage(File(url));
  }
  if (art != null) {
    try {
      await precacheImage(art, context);
    } catch (_) {
      art = null;
    }
  }
  if (!context.mounted) return null;

  final key = GlobalKey();
  final overlay = Overlay.of(context);
  final entry = OverlayEntry(
    builder: (context) => IgnorePointer(
      child: Opacity(
        opacity: 0.01,
        child: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: key,
            child: _LyricsShareCard(
              track: track,
              lines: lines,
              artwork: art,
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  ui.Image? image;
  try {
    for (var i = 0; i < 8; i++) {
      await WidgetsBinding.instance.endOfFrame;
      final boundary =
          key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) continue;
      try {
        image = await boundary.toImage(pixelRatio: _kCardPixelRatio);
        break;
      } catch (_) {}
    }
    if (image == null) return null;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } finally {
    image?.dispose();
    entry.remove();
  }
}

class _LyricsShareCard extends StatelessWidget {
  final PlayableTrack track;
  final List<String> lines;
  final ImageProvider<Object>? artwork;

  const _LyricsShareCard({
    required this.track,
    required this.lines,
    required this.artwork,
  });

  @override
  Widget build(BuildContext context) {
    final shown = lines.where((l) => l.trim().isNotEmpty).take(10).toList();
    return SizedBox(
      width: _kCardLogical,
      height: _kCardLogical,
      child: ColoredBox(
        color: const Color(0xFF121212),
        child: Padding(
          padding: const EdgeInsets.all(36),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 112,
                      height: 112,
                      child: artwork == null
                          ? const ColoredBox(
                              color: Color(0xFF2A2A2A),
                              child: Icon(
                                FluentIcons.music_note,
                                color: Color(0xFFBDBDBD),
                                size: 28,
                              ),
                            )
                          : Image(
                              image: artwork!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const ColoredBox(
                                color: Color(0xFF2A2A2A),
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFF5F5F5),
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            height: 1.15,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          track.artist,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFB5B5B5),
                            fontSize: 15,
                            height: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Expanded(
                child: shown.isEmpty
                    ? const SizedBox.shrink()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final line in shown)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                line,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFFF2F2F2),
                                  fontSize: 18,
                                  height: 1.25,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
