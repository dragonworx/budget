// Goldens of the formula states (Ahem font in tests: glyphs are blocks,
// colours and layout are what is checked).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'formula_support.dart';

void main() {
  Future<void> shot(WidgetTester tester, String name) => expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('../goldens/formula_$name.png'),
  );

  for (final width in [600.0, 320.0]) {
    final w = width.toInt();

    testWidgets('valid with preview at $w', (tester) async {
      await pumpFormula(tester, width: width, height: 300, autofocus: false);
      await typeText(tester, r'$rent / 4');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await shot(tester, 'valid_preview_$w');
    });

    testWidgets('unknown variable at $w', (tester) async {
      await pumpFormula(tester, width: width, height: 300, autofocus: false);
      await typeText(tester, r'$rnt * 2');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await shot(tester, 'unknown_$w');
    });

    testWidgets('error underline at $w', (tester) async {
      await pumpFormula(tester, width: width, height: 300, autofocus: false);
      await typeText(tester, r'$rent * (2');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await shot(tester, 'error_$w');
    });

    testWidgets('autocomplete open at $w', (tester) async {
      await pumpFormula(tester, width: width, height: 420);
      await typeText(tester, r'$r');
      await tester.pumpAndSettle();
      expect(suggestions, findsOneWidget);
      await shot(tester, 'autocomplete_$w');
    });

    testWidgets('touch operator row at $w', (tester) async {
      await pumpFormula(tester, width: width, height: 300, touch: true);
      await typeText(tester, r'$rent + 10');
      await tester.pumpAndSettle();
      await shot(tester, 'touch_keys_$w');
    });
  }
}
