// The "before" goldens (spec 011): today's amount TextFormField, recorded
// before FormulaField existed. formula_plain_golden_test.dart renders
// FormulaField (plain text) against these same files.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'plain_golden_support.dart';

void main() {
  for (final width in [600.0, 320.0]) {
    for (final (name, text, interact) in plainCases) {
      testWidgets('today\'s amount field: $name @ ${width.toInt()}', (
        tester,
      ) async {
        final c = TextEditingController(text: interact ? '' : text);
        await pumpFieldFrame(
          tester,
          legacyAmountField(controller: c),
          width: width,
        );
        if (interact) {
          await tester.enterText(find.byType(TextField), text);
          await tester.pumpAndSettle();
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
        }
        await expectLater(
          find.byKey(const ValueKey('frame')),
          matchesGoldenFile(
            '../goldens/formula_plain_${name}_${width.toInt()}.png',
          ),
        );
      });
    }
  }
}
