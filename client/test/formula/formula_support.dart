// Fixtures for the FormulaField tests.
import 'package:budget_client/widgets/formula/formula_field.dart';
import 'package:budget_formula/budget_formula.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'plain_golden_support.dart';

VariableValue v(String name, String value, VariableUnit unit) =>
    VariableValue(name, Decimal.parse(value), unit);

/// rent, rego, fare (substring "re"), rate, weeks, salary.
VariableScope sampleScope({bool loading = false}) => VariableScope(
  streamId: 's1',
  loading: loading,
  variables: [
    v('rent', '1200', VariableUnit.money),
    v('rego', '850', VariableUnit.money),
    v('fare', '4.5', VariableUnit.money),
    v('rate', '5.5', VariableUnit.percent),
    v('weeks', '52', VariableUnit.number),
    v('salary', '90000', VariableUnit.money),
  ],
  descriptions: const {'rent': 'Weekly rent, Glebe flat', 'rate': 'Home loan'},
);

final amountSpec = fieldSpecs['event.amount']!;

Finder get amountField => find.byKey(const ValueKey('editor-amount'));
Finder get suggestions => find.byKey(const ValueKey('formula-suggestions'));
Finder suggestion(String name) =>
    find.byKey(ValueKey('formula-suggestion-$name'));

class Harness {
  Harness(this.controller, this.focus);
  final FormulaEditingController controller;
  final FocusNode focus;
  final submitted = <FormulaValue>[];
  int dialogsClosed = 0;
}

/// A FormulaField in the app theme; [inDialog] opens it in a dialog
/// (Escape there closes the dialog when no list is open).
Future<Harness> pumpFormula(
  WidgetTester tester, {
  String text = '',
  VariableScope? scope,
  double width = 600,
  double height = 600,
  bool touch = false,
  bool inDialog = false,
  bool formulas = true,
  bool allowEmpty = false,
  String? Function(FormulaValue)? extraValidator,
  double topPad = 16,
  bool autofocus = true,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = Harness(FormulaEditingController(text: text), FocusNode());
  addTearDown(h.controller.dispose);
  addTearDown(h.focus.dispose);
  Widget field() => FormulaField(
    key: const ValueKey('editor-amount'),
    spec: amountSpec,
    scope: scope ?? sampleScope(),
    controller: h.controller,
    focusNode: h.focus,
    label: 'Amount',
    prefixText: '\$ ',
    hintText: '0.00',
    autofocus: autofocus,
    formulasEnabled: formulas,
    touchMode: touch,
    allowEmpty: allowEmpty,
    extraValidator: extraValidator,
    onSubmitted: h.submitted.add,
  );
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: testTheme,
      home: Scaffold(
        body: inDialog
            ? Builder(
                builder: (context) => Center(
                  child: TextButton(
                    key: const ValueKey('open-dialog'),
                    onPressed: () async {
                      await showDialog<void>(
                        context: context,
                        builder: (_) => AlertDialog(
                          key: const ValueKey('dialog'),
                          content: SizedBox(
                            width: 400,
                            child: Form(child: field()),
                          ),
                        ),
                      );
                      h.dialogsClosed++;
                    },
                    child: const Text('Open'),
                  ),
                ),
              )
            : Padding(
                padding: EdgeInsets.fromLTRB(16, topPad, 16, 16),
                child: Form(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      RepaintBoundary(
                        key: const ValueKey('frame'),
                        child: field(),
                      ),
                      const SizedBox(height: 8),
                      const TextField(key: ValueKey('next-field')),
                    ],
                  ),
                ),
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (inDialog) {
    await tester.tap(find.byKey(const ValueKey('open-dialog')));
    await tester.pumpAndSettle();
  }
  return h;
}

/// Types [text] with the caret at the end (as the keyboard would).
Future<void> typeText(WidgetTester tester, String text) async {
  await tester.showKeyboard(amountField);
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    ),
  );
  await tester.pumpAndSettle();
}

/// Sets [text] with the caret at [caret].
Future<void> setCaret(WidgetTester tester, String text, int caret) async {
  await tester.showKeyboard(amountField);
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret),
    ),
  );
  await tester.pumpAndSettle();
}

/// The text under the field (error or helper).
String? lineUnder(WidgetTester tester) {
  final d = tester.widget<InputDecorator>(
    find.descendant(of: amountField, matching: find.byType(InputDecorator)),
  );
  final moved = find.byKey(const ValueKey('editor-amount-error'));
  if (moved.evaluate().isNotEmpty) return tester.widget<Text>(moved).data;
  return d.decoration.errorText;
}
