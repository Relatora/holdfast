import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/brand/holdfast_mark.dart';
import 'package:holdfast/brand/intro_overlay.dart';
import 'package:material_ui/material_ui.dart';

Widget _app({required bool enabled, required bool animate, Duration reading = const Duration(seconds: 7)}) =>
    MaterialApp(
      builder: (context, child) => IntroOverlay(enabled: enabled, animate: animate, readingTime: reading, child: child!),
      home: const Scaffold(body: Text('the map')),
    );

double _opacityOf(WidgetTester tester, String text) {
  final opacity = tester.widget<Opacity>(find.ancestor(of: find.text(text), matching: find.byType(Opacity)).first);
  return opacity.opacity;
}

void main() {
  testWidgets('switched off: the app shows straight away', (tester) async {
    await tester.pumpWidget(_app(enabled: false, animate: true));
    expect(find.text('the map'), findsOneWidget);
    expect(find.text('HOLDFAST'), findsNothing);
  });

  testWidgets('the story plays, then the message stays until a tap', (tester) async {
    await tester.pumpWidget(_app(enabled: true, animate: true));
    expect(_opacityOf(tester, IntroText.message), 0, reason: 'the words come after the storm');
    await tester.pump(); // the story starts once the first frame is up
    await tester.pump(const Duration(milliseconds: 4300));
    expect(_opacityOf(tester, IntroText.message), 1);
    expect(find.text(IntroText.ps), findsOneWidget);
    await tester.tap(find.text('HOLDFAST'));
    await tester.pumpAndSettle();
    expect(find.text('HOLDFAST'), findsNothing);
    expect(find.text('the map'), findsOneWidget);
  });

  testWidgets('any key continues, and the key goes no further', (tester) async {
    await tester.pumpWidget(_app(enabled: true, animate: true));
    await tester.pump(const Duration(seconds: 1));
    final handled = await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    expect(handled, isTrue, reason: 'the map must not also jump to my location');
    await tester.pumpAndSettle();
    expect(find.text('HOLDFAST'), findsNothing);
  });

  testWidgets('reduced motion: the finished frame at once, and it moves on by itself', (tester) async {
    await tester.pumpWidget(_app(enabled: true, animate: false, reading: const Duration(seconds: 3)));
    expect(_opacityOf(tester, IntroText.message), 1);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('HOLDFAST'), findsNothing);
  });

  test('the mark paints every layer without throwing', () {
    for (final layers in MarkLayers.values) {
      final recorder = ui.PictureRecorder();
      HoldfastMarkPainter(layers: layers, progress: const MarkProgress(contours: 0.5, cage: 0.3, flicker: 0.8))
          .paint(Canvas(recorder), const Size.square(64));
      recorder.endRecording().dispose();
    }
  });
}
