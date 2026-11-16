/// Joins libmpv `af` pieces so equalizer and headphone correction occupy
/// one chain instead of replacing each other.
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
