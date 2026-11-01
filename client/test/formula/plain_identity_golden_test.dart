// FormulaField with plain text must draw exactly today's amount field:
// these compare against the goldens recorded from the TextFormField
// (plain_before_golden_test.dart) before FormulaField existed.
import 'package:budget_client/widgets/formula/formula_field.dart';
import 'package:budget_formula/budget_formula.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'plain_golden_support.dart';

void main() {
  for (final formulas in [false, true]) {
    for (final width in [600.0, 320.0]) {
      for (final (name, text, interact) in plainCases) {
        testWidgets(
          'formulas ${formulas ? 'on' : 'off'}: plain $name at ${width.toInt()}',
          (tester) async {
            final c = FormulaEditingController(text: interact ? '' : text);
            final focus = FocusNode();
            addTearDown(c.dispose);
            addTearDown(focus.dispose);
            await pumpFieldFrame(
              tester,
              FormulaField(
                key: const ValueKey('editor-amount'),
                spec: fieldSpecs['event.amount']!,
                scope: VariableScope.empty,
                controller: c,
                focusNode: focus,
                label: 'Amount',
                prefixText: '\$ ',
                hintText: '0.00',
                formulasEnabled: formulas,
                touchMode: false,
              ),
              width: width,
            );
            if (interact) {
              await tester.enterText(
                find.byKey(const ValueKey('editor-amount')),
                text,
              );
              focus.unfocus();
              await tester.pumpAndSettle();
            }
            await expectLater(
              find.byKey(const ValueKey('frame')),
              matchesGoldenFile(
                '../goldens/formula_plain_${name}_${width.toInt()}.png',
              ),
            );
          },
        );
      }
    }
  }
}
