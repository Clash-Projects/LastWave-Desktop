import 'package:fluent_ui/fluent_ui.dart';

import '../theme/tokens.dart';

/// Corner for every text field in the app.
///
/// Fluent's [TextBox] hard-codes a 4px corner and exposes no theme hook for it:
/// the radius only ever comes from a per-field `decoration`. A field is a
/// control, so it takes the control step of the ladder like the buttons it
/// usually sits next to, instead of reading as the one square surface left on
/// an otherwise soft page.
///
/// Only the radius is set. [TextBox] copies that single property onto its own
/// decoration, which is what keeps the stock fill (hover/focus included) and
/// the focus underline untouched.
WidgetStateProperty<BoxDecoration> waveInputDecoration({
  double radius = WaveRadius.controls,
}) {
  return WidgetStatePropertyAll(
    BoxDecoration(borderRadius: BorderRadius.circular(radius)),
  );
}
