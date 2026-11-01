// Spec 013 group A "before" goldens: the stream dialog (seed, threshold)
// and the loan "Set up repayments" dialog, recorded on the stock fields
// before FormulaField replaced them. With formulas off (the default in
// tests) the FormulaField screens must match these files byte for byte.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/loans/loan_models.dart';
import 'package:budget_client/features/loans/loan_summary_panel.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/widgets/stream_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_categories.dart';
import '../support/fake_loans.dart';
import '../support/fake_streams.dart';

Future<void> _size(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _stream(WidgetTester tester, {BudgetStream? existing}) async {
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showStreamDialog(context, existing: existing),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(ValueKey(key)), text);
  await tester.pumpAndSettle();
}

Future<void> _blur(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

Future<void> _setup(WidgetTester tester) async {
  final acc = BudgetStream.fromJson({
    ...testStream('acc', 'Mortgage').toJson(),
    'hasLoan': true,
  });
  final streams = FakeLoanStreamRepository(
    streams: [acc, testStream('pay', 'Everyday')],
    summary: loanSummaryJson(warnings: ['repaymentScheduleMismatch']),
  );
  final events = FakeLoanEventRepository({
    'acc': [loanEvent()],
    'pay': [],
  });
  final c = ProviderContainer(
    overrides: [
      streamRepositoryProvider.overrideWithValue(streams),
      eventRepositoryProvider.overrideWithValue(events),
      categoryRepositoryProvider.overrideWith(
        (ref) => FakeCategoryRepository(events, ['Loan repayment']),
      ),
    ],
  );
  addTearDown(c.dispose);
  await c.read(streamsProvider.future);
  await c.read(eventsProvider('acc').future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SingleChildScrollView(
            child: LoanSummaryPanel(
              streamId: 'acc',
              summary: LoanSummary.fromJson(
                loanSummaryJson(warnings: ['repaymentScheduleMismatch']),
              ),
              actions: true,
              today: DateTime(2027, 2, 20),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final open = find.byKey(const ValueKey('loan-setup-repayments'));
  await tester.ensureVisible(open);
  await tester.pumpAndSettle();
  await tester.tap(open);
  await tester.pumpAndSettle();
}

Future<void> _golden(String name) => expectLater(
  find.byType(Dialog),
  matchesGoldenFile('../goldens/rollout_a_$name.png'),
);

void main() {
  for (final w in [600.0, 320.0]) {
    final px = w.toInt();
    testWidgets('stream dialog new @$px', (tester) async {
      await _size(tester, w);
      await _stream(tester);
      await _blur(tester);
      await _golden('stream_new_$px');
    });

    testWidgets('stream dialog edit, typed values @$px', (tester) async {
      await _size(tester, w);
      await _stream(tester, existing: testStream('acc', 'Everyday'));
      await _type(tester, 'stream-seed', '-120.50');
      await _type(tester, 'stream-threshold', '1,250');
      await _blur(tester);
      await _golden('stream_values_$px');
    });

    testWidgets('stream dialog errors after Save @$px', (tester) async {
      await _size(tester, w);
      await _stream(tester);
      await _type(tester, 'stream-seed', 'abc');
      await _type(tester, 'stream-threshold', '12x');
      await tester.tap(find.byKey(const ValueKey('stream-save')));
      await tester.pumpAndSettle();
      await _blur(tester);
      await _golden('stream_errors_$px');
      // Fixed while typing, errors clear live.
      await _type(tester, 'stream-seed', '2500');
      await _type(tester, 'stream-threshold', '');
      await _blur(tester);
      await _golden('stream_fixed_$px');
    });

    testWidgets('setup repayments dialog @$px', (tester) async {
      await _size(tester, w);
      await _setup(tester);
      await _golden('setup_$px');
      await _type(tester, 'loan-setup-amount', 'abc');
      await _blur(tester);
      await _golden('setup_invalid_$px');
    });
  }
}
