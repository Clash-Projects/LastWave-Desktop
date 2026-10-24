/// Central artist parsing and credit splitting utility.
///
/// Ensures collaborations (e.g. "Artist 1, Artist 2", "Artist 1 & Artist 2",
/// "Artist 1 feat. Artist 2", "Artist 1 x Artist 2", "Artist 1 / Artist 2")
/// are broken into individual distinct artists across statistics, UI,
/// search, and navigation, while preserving established band names like
/// "Tyler, The Creator", "Earth, Wind & Fire", "Simon & Garfunkel", "AC/DC".
library;

const Set<String> knownBandsWithDelimiters = {
  'tyler, the creator',
  'earth, wind & fire',
  'earth, wind and fire',
  'simon & garfunkel',
  'simon and garfunkel',
  'crosby, stills & nash',
  'crosby, stills, nash & young',
  'of monsters and men',
  'florence + the machine',
  'florence and the machine',
  'kool & the gang',
  'kool and the gang',
  'hall & oates',
  'daryl hall & john oates',
  'ac/dc',
};

/// First billed artist in a credit string.
///
/// "Drake, Future & Metro Boomin" → "Drake"
/// "Tyler, The Creator" stays intact.
String primaryArtistName(String artist) {
  var s = artist.trim();
  if (s.isEmpty) return s;
  final lower = s.toLowerCase();
  if (knownBandsWithDelimiters.contains(lower)) return s;

  s = s
      .split(RegExp(
        r'\s+[(\[]?(?:feat\.?|ft\.?|featuring)\b',
        caseSensitive: false,
      ))
      .first
      .trim();
  if (RegExp(r',\s*(the|and)\b', caseSensitive: false).hasMatch(s) &&
      !s.contains(' & ') &&
      !s.contains(' feat') &&
      !s.contains(' ft')) {
    return s;
  }
  final cut = s.split(RegExp(r'\s*[,;&/]\s*|\s+[xX]\s+|\s+and\s+')).first.trim();
  return cut.isNotEmpty ? cut : s;
}

/// Individual credits from a collab string.
///
/// Splits on: `,`, `;`, `&`, `and`, `feat.`, `ft.`, `featuring`, `/`, `x`, `X`, `with`.
Iterable<String> splitArtistCredits(String artist) sync* {
  final s = artist.trim();
  if (s.isEmpty) return;
  final lower = s.toLowerCase();
  if (lower == 'unknown artist' || lower == 'various artists') {
    return;
  }
  if (knownBandsWithDelimiters.contains(lower)) {
    yield s;
    return;
  }
  if (RegExp(r',\s*(the|and)\b', caseSensitive: false).hasMatch(s) &&
      !s.contains(' & ') &&
      !s.contains(' feat') &&
      !s.contains(' ft')) {
    yield s;
    return;
  }

  final delimiterRegex = RegExp(
    r'(?:\s*[,;]\s*|\s+&\s+|\s+and\s+|\s+/\s+|\s+[xX]\s+|\s+[(\[]?(?:feat\.?|ft\.?|featuring|with)\b[)\]]?\s*)',
    caseSensitive: false,
  );

  final parts = s.split(delimiterRegex);
  final seen = <String>{};
  for (final raw in parts) {
    var p = raw.trim();
    p = p.replaceAll(RegExp(r'^[(\[]+|[)\]]+$'), '').trim();
    p = p.replaceFirst(
        RegExp(r'^(?:feat\.?|ft\.?|featuring|with)\s+', caseSensitive: false),
        '').trim();
    if (p.isEmpty) continue;
    final pLow = p.toLowerCase();
    if (pLow == 'the' || pLow == 'and' || pLow == '&') continue;
    if (seen.add(pLow)) {
      yield p;
    }
  }
}
