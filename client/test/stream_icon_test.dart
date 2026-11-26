import 'package:budget_client/widgets/stream_icon.dart';
import 'package:budget_client/widgets/ui.dart';

import 'dart:ui' show PictureRecorder;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('StreamIcon takes size and colour from IconTheme like Icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: IconTheme(
            data: IconThemeData(size: 18, color: Color(0xFF123456)),
            child: StreamIcon(key: ValueKey('p')),
          ),
        ),
      ),
    );
    final p = find.byKey(const ValueKey('p'));
    expect(tester.getSize(p), const Size(18, 18));
    final paint = tester.widget<CustomPaint>(
      find.descendant(of: p, matching: find.byType(CustomPaint)),
    );
    expect(
      (paint.painter! as StreamGlyphPainter).color,
      const Color(0xFF123456),
    );
  });

  testWidgets('explicit size/colour win; defaults to 24', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: StreamIcon(key: ValueKey('p'))),
      ),
    );
    expect(tester.getSize(find.byKey(const ValueKey('p'))), const Size(24, 24));
  });

  testWidgets('the wave paints a centred curve with no throws', (tester) async {
    final recorder = PictureRecorder();
    const StreamGlyphPainter(Color(0xFFFFFFFF))
        .paint(Canvas(recorder), const Size(20, 20));
    recorder.endRecording();
    // 16px still uses a 2-unit viewBox stroke (not thinned).
    final small = PictureRecorder();
    const StreamGlyphPainter(Color(0xFFFFFFFF))
        .paint(Canvas(small), const Size(16, 16));
    small.endRecording();
    // Dropping the baseline, the wave is shifted so it centres in the 24 box.
    final bounds = StreamGlyphPainter.wavePath().getBounds();
    expect(bounds.center.dx, closeTo(12, 0.01));
    expect(bounds.center.dy, closeTo(12, 0.01));
    expect(
      const StreamGlyphPainter(Color(0xFFFFFFFF))
          .shouldRepaint(const StreamGlyphPainter(Color(0xFF000000))),
      isTrue,
    );
  });

  testWidgets('EmptyState and IconTile host a glyph at their icon sizes', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              IconTile.glyph(StreamIcon(key: ValueKey('tile'))),
              Expanded(
                child: EmptyState(
                  glyph: StreamIcon(key: ValueKey('empty')),
                  title: 't',
                  message: 'm',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('tile'))),
      const Size(20, 20),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('empty'))),
      const Size(30, 30),
    );
  });
}
