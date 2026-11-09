import 'package:flutter/cupertino.dart' show cupertinoTextSelectionHandleControls;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/widgets.dart'
    show BuildContext, EditableTextState, SizedBox, TextSelectionControls, Widget;
import 'package:fluent_ui/fluent_ui.dart' show TextBox;

/// Keep iOS-native selection handles and text highlighting, but hide the
/// floating context toolbar. Desktop selection remains Fluent-native.
TextSelectionControls? get waveTextSelectionControls =>
    defaultTargetPlatform == TargetPlatform.iOS
        ? cupertinoTextSelectionHandleControls
        : null;

/// TextBox's default builder is the Fluent/Windows toolbar. Hide that
/// toolbar on iOS while leaving the selection itself intact.
Widget waveTextContextMenuBuilder(
  BuildContext context,
  EditableTextState state,
) {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return const SizedBox.shrink();
  }
  return TextBox.defaultContextMenuBuilder(context, state);
}
