// FormulaField states (spec 011 "States and feedback").
import 'package:budget_client/widgets/formula/formula_field.dart';
import 'package:budget_formula/budget_formula.dart' show VariableUnit;
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'formula_support.dart';

String? previewText(WidgetTester tester) {
  final f = find.byKey(const ValueKey('editor-amount-preview'));
  if (f.evaluate().isEmpty) return null;
  return tester.widget<Text>(f).textSpan!.toPlainText();
}

void main() {
  testWidgets('empty: hint, then the required message', (tester) async {
    await pumpFormula(tester, autofocus: false);
    expect(find.text('0.00'), findsOneWidget);
    expect(lineUnder(tester), isNull);
    await typeText(tester, '5');
    await typeText(tester, '');
    expect(lineUnder(tester), 'Enter an amount');
  });

  testWidgets('plain valid: nothing under the field', (tester) async {
    await pumpFormula(tester);
    await typeText(tester, '1,250.50');
    expect(lineUnder(tester), isNull);
    expect(previewText(tester), isNull);
  });

  for (final (text, message) in [
    ('abc', 'Enter a number, e.g. 1250 or 1,250.50'),
    ('0', 'Enter an amount above zero'),
    ('-5', 'Use Money out instead of a negative amount'),
    ('12abc', 'Enter a number, e.g. 1250 or 1,250.50'),
  ]) {
    testWidgets('plain invalid "$text": today\'s message', (tester) async {
      await pumpFormula(tester);
      await typeText(tester, text);
      expect(lineUnder(tester), message);
    });
  }

  testWidgets('formula valid: preview with ✦, hints after it', (tester) async {
    final h = await pumpFormula(tester);
    await typeText(tester, 'rent / 4');
    expect(lineUnder(tester), isNull);
    expect(previewText(tester), contains(r'= $300.00'));
    expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    expect(h.controller.formula.expr, 'rent / 4');
    await typeText(tester, '1000 * rate');
    expect(previewText(tester), contains(r'= $5,500.00'));
    expect(previewText(tester), contains('rate is a percentage'));
  });

  testWidgets('formula invalid: message + hint, no preview', (tester) async {
    await pumpFormula(tester);
    await typeText(tester, 'rnet * 2');
    expect(lineUnder(tester), contains('rnet'));
    expect(lineUnder(tester), contains('rent'));
    expect(previewText(tester), isNull);
    await typeText(tester, '2 +');
    expect(lineUnder(tester), isNotNull);
    await typeText(tester, 'rent - 2000');
    expect(lineUnder(tester), 'Use Money out instead of a negative amount');
  });

  testWidgets('server flagged: error until the text changes', (tester) async {
    final h = await pumpFormula(tester);
    await typeText(tester, 'gone * 2');
    h.controller.flag('Unknown variable gone', Decimal.parse('2400'));
    await typeText(tester, 'gone * 2');
    expect(
      lineUnder(tester),
      'This formula no longer works: Unknown variable gone. '
      r'Saved value: $2,400.00.',
    );
    expect(h.controller.formula.isValid, isFalse);
    await typeText(tester, 'rent * 2');
    expect(lineUnder(tester), isNull);
    expect(previewText(tester), contains(r'$2,400.00'));
  });

  testWidgets('variables loading: unknowns not flagged, preview …', (
    tester,
  ) async {
    final h = await pumpFormula(tester, scope: sampleScope(loading: true));
    await typeText(tester, 'later * 2');
    expect(lineUnder(tester), isNull);
    expect(previewText(tester), contains('…'));
    expect(h.controller.formula.pending, isTrue);
    expect(h.controller.formula.isValid, isFalse);
  });

  testWidgets('formulas disabled: a formula gets today\'s message', (
    tester,
  ) async {
    await pumpFormula(tester, formulas: false);
    await typeText(tester, 'rent / 4');
    expect(lineUnder(tester), 'Enter a number, e.g. 1250 or 1,250.50');
    final tf = tester.widget<TextField>(
      find.descendant(of: amountField, matching: find.byType(TextField)),
    );
    expect(
      tf.keyboardType,
      const TextInputType.numberWithOptions(decimal: true),
    );
    expect(tf.autocorrect, isTrue);
  });

  testWidgets('formulas on: text keyboard, no autocorrect or smart dashes', (
    tester,
  ) async {
    await pumpFormula(tester);
    final tf = tester.widget<TextField>(
      find.descendant(of: amountField, matching: find.byType(TextField)),
    );
    expect(tf.keyboardType, TextInputType.text);
    expect(tf.autocorrect, isFalse);
    expect(tf.enableSuggestions, isFalse);
    expect(tf.smartDashesType, SmartDashesType.disabled);
    expect(tf.smartQuotesType, SmartQuotesType.disabled);
    expect(tf.textCapitalization, TextCapitalization.none);
    expect(tf.enableIMEPersonalizedLearning, isFalse);
  });

  testWidgets('allowEmpty: empty is valid', (tester) async {
    final h = await pumpFormula(tester, allowEmpty: true);
    await typeText(tester, '5');
    await typeText(tester, '');
    expect(lineUnder(tester), isNull);
    expect(h.controller.formula.isValid, isTrue);
  });

  testWidgets('no "unknown" error while the name is being completed', (
    tester,
  ) async {
    final h = await pumpFormula(tester);
    await typeText(tester, 'r');
    expect(suggestions, findsOneWidget);
    expect(lineUnder(tester), isNull);
    expect(h.controller.formula.isValid, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(lineUnder(tester), isNotNull);
  });

  testWidgets('extraValidator runs after resolution', (tester) async {
    await pumpFormula(
      tester,
      extraValidator: (v) => v.value != null && v.value! > Decimal.fromInt(1000)
          ? 'At most \$1,000 here'
          : null,
    );
    await typeText(tester, 'rent');
    expect(lineUnder(tester), r'At most $1,000 here');
    await typeText(tester, 'rent / 2');
    expect(lineUnder(tester), isNull);
    await typeText(tester, 'abc'); // resolution errors come first
    expect(lineUnder(tester), 'Enter a number, e.g. 1250 or 1,250.50');
  });

  testWidgets('semantics label for a formula', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpFormula(tester);
    await typeText(tester, 'rent / 4');
    expect(
      find.bySemanticsLabel(
        RegExp(r'Amount, formula rent / 4, equals \$300\.00'),
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('a scope change (live hint) re-resolves the preview', (
    tester,
  ) async {
    final h = await pumpFormula(tester);
    await typeText(tester, 'rent / 4');
    expect(previewText(tester), contains(r'$300.00'));
    h.controller.scope = VariableScope(
      variables: [v('rent', '2000', VariableUnit.money)],
    );
    await tester.pumpAndSettle();
    expect(previewText(tester), contains(r'$500.00'));
  });

  testWidgets('a new scope from the widget (provider rebuild) wins', (
    tester,
  ) async {
    final c = FormulaEditingController(text: 'rent / 4');
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: _ScopeSwap(controller: c)),
      ),
    );
    await tester.pumpAndSettle();
    expect(previewText(tester), contains(r'$300.00'));
    tester
        .state<_ScopeSwapState>(find.byType(_ScopeSwap))
        .swap(
          VariableScope(variables: [v('rent', '4000', VariableUnit.money)]),
        );
    await tester.pumpAndSettle();
    expect(previewText(tester), contains(r'$1,000.00'));
  });

  testWidgets('touch: the keys row stays put as the line under it changes', (
    tester,
  ) async {
    await pumpFormula(tester, touch: true);
    final keys = find.byKey(const ValueKey('editor-amount-keys'));
    final y0 = tester.getTopLeft(keys).dy;
    await typeText(tester, '(');
    expect(lineUnder(tester), isNotNull); // error line, below the keys
    expect(tester.getTopLeft(keys).dy, y0);
    await typeText(tester, '(rate)');
    expect(find.byKey(const ValueKey('editor-amount-preview')), findsOneWidget);
    expect(tester.getTopLeft(keys).dy, y0);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('editor-amount-preview'))).dy,
      greaterThan(tester.getBottomLeft(keys).dy),
    );
    // Unfocused: the line goes back into the field's decoration.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(keys, findsNothing);
    expect(find.byKey(const ValueKey('editor-amount-error')), findsNothing);
  });
}

class _ScopeSwap extends StatefulWidget {
  const _ScopeSwap({required this.controller});
  final FormulaEditingController controller;
  @override
  State<_ScopeSwap> createState() => _ScopeSwapState();
}

class _ScopeSwapState extends State<_ScopeSwap> {
  VariableScope scope = sampleScope();
  void swap(VariableScope s) => setState(() => scope = s);
  @override
  Widget build(BuildContext context) => FormulaField(
    key: const ValueKey('editor-amount'),
    spec: amountSpec,
    scope: scope,
    controller: widget.controller,
    formulasEnabled: true,
    touchMode: false,
  );
}
