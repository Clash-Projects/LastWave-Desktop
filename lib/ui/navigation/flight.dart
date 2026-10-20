import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:fluent_ui/fluent_ui.dart';

import '../theme/tokens.dart';

/// Cover flight: the cover the user pressed travels into the detail header
/// instead of the page simply cutting in.
///
/// Deliberately not a Flutter `Hero`. A hero tag has to be unique *within a
/// route*, and the same album, artist or playlist legitimately appears twice
/// on one page (a chart row and a shelf, a search result and a shelf), which
/// Flutter reports as an error the moment a flight with that tag starts.
/// Giving every card an instance token would mean touching every card and
/// still break whenever a list rebuilds mid-transition.
///
/// Instead the source rect is recorded once, when the detail route is pushed
/// ([arm], called from `waveOpen`), and the destination replays the flight in
/// an overlay entry that sits above *both* routes ([WaveFlightTarget]). So
/// duplicate ids are harmless, cards need no changes at all, and a page that
/// is popped mid-flight takes its overlay with it.
///
/// The recorded rect is the pressed widget's own box, cropped to a square
/// from its top-left — that is where a cover sits in every card we have
/// (square artwork on top, caption underneath, artwork on the left of a row),
/// so the flight starts on the cover without the card having to hand its
/// artwork's geometry over.
class WaveFlight {
  WaveFlight._();

  /// How long a recorded source stays eligible for consumption. The push and
  /// the destination's first frame are adjacent, so anything older is a stray
  /// arm from a navigation that never landed (redirect, failed push).
  static const Duration ttl = Duration(milliseconds: 900);

  static _FlightSource? _armed;

  /// Records where the route being opened came from.
  ///
  /// [context] should be the pressed widget's context — cards already hand
  /// their own `context` to `waveOpen`. Locations that are not a detail page
  /// (Now Playing, a search jump, a rail destination) arm nothing.
  static void arm(BuildContext context, String location) {
    final route = _parseLocation(location);
    if (route == null) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return;
    final topLeft = box.localToGlobal(Offset.zero);
    final side = math.min(box.size.width, box.size.height);
    // A row or a rail glyph is not a cover; below this the flight reads as a
    // stray square rather than something growing out of what was pressed.
    // Above it, the caller passed a page-level context instead of the card's,
    // and a whole-page square would zoom in from nowhere.
    if (side < 32 || side > 520) return;
    _armed = _FlightSource(
      kind: route.$1,
      id: route.$2,
      from: Rect.fromLTWH(topLeft.dx, topLeft.dy, side, side),
      // Artist covers are circles everywhere in the app; album and playlist
      // covers are the artwork radius.
      fromRadius: route.$1 == 'artist' ? side / 2 : WaveRadius.artwork,
      recordedAt: DateTime.now(),
    );
  }

  /// Drops any recorded source. Only tests use it, so one case cannot inherit
  /// the next one's arm.
  @visibleForTesting
  static void reset() => _armed = null;

  /// True while a source is waiting for its destination. The router uses it to
  /// drop the press-anchored page scale: the cover is already doing the
  /// travelling, and scaling the page as well moves the landing spot.
  static bool get isArmed => _armed != null;

  /// Takes the recorded source if it belongs to [kind]/[id] and is fresh.
  static _FlightSource? _claim(String kind, String id) {
    final armed = _armed;
    if (armed == null || armed.kind != kind || armed.id != id) return null;
    _armed = null;
    final age = DateTime.now().difference(armed.recordedAt);
    return age > ttl ? null : armed;
  }

  static (String, String)? _parseLocation(String location) {
    final segments = Uri.parse(location).pathSegments;
    if (segments.length < 2) return null;
    return switch (segments.first) {
      'album' => ('album', segments[1]),
      'artist' => ('artist', segments[1]),
      'playlists' => ('playlist', segments[1]),
      'ytplaylist' => ('ytplaylist', segments[1]),
      _ => null,
    };
  }
}

class _FlightSource {
  const _FlightSource({
    required this.kind,
    required this.id,
    required this.from,
    required this.fromRadius,
    required this.recordedAt,
  });

  final String kind;
  final String id;
  final Rect from;
  final double fromRadius;
  final DateTime recordedAt;
}

/// Destination end of a [WaveFlight]: renders [child] and, when a flight was
/// armed for [kind]/[id], flies a copy of it in from the pressed card.
///
/// The copy is the same widget the header will show, so a cover that is still
/// resolving looks identical in flight and at rest — nothing has to be handed
/// over but geometry.
class WaveFlightTarget extends StatefulWidget {
  final String kind;
  final String id;

  /// Corner radius the cover settles at in the header (a circle passes its
  /// half-size).
  final double radius;

  /// False while the header has no cover to fly (skeleton / empty artwork);
  /// the armed source is left for the next destination.
  final bool enabled;

  final Widget child;

  const WaveFlightTarget({
    super.key,
    required this.kind,
    required this.id,
    required this.child,
    this.radius = WaveRadius.artwork,
    this.enabled = true,
  });

  @override
  State<WaveFlightTarget> createState() => _WaveFlightTargetState();
}

class _WaveFlightTargetState extends State<WaveFlightTarget>
    with SingleTickerProviderStateMixin {
  final GlobalKey _slot = GlobalKey();

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: WaveMotion.normal,
  );

  _FlightSource? _source;
  Rect? _to;
  OverlayEntry? _entry;
  bool _started = false;
  bool _hideChild = false;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      _source = WaveFlight._claim(widget.kind, widget.id);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (_source == null) return;
    // "Arrive, don't travel": under reduce motion the header simply is there.
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _source = null;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _play());
  }

  void _play() {
    if (!mounted || _source == null) return;
    final box = _slot.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final to = box.localToGlobal(Offset.zero) & box.size;
    // A header that has not been laid out (or is offstage) has no landing
    // spot — leave the cover where it is rather than flying to nowhere.
    if (to.width < 8 || to.height < 8) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    _to = to;
    _entry = OverlayEntry(builder: _buildFlight);
    overlay.insert(_entry!);
    setState(() => _hideChild = true);
    _controller
      ..addStatusListener(_onStatus)
      ..addListener(_onTick)
      ..forward();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _finish();
  }

  /// Hands the header its own cover back before the copy dissolves, so the
  /// last stretch fades the flight *out of* the real artwork rather than
  /// leaving an empty frame for a tick.
  void _onTick() {
    if (_hideChild && _controller.value >= 0.82) {
      setState(() => _hideChild = false);
    }
  }

  void _finish() {
    _entry?.remove();
    _entry = null;
    if (!mounted) return;
    setState(() => _hideChild = false);
  }

  @override
  void dispose() {
    _controller
      ..removeStatusListener(_onStatus)
      ..removeListener(_onTick)
      ..dispose();
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  Widget _buildFlight(BuildContext overlayContext) {
    final source = _source!;
    final to = _to!;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_controller.value);
        final rect = Rect.lerp(source.from, to, t)!;
        final radius = lerpDouble(source.fromRadius, widget.radius, t)!;
        // The last stretch dissolves the copy into the cover already in the
        // header, so the hand-off has no double image and no snap.
        final opacity = t < 0.82 ? 1.0 : (1 - (t - 0.82) / 0.18);
        return Positioned.fromRect(
          rect: rect,
          child: IgnorePointer(
            child: Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: FittedBox(
                  fit: BoxFit.cover,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox.fromSize(size: to.size, child: child),
                ),
              ),
            ),
          ),
        );
      },
      child: widget.child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _slot,
      child: _hideChild
          ? Opacity(opacity: 0, child: widget.child)
          : widget.child,
    );
  }
}
