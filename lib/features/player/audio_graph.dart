/// Joins libmpv `af` pieces so equalizer, headphone correction, pitch,
/// and a mix sweep occupy one chain instead of replacing each other.
String mergeEqualizerAndHeadphone(String equalizerAf, String headphoneAf) {
  final inner = <String>[];
  void absorb(String af) {
    final trimmed = af.trim();
    if (trimmed.isEmpty) return;
    final wrapped = RegExp(r'^format=floatp,lavfi=\[(.*)\]$').firstMatch(trimmed);
    if (wrapped != null) {
      final body = wrapped.group(1)!;
      if (body.isNotEmpty) inner.add(body);
      return;
    }
    final lavfi = RegExp(r'^lavfi=\[(.*)\]$').firstMatch(trimmed);
    if (lavfi != null) {
      final body = lavfi.group(1)!;
      if (body.isNotEmpty) inner.add(body);
      return;
    }
    inner.add(trimmed);
  }

  absorb(equalizerAf);
  absorb(headphoneAf);
  if (inner.isEmpty) return '';
  return 'format=floatp,lavfi=[${inner.join(',')}]';
}

/// Appends one lavfi filter (a sweep) without dropping the chain already
/// built for EQ, headphone correction, or scaletempo.
String afWithSweep(String baseAf, String sweepFilter) {
  final sweep = sweepFilter.trim();
  if (sweep.isEmpty) return baseAf;
  if (baseAf.isEmpty) return 'lavfi=[$sweep]';
  final lavfi = RegExp(r'lavfi=\[(.*)\]$').firstMatch(baseAf);
  if (lavfi != null) {
    final body = lavfi.group(1)!;
    final merged = body.isEmpty ? sweep : '$body,$sweep';
    return baseAf.replaceRange(lavfi.start, lavfi.end, 'lavfi=[$merged]');
  }
  return '$baseAf,lavfi=[$sweep]';
}
