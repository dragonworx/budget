import 'dart:ui' show PictureRecorder;

import 'package:budget_client/widgets/list_glyph.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ListGlyph takes size and colour from IconTheme like Icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: IconTheme(
            data: IconThemeData(size: 20, color: Color(0xFFABCDEF)),
            child: ListGlyph(key: ValueKey('g')),
          ),
        ),
      ),
    );
    final g = find.byKey(const ValueKey('g'));
    expect(tester.getSize(g), const Size(20, 20));
    final paint = tester.widget<CustomPaint>(
      find.descendant(of: g, matching: find.byType(CustomPaint)),
    );
    expect((paint.painter! as ListGlyphPainter).color, const Color(0xFFABCDEF));
  });

  testWidgets('IconButton colours it like its other icons (accent when set)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IconButton(
            color: const Color(0xFF00FF00),
            onPressed: () {},
            icon: const ListGlyph(key: ValueKey('g')),
          ),
        ),
      ),
    );
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byKey(const ValueKey('g')),
        matching: find.byType(CustomPaint),
      ),
    );
    expect((paint.painter! as ListGlyphPainter).color, const Color(0xFF00FF00));
  });

  test('paints three bullet rows without throwing', () {
    final rec = PictureRecorder();
    const ListGlyphPainter(Color(0xFFFFFFFF))
        .paint(Canvas(rec), const Size(18, 18));
    rec.endRecording();
    expect(ListGlyphPainter.rows, hasLength(3));
  });
}
