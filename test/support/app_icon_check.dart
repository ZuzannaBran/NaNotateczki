import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:program/core/theme/app_font_loader.dart';
import 'package:program/core/theme/app_theme.dart';

Future<void> verifyAppIcons(WidgetTester tester) async {
  await tester.runAsync(loadAppIconFonts);
  for (final theme in [AppTheme.light(), AppTheme.dark()]) {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const Scaffold(body: Icon(Icons.add)),
      ),
    );
    final richText = tester.widget<RichText>(
      find.descendant(of: find.byType(Icon), matching: find.byType(RichText)),
    );
    final span = richText.text as TextSpan;
    expect(span.style!.fontFamily, 'MaterialIcons');
    final painter = TextPainter(
      text: TextSpan(
        text: span.text,
        style: span.style!.copyWith(fontSize: 48, color: Colors.black),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.white, BlendMode.src);
    painter.paint(canvas, Offset.zero);
    final picture = recorder.endRecording();
    final image = (await tester.runAsync(() => picture.toImage(48, 48)))!;
    final pixels = (await tester.runAsync(() => image.toByteData()))!;
    bool dark(int x, int y) => pixels.getUint8((y * 48 + x) * 4) < 100;
    // A plus has intersecting bars and empty corners; tofu/Ahem does not.
    expect(dark(24, 24), isTrue);
    expect(dark(24, 13), isTrue);
    expect(dark(13, 24), isTrue);
    expect(dark(13, 13), isFalse);
    image.dispose();
    picture.dispose();
    painter.dispose();
  }
}
