import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/platform/pointer.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('hints name the gesture of the platform', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(isDesktop, isTrue);
    expect(secondaryPress, 'right-click');
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(isDesktop, isFalse);
    expect(secondaryPress, 'long-press');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a right-click on the map reports the point, like a long-press', (tester) async {
    final pressed = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: FlutterMap(
        options: MapOptions(
          initialCenter: const LatLng(42.97, -82.40),
          initialZoom: 12,
          onLongPress: (_, point) => pressed.add('long'),
          onSecondaryTap: (_, point) => pressed.add('right ${point.latitude.toStringAsFixed(2)}'),
        ),
        children: const [],
      ),
    ));
    final centre = tester.getCenter(find.byType(FlutterMap));
    final mouse = await tester.startGesture(centre, kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await mouse.up();
    await tester.pumpAndSettle();
    expect(pressed, ['right 42.97']);
  });

  testWidgets('shortcut letters are ignored while typing', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: TextField())));
    expect(typingInTextField, isFalse);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(typingInTextField, isTrue);
  });
}
