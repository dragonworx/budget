// Spec 013 group B "before" goldens: the loan form (principal, rate, term,
// charge day) and the rate periods rows, recorded on the stock fields
// before FormulaField replaced them. With formulas off (the default in
// tests) the FormulaField screens must match these files byte for byte.
import 'package:budget_client/features/loans/loan_form.dart';
import 'package:budget_client/features/loans/loan_models.dart';
import 'package:budget_loan/budget_loan.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _form(
  WidgetTester tester,
  double width,
  LoanDraft d, {
  Map<String, String> errors = const {},
}) async {
  tester.view.physicalSize = Size(width, 1500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: StatefulBuilder(
              builder: (context, setState) => LoanForm(
                draft: d,
                errors: errors,
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

Finder _field(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(EditableText),
);

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.enterText(_field(key), text);
  await tester.pumpAndSettle();
}

Future<void> _blur(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
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

LoanDraft _flat() => LoanDraft(
  start: DateTime(2027, 1, 15),
  principal: '20000',
  interestType: InterestType.flat,
  termMonths: 24,
  periods: [RatePeriodDraft(from: DateTime(2027, 1, 15), rate: '9.5')],
);

Future<void> _match(String name, double width) => expectLater(
  find.byType(MaterialApp),
  matchesGoldenFile('../goldens/rollout_b_${name}_${width.toInt()}.png'),
);

void main() {
  for (final width in [700.0, 320.0]) {
    testWidgets('simple loan values ($width)', (tester) async {
      await _form(tester, width, _simple());
      await _match('simple', width);
    });

    testWidgets('simple loan typed errors ($width)', (tester) async {
      await _form(tester, width, _simple());
      await _type(tester, 'loan-principal', 'abc');
      await _type(tester, 'loan-rate-0', '');
      await _type(tester, 'loan-term-years', '0');
      await _type(tester, 'loan-term-months', '0');
      await _blur(tester);
      await _match('simple_errors', width);
    });

    testWidgets('simple loan save errors ($width)', (tester) async {
      await _form(
        tester,
        width,
        _simple(),
        errors: const {
          'principal': 'Enter the amount borrowed',
          'term': 'A term of 1 month to 50 years',
          'rate-0': 'At most 100%',
        },
      );
      await _match('simple_saved_errors', width);
    });

    testWidgets('advanced rows and charge day ($width)', (tester) async {
      await _form(tester, width, _advanced());
      await _match('advanced', width);
    });

    testWidgets('advanced typed errors ($width)', (tester) async {
      await _form(tester, width, _advanced(), errors: const {'rate-1': 'Bad'});
      await _type(tester, 'loan-rate-0', '');
      await _type(tester, 'loan-charge-day-number', '40');
      await _blur(tester);
      await _match('advanced_errors', width);
    });

    testWidgets('flat ($width)', (tester) async {
      await _form(tester, width, _flat());
      await _match('flat', width);
    });
  }
}
