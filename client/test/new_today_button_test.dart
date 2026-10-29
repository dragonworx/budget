// Header "New event today" (three pluses): always in the header, just
// before Reminders, at every width; opens the New event editor on today.
import 'package:budget_client/widgets/three_plus_glyph.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the glyph paints three plus signs', (t) async {
    expect(ThreePlusPainter.centres, hasLength(3));
    await t.pumpWidget(
      const MaterialApp(home: Center(child: ThreePlusGlyph(size: 24))),
    );
    expect(find.byType(CustomPaint), findsWidgets);
    expect(t.getSize(find.byType(ThreePlusGlyph)), const Size(24, 24));
  });
}
