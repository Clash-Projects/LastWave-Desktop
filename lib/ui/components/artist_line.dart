import 'package:fluent_ui/fluent_ui.dart';

import '../../core/audio/artist_parser.dart';
import '../navigation/wave_nav.dart';
import '../theme/tokens.dart';

/// Renders an artist credit line, breaking multiple collaborated artists
/// into separate, distinct clickable names (e.g. "Drake • 21 Savage").
class WaveArtistLine extends StatelessWidget {
  final String artist;
  final TextStyle? style;
  final int maxLines;
  final TextOverflow overflow;
  final TextAlign? textAlign;
  final List<InlineSpan>? extraTrailingSpans;
  final void Function(String artist)? onTapArtist;

  const WaveArtistLine({
    super.key,
    required this.artist,
    this.style,
    this.maxLines = 1,
    this.overflow = TextOverflow.ellipsis,
    this.textAlign,
    this.extraTrailingSpans,
    this.onTapArtist,
  });

  void _open(BuildContext context, String name) {
    if (onTapArtist != null) {
      onTapArtist!(name);
    } else {
      waveOpen(context, '/artist/${Uri.encodeComponent(name)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final defaultStyle = style ??
        WaveType.meta.copyWith(
          color:
              dark ? WaveColors.textSecondary : WaveColors.lightTextSecondary,
        );
    final dotStyle = defaultStyle.copyWith(
      color: dark ? WaveColors.textTertiary : WaveColors.lightTextTertiary,
      fontSize: (defaultStyle.fontSize ?? 12) * 0.9,
    );

    final list = splitArtistCredits(artist).toList();
    if (list.isEmpty) {
      if (extraTrailingSpans != null && extraTrailingSpans!.isNotEmpty) {
        return Text.rich(
          TextSpan(text: artist, style: defaultStyle, children: extraTrailingSpans),
          style: defaultStyle,
          maxLines: maxLines,
          overflow: overflow,
          textAlign: textAlign,
        );
      }
      return Text(
        artist,
        style: defaultStyle,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      );
    }

    if (list.length == 1 && (extraTrailingSpans == null || extraTrailingSpans!.isEmpty)) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _open(context, list.first),
          child: Text(
            list.first,
            maxLines: maxLines,
            overflow: overflow,
            textAlign: textAlign,
            style: defaultStyle,
          ),
        ),
      );
    }

    return Text.rich(
      TextSpan(
        children: [
          for (var i = 0; i < list.length; i++) ...[
            if (i > 0) TextSpan(text: ' • ', style: dotStyle),
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => _open(context, list[i]),
                  child: Text(list[i], style: defaultStyle),
                ),
              ),
            ),
          ],
          ...?extraTrailingSpans,
        ],
      ),
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }
}
