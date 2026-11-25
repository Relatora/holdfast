/// Renders the Holdfast mark (lib/brand/holdfast_mark.dart) to the PNGs the
/// launcher-icon and splash generators read. The icon is code, so it is
/// drawn by the same painter the splash screen animates; this keeps the two
/// identical and lets the icon change in review like any other code.
///
///     flutter test tool/render_icons_test.dart
///     dart run flutter_launcher_icons
///     (then the steps in flutter_native_splash.yaml)
///
/// It lives under tool/ rather than test/ so the normal test run doesn't
/// rewrite assets.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/brand/holdfast_mark.dart';
import 'package:material_ui/material_ui.dart';

Future<void> _render(MarkLayers layers, int size, String name) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  HoldfastMarkPainter(layers: layers).paint(canvas, Size.square(size.toDouble()));
  final image = await recorder.endRecording().toImage(size, size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('assets/brand/$name')..createSync(recursive: true);
  file.writeAsBytesSync(png!.buffer.asUint8List());
  image.dispose();
}

Future<void> _blank(int size, String name) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder);
  final image = await recorder.endRecording().toImage(size, size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File('assets/brand/$name').writeAsBytesSync(png!.buffer.asUint8List());
  image.dispose();
}

void main() {
  test('render the brand PNGs', () async {
    await _render(MarkLayers.full, 1024, 'icon.png');
    await _render(MarkLayers.background, 1024, 'icon_background.png');
    await _render(MarkLayers.foreground, 1024, 'icon_foreground.png');
    await _render(MarkLayers.monochrome, 1024, 'icon_monochrome.png');
    // The system splash is plain slate: the intro then draws the mark from
    // nothing, so there is no jump between the two. Android 12+ insists on
    // an icon, so it gets a transparent one.
    await _blank(288, 'splash_blank.png');
    for (final name in ['icon.png', 'icon_foreground.png', 'icon_background.png']) {
      expect(File('assets/brand/$name').lengthSync(), greaterThan(1000), reason: name);
    }
  });
}
