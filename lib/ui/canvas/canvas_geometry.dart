// Pure geometry for the Canvas panel (kept free of UI imports so it can
// be unit-tested without the app's generated secrets).

/// Exact width/height of a Canvas frame.
const double kCanvasAspect = 9 / 16;

/// Width a canvas panel takes for a content area [height] tall, clamped so
/// the page beside it keeps at least [minPage] of [available] width.
///
/// The frame inside the panel is always exactly [kCanvasAspect]; the clamp
/// only ever makes the panel narrower, in which case the frame letterboxes
/// rather than distorting.
double canvasPanelWidth({
  required double height,
  required double available,
  double minPage = 520,
}) {
  final ideal = height * kCanvasAspect;
  final room = available - minPage;
  return ideal.clamp(0.0, room < 220 ? 220.0 : room).toDouble();
}
