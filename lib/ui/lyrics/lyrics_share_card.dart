import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../core/audio/stream_models.dart';

/// Logical card size. [pixelRatio] 2 writes a 1080×1080 PNG.
const double _kCardLogical = 540;
const double _kCardPixelRatio = 2;

/// Background and text colors of a card.
class _CardStyle {
  final String label;
  final Color top;
  final Color bottom;
  final Color text;
  final Color subtext;
  const _CardStyle(
    this.label,
    this.top,
    this.bottom, {
    this.text = const Color(0xFFFFFFFF),
    this.subtext = const Color(0xCCFFFFFF),
  });
}

const _presetStyles = <_CardStyle>[
  _CardStyle('Sunset', Color(0xFFFF7A59), Color(0xFF9B1D5A)),
  _CardStyle('Ocean', Color(0xFF2B7DE9), Color(0xFF0B2F6B)),
  _CardStyle('Forest', Color(0xFF2E9E6B), Color(0xFF0C3B2E)),
  _CardStyle('Violet', Color(0xFF8E5CF0), Color(0xFF2E1A6B)),
  _CardStyle(
    'Paper',
    Color(0xFFFAF6EE),
    Color(0xFFE6DFD0),
    text: Color(0xFF1C1B19),
    subtext: Color(0xB31C1B19),
  ),
  _CardStyle('Black', Color(0xFF1E1E1E), Color(0xFF000000)),
];

/// Renders artwork, title, artist, and [lines] to a 1080px PNG. A dialog
/// shows the card first so the colors can be picked, then the PNG goes
/// through the same [FilePicker.saveFile] call playlists use.
Future<void> exportLyricsShareCard(
  BuildContext context, {
  required PlayableTrack track,
  required List<String> lines,
}) async {
  final art = await _loadArtwork(context, track.artworkUrl);
  if (!context.mounted) return;
  final artStyle = await _artworkStyle(art);
  if (!context.mounted) return;
  final styles = [?artStyle, ..._presetStyles];

  final style = await showDialog<_CardStyle>(
    context: context,
    builder: (dialogContext) {
      var selected = styles.first;
      return StatefulBuilder(
        builder: (context, setState) => ContentDialog(
          constraints: const BoxConstraints(maxWidth: 520),
          title: const Text('Lyrics card'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: FittedBox(
                  child: _LyricsShareCard(
                    track: track,
                    lines: lines,
                    artwork: art,
                    style: selected,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in styles)
                    Tooltip(
                      message: s.label,
                      child: GestureDetector(
                        onTap: () => setState(() => selected = s),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [s.top, s.bottom],
                            ),
                            border: Border.all(
                              color: identical(s, selected)
                                  ? FluentTheme.of(context).accentColor
                                  : const Color(0x33808080),
                              width: identical(s, selected) ? 2.5 : 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            Button(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(selected),
              child: const Text('Save…'),
            ),
          ],
        ),
      );
    },
  );
  if (!context.mounted || style == null) return;

  final bytes = await _renderCard(
    context,
    track: track,
    lines: lines,
    art: art,
    style: style,
  );
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

Future<ImageProvider<Object>?> _loadArtwork(
  BuildContext context,
  String url,
) async {
  ImageProvider<Object>? art;
  if (url.startsWith('http')) {
    art = CachedNetworkImageProvider(url);
  } else if (url.startsWith('file:')) {
    final file = File(Uri.parse(url).toFilePath());
    if (file.existsSync()) art = FileImage(file);
  } else if (url.isNotEmpty && File(url).existsSync()) {
    art = FileImage(File(url));
  }
  if (art == null) return null;
  try {
    await precacheImage(art, context);
    return art;
  } catch (_) {
    return null;
  }
}

/// A gradient pulled from the cover, dark enough for white text.
Future<_CardStyle?> _artworkStyle(ImageProvider<Object>? art) async {
  if (art == null) return null;
  try {
    final palette = await PaletteGenerator.fromImageProvider(
      art,
      size: const Size(96, 96),
      maximumColorCount: 12,
    );
    final base = (palette.vibrantColor ??
            palette.dominantColor ??
            palette.mutedColor)
        ?.color;
    if (base == null) return null;
    final hsl = HSLColor.fromColor(base);
    final top = hsl
        .withLightness(hsl.lightness.clamp(0.28, 0.42))
        .withSaturation(hsl.saturation.clamp(0.3, 0.85))
        .toColor();
    final bottom = hsl
        .withLightness((hsl.lightness * 0.35).clamp(0.08, 0.18))
        .withSaturation(hsl.saturation.clamp(0.25, 0.7))
        .toColor();
    return _CardStyle('Artwork', top, bottom);
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> _renderCard(
  BuildContext context, {
  required PlayableTrack track,
  required List<String> lines,
  required ImageProvider<Object>? art,
  required _CardStyle style,
}) async {
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
              style: style,
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
  final _CardStyle style;

  const _LyricsShareCard({
    required this.track,
    required this.lines,
    required this.artwork,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    final shown = lines.where((l) => l.trim().isNotEmpty).take(10).toList();
    return SizedBox(
      width: _kCardLogical,
      height: _kCardLogical,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [style.top, style.bottom],
          ),
        ),
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
                              color: Color(0x33000000),
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
                                color: Color(0x33000000),
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
                          style: TextStyle(
                            color: style.text,
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
                          style: TextStyle(
                            color: style.subtext,
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
                                style: TextStyle(
                                  color: style.text,
                                  fontSize: 18,
                                  height: 1.25,
                                  fontWeight: FontWeight.w600,
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
