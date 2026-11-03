import 'dart:math' as math;

/// What the planner needs to know about one side of a transition.
class MixTrackInfo {
  const MixTrackInfo({
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
  });

  final String title;
  final String artist;
  final String album;

  /// Zero when not known yet (the incoming deck has not loaded).
  final Duration duration;
}

/// How a planned AutoMix transition is rendered.
enum MixStyle {
  /// No overlap: the next track starts when this one ends (album
  /// continuity, live sets, spoken word).
  gapless,

  /// Smoothed equal-power volume blend.
  blend,

  /// Blend plus a low-pass / high-pass sweep (only when libmpv ships the
  /// filters — see [PlaybackService] filter probing).
  filterSweep,
}

class MixPlan {
  const MixPlan({
    required this.style,
    required this.overlap,
    this.reason = '',
  });

  final MixStyle style;
  final Duration overlap;

  /// Short tag for the diagnostics log (`automix plan ... reason=`).
  final String reason;

  bool get mixes => style != MixStyle.gapless && overlap > Duration.zero;
}

/// Decides *whether* and *how long* two tracks should overlap.
///
/// Rules, in order:
///  * consecutive tracks of the same album are left gapless — albums are
///    sequenced on purpose (continuous mixes, segues, hidden transitions);
///  * live recordings and spoken word are left gapless;
///  * the overlap shrinks for short tracks so a 30s mix never eats a
///    quarter of a 2-minute song;
///  * the filter sweep is used only when the audio engine supports it.
class MixPlanner {
  MixPlanner._();

  /// Longest share of either track an overlap may take.
  static const double maxShareOfTrack = 0.12;

  /// Shortest overlap worth doing; below this a plain cut sounds better.
  static const Duration minOverlap = Duration(seconds: 6);

  static final RegExp _spoken = RegExp(
    r'\b(podcast|episode|audiobook|chapter \d+|interview|skit)\b',
    caseSensitive: false,
  );

  static final RegExp _liveTag = RegExp(
    r'[(\[]\s*(?:[^)\]]*\s)?live\b[^)\]]*[)\]]|[-–—]\s*live\b|^\s*live\s*(?::|\s(?:at|from|in)\b)',
    caseSensitive: false,
  );

  static MixPlan plan({
    required MixTrackInfo outgoing,
    required MixTrackInfo incoming,
    required Duration requested,
    required bool sweepAvailable,
    bool sweepWanted = true,
  }) {
    if (_sameAlbum(outgoing, incoming)) {
      return const MixPlan(
          style: MixStyle.gapless, overlap: Duration.zero, reason: 'album');
    }
    if (_isSpokenOrLive(outgoing) || _isSpokenOrLive(incoming)) {
      return const MixPlan(
          style: MixStyle.gapless, overlap: Duration.zero, reason: 'live');
    }

    var overlapMs = requested.inMilliseconds;
    for (final d in [outgoing.duration, incoming.duration]) {
      if (d > Duration.zero) {
        overlapMs =
            math.min(overlapMs, (d.inMilliseconds * maxShareOfTrack).round());
      }
    }
    if (overlapMs < minOverlap.inMilliseconds) {
      return const MixPlan(
          style: MixStyle.gapless, overlap: Duration.zero, reason: 'short');
    }
    // Whole seconds keep the log readable and the schedule stable.
    final overlap = Duration(seconds: (overlapMs / 1000).floor());
    final style = sweepWanted && sweepAvailable
        ? MixStyle.filterSweep
        : MixStyle.blend;
    return MixPlan(
      style: style,
      overlap: overlap,
      reason: overlap < requested ? 'shortened' : 'full',
    );
  }

  /// Outgoing / incoming gains (0..1) at [progress] through the overlap.
  ///
  /// Equal-power (cos/sin) so loudness stays level, driven by a smoothstep
  /// so both ends move slowly: the incoming track creeps in under the
  /// outgoing one and the outgoing tail lets go gently rather than
  /// dropping linearly from the first frame.
  static (double, double) gains(double progress) {
    final p = progress.clamp(0.0, 1.0);
    final s = p * p * (3 - 2 * p);
    final angle = s * math.pi / 2;
    return (math.cos(angle), math.sin(angle));
  }

  /// DJ-style gains for a beat-matched mix: the incoming track comes up
  /// over the first 60% while the outgoing one stays at full level for the
  /// first 40%, then lets go. Locked beats make the brief overlap at full
  /// level sound like one groove instead of a clash.
  static (double, double) djGains(double progress) {
    final p = progress.clamp(0.0, 1.0);
    double smooth(double x) {
      final t = x.clamp(0.0, 1.0);
      return t * t * (3 - 2 * t);
    }

    final inG = math.sin(smooth(p / 0.6) * math.pi / 2);
    final outG = math.cos(smooth((p - 0.4) / 0.6) * math.pi / 2);
    return (outG, inG);
  }

  static bool _sameAlbum(MixTrackInfo a, MixTrackInfo b) {
    final x = _norm(a.album);
    final y = _norm(b.album);
    if (x.isEmpty || y.isEmpty) return false;
    // "Singles" style buckets are not sequenced albums.
    if (x == 'single' || x == 'singles') return false;
    if (x != y) return false;
    final ar = _norm(a.artist);
    final br = _norm(b.artist);
    return ar.isEmpty || br.isEmpty || ar == br || ar.contains(br) || br.contains(ar);
  }

  static bool _isSpokenOrLive(MixTrackInfo t) {
    final text = '${t.title} ${t.album}';
    if (_spoken.hasMatch(text)) return true;
    return _liveTag.hasMatch(t.title) || _liveTag.hasMatch(t.album);
  }

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'\s*[(\[][^)\]]*[)\]]'), '')
      .replaceAll(RegExp(r'[^a-z0-9\u0080-￿]+'), ' ')
      .trim();
}

/// True when an mpv error line is about the audio filter chain (a missing
/// lavfi filter, a graph that failed to build) rather than the stream.
///
/// The bundled libmpv lacks some lavfi filters (`lowpass`, `highpass`):
/// mpv reports that as `[cplayer] Audio filter initialized failed!`,
/// which media_kit forwards on `stream.error`. That is NOT a broken
/// stream — the audio keeps playing — and must never trigger a retry.
bool isFilterGraphError(String text) {
  final t = text.toLowerCase();
  return t.contains('filter') ||
      t.contains('lavfi') ||
      t.contains('avfiltergraph');
}
