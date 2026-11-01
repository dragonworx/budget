// Spec 013 group B: the loan form's principal, rates (simple and per
// period), term years / months and charge day take formulas. Each formula
// is saved beside its value (principal: the event's amountExpr; the rest
// in the loan JSON), saved errors show on open, and with formulas off the
// fields and the loan JSON are exactly as before.
import 'dart:convert';

import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/loans/loan_form.dart';
import 'package:budget_client/features/loans/loan_models.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_loan/budget_loan.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../variables/manager_support.dart';

Finder _k(String key) => find.byKey(ValueKey(key));

Finder _input(String key) =>
    find.descendant(of: _k(key), matching: find.byType(EditableText));

String _text(WidgetTester tester, String key) =>
    tester.widget<EditableText>(_input(key)).controller.text;

/// The error line under [key]'s field (null when none).
String? _error(WidgetTester tester, String key) {
  final under = find.byKey(ValueKey('$key-error'));
  if (under.evaluate().isNotEmpty) return tester.widget<Text>(under).data;
  return tester
      .widget<InputDecorator>(
        find.descendant(of: _k(key), matching: find.byType(InputDecorator)),
      )
      .decoration
      .errorText;
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.enterText(_input(key), text);
  await tester.pumpAndSettle();
}

Future<void> _blur(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

Future<void> _form(
  WidgetTester tester,
  LoanDraft d, {
  bool on = true,
  double width = 700,
}) async {
  tester.view.physicalSize = Size(width, 1500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  ServerFeatures.variables = on;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        variableRepositoryProvider.overrideWithValue(FakeVars(baseVars())),
        streamRepositoryProvider.overrideWithValue(FakeStreams(Role.owner)),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: StatefulBuilder(
              builder: (context, setState) => LoanForm(
                draft: d,
                errors: const {},
                onChanged: () => setState(() {}),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

LoanDraft _simple() => LoanDraft(
  start: DateTime(2027, 1, 15),
  principal: '500000',
  termMonths: 360,
  periods: [RatePeriodDraft(from: DateTime(2027, 1, 15), rate: '6.25')],
);

LoanDraft _advanced() => LoanDraft(
  start: DateTime(2027, 1, 15),
  principal: '450000',
  mode: LoanMode.advanced,
  termMonths: 300,
  chargeDay: const DayOfMonthChargeDay(20),
  periods: [
    RatePeriodDraft(from: DateTime(2027, 1, 15), rate: '5.89'),
    RatePeriodDraft(
      from: DateTime(2029, 1, 15),
      rate: '6.4',
      type: RateType.variable,
      offsetApplies: true,
    ),
  ],
);

void main() {
  tearDown(() => ServerFeatures.variables = false);

  testWidgets('principal formula: value and amountExpr', (tester) async {
    final d = _simple();
    await _form(tester, d);
    await _type(tester, 'loan-principal', r'$rent * 100');
    await _blur(tester);
    expect(d.principalValue, Decimal.fromInt(120000));
    expect(d.principalExpr, r'$rent * 100');
    expect(d.principalProblem, isNull);
    expect(d.formulaProblem, isNull);
    // The principal's formula is the event's, not the loan JSON's.
    expect(jsonEncode(d.toJson()), isNot(contains('Expr')));
  });

  testWidgets('simple rate formula: percent value and ratePctExpr', (
    tester,
  ) async {
    final d = _simple();
    await _form(tester, d);
    await _type(tester, 'loan-rate-0', r'$rate + 1.5');
    await _blur(tester);
    final p = d.periods.first;
    expect(Decimal.parse(p.rate), Decimal.fromInt(7));
    expect(p.rateExpr, r'$rate + 1.5');
    final json = d.toJson();
    final period = (json['ratePeriods'] as List).first as Map;
    expect(period['ratePctExpr'], r'$rate + 1.5');
    expect(Decimal.parse('${period['ratePct']}'), Decimal.fromInt(7));
  });

  testWidgets('a money variable in a rate shows the hint', (tester) async {
    final d = _simple();
    await _form(tester, d);
    await _type(tester, 'loan-rate-0', r'$rent / 200');
    expect(
      find.textContaining('not a percentage', findRichText: true),
      findsWidgets,
    );
  });

  testWidgets('term: a formula sends both boxes; integer and range rules', (
    tester,
  ) async {
    final d = _simple();
    await _form(tester, d);
    await _type(tester, 'loan-term-years', r'$months + 13');
    await _type(tester, 'loan-term-months', '6');
    await _blur(tester);
    expect(d.termMonths, 25 * 12 + 6);
    expect(d.termYearsExpr, r'$months + 13');
    expect(d.termMonthsExpr, '6');
    final json = d.toJson();
    expect(json['termYearsExpr'], r'$months + 13');
    expect(json['termMonthsExpr'], '6');
    expect(d.formulaProblem, isNull);

    // Not a whole number.
    await _type(tester, 'loan-term-years', r'$months / 5');
    await _blur(tester);
    expect(_error(tester, 'loan-term-years'), isNotNull);
    expect(d.formulaProblem, isNotNull);

    // Unknown variable.
    await _type(tester, 'loan-term-years', r'$nope + 1');
    await _blur(tester);
    expect(_error(tester, 'loan-term-years'), contains('nope'));
    expect(d.formulaProblem, isNotNull);

    // Back to plain numbers: no exprs, and the JSON is the stock one.
    await _type(tester, 'loan-term-years', '30');
    await _type(tester, 'loan-term-months', '');
    await _blur(tester);
    expect(d.termMonths, 360);
    expect(d.termYearsExpr, isNull);
    expect(d.termMonthsExpr, isNull);
    expect(d.formulaProblem, isNull);
    expect(jsonEncode(d.toJson()), isNot(contains('Expr')));
  });

  testWidgets('charge day formula: chargeDayExpr, 1..31', (tester) async {
    final d = _advanced();
    await _form(tester, d);
    await _type(tester, 'loan-charge-day-number', r'$months + 3');
    await _blur(tester);
    expect(d.chargeDay, const DayOfMonthChargeDay(15));
    expect(d.chargeDayExpr, r'$months + 3');
    expect(d.toJson()['chargeDayExpr'], r'$months + 3');

    await _type(tester, 'loan-charge-day-number', r'$months * 3');
    await _blur(tester);
    expect(_error(tester, 'loan-charge-day-number'), isNotNull);
    expect(d.formulaProblem, isNotNull);
    // The last good day stays until the formula resolves in range.
    expect(d.chargeDay, const DayOfMonthChargeDay(15));
  });

  testWidgets('per-period rate formula in a dense row (320 px)', (
    tester,
  ) async {
    final d = _advanced();
    await _form(tester, d, width: 320);
    await _type(tester, 'loan-rate-1', r'$rate + 1');
    await _blur(tester);
    expect(tester.takeException(), isNull);
    expect(d.periods[1].rateExpr, r'$rate + 1');
    expect(Decimal.parse(d.periods[1].rate), Decimal.parse('6.5'));
    // Dense: the value is in the ✦ tooltip, no picker button in the box.
    expect(_k('loan-rate-1-preview'), findsOneWidget);
    expect(_k('loan-rate-1-var-picker'), findsNothing);
    final rows = (d.toJson()['ratePeriods'] as List).cast<Map>();
    expect(rows[0].containsKey('ratePctExpr'), isFalse);
    expect(rows[1]['ratePctExpr'], r'$rate + 1');
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../goldens/rollout_b_formula_rows_320.png'),
    );
  });

  testWidgets('formulas off: legacy fields, no exprs', (tester) async {
    final d = _simple();
    await _form(tester, d, on: false);
    await _type(tester, 'loan-term-years', r'$months');
    expect(_text(tester, 'loan-term-years'), isNot(contains(r'$')));
    await _type(tester, 'loan-rate-0', r'$rate');
    expect(_text(tester, 'loan-rate-0'), isNot(contains(r'$')));
    expect(jsonEncode(d.toJson()), isNot(contains('Expr')));
  });

  test('loan JSON without formulas is the same with formulas on or off', () {
    for (final d in [_simple(), _advanced()]) {
      ServerFeatures.variables = false;
      final off = jsonEncode(d.toJson());
      ServerFeatures.variables = true;
      expect(jsonEncode(d.toJson()), off);
      expect(off, isNot(contains('Expr')));
    }
  });

  testWidgets('saved formulas round-trip and a saved error is flagged', (
    tester,
  ) async {
    ServerFeatures.variables = true;
    final d = _advanced()
      ..termYearsExpr = r'$months + 13'
      ..termMonthsExpr = '0'
      ..chargeDayExpr = r'$months + 8'
      ..principalExpr = r'$gone * 2';
    d.periods[1].rateExpr = r'$rate + 1';
    d.periods[1].rate = '6.5';
    final json = d.toJson();
    final event = BudgetEvent.fromJson({
      ..._eventJson(json),
      'amountExpr': r'$gone * 2',
      'exprErrors': {
        'amount': {'message': 'Unknown variable: gone'},
      },
    });
    final back = LoanDraft.fromEvent(event)!;
    expect(back.termYearsExpr, r'$months + 13');
    expect(back.chargeDayExpr, r'$months + 8');
    expect(back.periods[1].rateExpr, r'$rate + 1');
    expect(back.principalExpr, r'$gone * 2');

    await _form(tester, back);
    expect(_text(tester, 'loan-term-years'), r'$months + 13');
    expect(_text(tester, 'loan-rate-1'), r'$rate + 1');
    expect(_text(tester, 'loan-charge-day-number'), r'$months + 8');
    expect(_text(tester, 'loan-principal'), r'$gone * 2');
    expect(_error(tester, 'loan-principal'), isNotNull);
    expect(back.formulaProblem, isNotNull);
  });
}

/// A loan event's JSON around [loan] (the server's shape).
Map<String, dynamic> _eventJson(Map<String, Object?> loan) => {
  'id': 'loan1',
  'streamId': 'acc',
  'name': 'Home loan',
  'direction': 'debit',
  'amount': '450000',
  'startDate': '2027-01-15',
  'recurrenceMode': 'once',
  'endMode': 'never',
  'enabled': true,
  'version': 1,
  'kind': 'loan',
  'loan': jsonDecode(jsonEncode(loan)),
  'overrides': <Object>[],
};
