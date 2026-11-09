import 'package:flutter/cupertino.dart' show cupertinoTextSelectionHandleControls;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart' show AdaptiveTextSelectionToolbar;
import 'package:flutter/widgets.dart'
    show BuildContext, EditableTextState, TextSelectionControls, Widget;
import 'package:fluent_ui/fluent_ui.dart' show TextBox;

/// Use iOS-native selection handles and the adaptive iOS Copy/Paste menu
/// without changing the Fluent desktop selection experience.
TextSelectionControls? get waveTextSelectionControls =>
    defaultTargetPlatform == TargetPlatform.iOS
        ? cupertinoTextSelectionHandleControls
        : null;

/// TextBox's default builder is the Fluent/Windows toolbar. On iOS, use
/// Flutter's adaptive toolbar, which resolves to the native Cupertino menu.
Widget waveTextContextMenuBuilder(
  BuildContext context,
  EditableTextState state,
) {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return AdaptiveTextSelectionToolbar.editableText(
      editableTextState: state,
    );
  }
  return TextBox.defaultContextMenuBuilder(context, state);
}
