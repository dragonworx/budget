// 013 group C: RecurrenceIntervalField with a FormulaEditingController
// (the solve sheet and goal panel switch to it in group D).
import 'package:budget_client/data/models.dart';
import 'package:budget_client/widgets/formula/formula_field.dart';
import 'package:budget_client/widgets/recurrence_interval_field.dart';
import 'package:budget_formula/budget_formula.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../formula/formula_support.dart';
import '../formula/plain_golden_support.dart';

Finder _k(String k) => find.byKey(ValueKey(k));

IconButton _step(WidgetTester t, String k) =>
    t.widget<IconButton>(_k('plan-interval-$k'));

Future<FormulaEditingController> _pump(
  WidgetTester tester, {
  String text = '3',
  bool formulas = true,
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final c = FormulaEditingController(
    text: text,
    spec: fieldSpecs['solve.interval']!,
    formulasEnabled: formulas,
  );
  addTearDown(c.dispose);
  var cleared = 0;
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: testTheme,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            child: StatefulBuilder(
              builder: (context, setState) => RecurrenceIntervalField(
                keyPrefix: 'plan',
                caption: 'Frequency',
                controller: c,
                unit: RecurrenceUnit.weeks,
                allowBlank: true,
                autoInterval: 2,
                spec: fieldSpecs['solve.interval'],
                scope: sampleScope(),
                onChanged: () => setState(() {}),
                onUnitChanged: (_) {},
                onClear: () => setState(() {
                  cleared++;
                  c.clear();
                }),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(cleared, 0);
  return c;
}

void main() {
  setUp(() => ServerFeatures.variables = true);
  tearDown(() => ServerFeatures.variables = false);

  testWidgets('a formula N: steppers off, wider box, value', (tester) async {
    final c = await _pump(tester, width: 600);
    expect(_step(tester, 'plus').onPressed, isNotNull);
    final narrow = tester.getSize(_k('plan-interval')).width;
    expect(narrow, 48);

    await tester.enterText(_k('plan-interval'), r'$weeks / 26');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_step(tester, 'plus').onPressed, isNull);
    expect(_step(tester, 'minus').onPressed, isNull);
    expect(_step(tester, 'minus').tooltip, formulaStepperTip);
    expect(tester.getSize(_k('plan-interval')).width, greaterThan(48));
    expect(c.typedInt, 2);
    expect(c.formula.isFormula, isTrue);
  });

  testWidgets('a number again: steppers step it', (tester) async {
    final c = await _pump(tester, text: r'$weeks / 26');
    expect(_step(tester, 'plus').onPressed, isNull);
    await tester.enterText(_k('plan-interval'), '5');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.tap(_k('plan-interval-plus'));
    await tester.pumpAndSettle();
    expect(c.text, '6');
    expect(_step(tester, 'plus').tooltip, 'More');
    expect(tester.getSize(_k('plan-interval')).width, 48);
  });

  testWidgets('clear empties text and formula', (tester) async {
    final c = await _pump(tester, text: r'$weeks / 26');
    await tester.tap(_k('plan-interval-clear'));
    await tester.pumpAndSettle();
    expect(c.text, isEmpty);
    expect(c.formula.isFormula, isFalse);
    expect(_k('plan-interval-clear'), findsNothing);
    expect(_step(tester, 'plus').onPressed, isNotNull);
  });

  testWidgets('320 px: the unit dropdown never shrinks for a formula', (
    tester,
  ) async {
    await _pump(tester, text: '2', width: 320);
    final plainUnit = tester.getSize(_k('plan-unit')).width;
    await tester.enterText(_k('plan-interval'), r'$weeks / 26 + 1');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(_k('plan-unit')).width, plainUnit);
  });
}
