/// How the person points at things: a finger on a phone, a mouse on a
/// desktop. The app offers the same actions either way; only the gesture
/// and its wording differ (long-press on a phone, right-click on a PC).
library;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// A desktop operating system, in the app or in a desktop browser: a mouse
/// and keyboard are expected.
bool get isDesktop => switch (defaultTargetPlatform) {
      TargetPlatform.windows || TargetPlatform.macOS || TargetPlatform.linux => true,
      _ => false,
    };

/// The gesture that opens a "more" menu, for hints: "right-click" on a
/// desktop, "long-press" on a phone.
String get secondaryPress => isDesktop ? 'right-click' : 'long-press';

/// True while a text field has the keyboard focus, so single-letter
/// shortcuts don't fire while someone is typing a search.
bool get typingInTextField {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return context.widget is EditableText || context.findAncestorWidgetOfExactType<EditableText>() != null;
}
