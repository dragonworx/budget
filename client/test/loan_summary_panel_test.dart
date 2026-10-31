// The loan summary panel (spec 003 §8): its rows, the warnings, and the
// warning actions (set up repayments, use the minimum, end at payoff,
// match the loan to my repayments), each confirmed first.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/loans/loan_models.dart';
import 'package:budget_client/features/loans/loan_summary_panel.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_categories.dart';
import 'support/fake_loans.dart';
import 'support/fake_streams.dart';

/// The loan stream's side of a monthly repayment transfer from 'pay'.
BudgetEvent repaymentIn({String amount = '3000'}) => BudgetEvent(
  id: 'rep-in',
  streamId: 'acc',
  name: 'Loan repayment',
  direction: EventDirection.credit,
  amount: Decimal.parse(amount),
  startDate: DateTime(2027, 2, 15),
  recurrenceMode: RecurrenceMode.every,
  interval: 1,
  unit: RecurrenceUnit.months,
  endMode: EndMode.never,
  version: 2,
  transfer: const TransferLink(peerStreamId: 'pay', peerEventId: 'rep-out'),
);

const _transfer = {
  'eventId': 'rep-in',
  'peerStreamId': 'pay',
  'amount': '3000.00',
  'frequency': {'rule': 'monthly', 'interval': 1, 'days': <int>[]},
};

late FakeLoanEventRepository events;

Future<void> pumpPanel(
  WidgetTester tester,
  Map<String, dynamic> summary, {
  bool actions = true,
  List<BudgetEvent>? inStream,
  double width = 800,
}) async {
  tester.view.physicalSize = Size(width, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final acc = BudgetStream.fromJson({
    ...testStream('acc', 'Mortgage').toJson(),
    'hasLoan': true,
  });
  final streams = FakeLoanStreamRepository(
    streams: [acc, testStream('pay', 'Everyday')],
    summary: summary,
  );
  events = FakeLoanEventRepository({
    'acc': inStream ?? [loanEvent(), repaymentIn()],
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
        home: Scaffold(
          body: SingleChildScrollView(
            child: LoanSummaryPanel(
              streamId: 'acc',
              summary: LoanSummary.fromJson(summary),
              actions: actions,
              today: DateTime(2027, 2, 20),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

String rowText(WidgetTester tester, String key) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(Text),
      ),
    )
    .map((t) => t.data)
    .join(' | ');

void main() {
  for (final width in [800.0, 320.0]) {
    testWidgets('rows: owed, minimum, interest, payoff (${width}px)', (
      tester,
    ) async {
      await pumpPanel(
        tester,
        loanSummaryJson(transfers: [_transfer]),
        width: width,
      );
      expect(rowText(tester, 'loan-summary-owed'), contains('\$598,765.43'));
      expect(
        rowText(tester, 'loan-summary-minimum-0'),
        'Minimum repayment | \$3,555.00 monthly',
      );
      expect(
        rowText(tester, 'loan-summary-total-interest'),
        contains('\$679,854.21'),
      );
      expect(rowText(tester, 'loan-summary-payoff'), contains('15 Jan 2057'));
      expect(find.text('From Everyday'), findsOneWidget);
      expect(find.text('Interest this month'), findsOneWidget);
      expect(find.text('\$2,902.68'), findsWidgets);
      expect(find.byKey(const ValueKey('loan-summary-estimate')), findsOne);
      expect(
        find.byKey(const ValueKey('loan-warning-no-repayments')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('not paid off: warning and the term-end row', (tester) async {
    await pumpPanel(tester, {
      ...loanSummaryJson(
        transfers: [_transfer],
        warnings: ['notPaidByTermEnd'],
        payoffDate: null,
      ),
      'owedAtTermEnd': '1234.56',
    });
    expect(
      rowText(tester, 'loan-summary-payoff'),
      contains('Not paid off by 15 Jan 2057'),
    );
    expect(rowText(tester, 'loan-summary-term-end'), contains('\$1,234.56'));
    expect(find.byKey(const ValueKey('loan-warning-not-paid')), findsOne);
  });

  testWidgets('no repayments: set up creates a transfer from the payer', (
    tester,
  ) async {
    await pumpPanel(
      tester,
      loanSummaryJson(warnings: ['repaymentScheduleMismatch']),
      inStream: [loanEvent()],
    );
    expect(find.byKey(const ValueKey('loan-warning-no-repayments')), findsOne);
    // No mismatch notice without transfers.
    expect(find.byKey(const ValueKey('loan-warning-schedule')), findsNothing);
    await tapKey(tester, 'loan-setup-repayments');
    expect(find.byKey(const ValueKey('loan-setup-dialog')), findsOneWidget);
    expect(find.text('Everyday'), findsOneWidget);
    final amount = tester.widget<TextField>(
      find.byKey(const ValueKey('loan-setup-amount')),
    );
    expect(amount.controller!.text, '3555.00');
    await tapKey(tester, 'loan-setup-create');
    expect(events.created, hasLength(1));
    final t = events.created.single;
    expect(t.streamId, 'pay');
    expect(t.direction, EventDirection.debit);
    expect(t.transfer!.peerStreamId, 'acc');
    expect(t.amount, Decimal.parse('3555'));
    expect(t.startDate, DateTime(2027, 2, 15));
    expect(t.recurrenceMode, RecurrenceMode.every);
    expect(t.unit, RecurrenceUnit.months);
    expect(find.textContaining('Repayments set up from Everyday'), findsOne);
  });

  testWidgets('below minimum: use the minimum splits the repayments', (
    tester,
  ) async {
    await pumpPanel(
      tester,
      loanSummaryJson(transfers: [_transfer], warnings: ['belowMinimum']),
    );
    expect(find.byKey(const ValueKey('loan-warning-below-minimum')), findsOne);
    await tapKey(tester, 'loan-use-minimum-0');
    expect(find.text('Use the minimum?'), findsOneWidget);
    await tester.tap(find.text('Change repayments'));
    await tester.pumpAndSettle();
    expect(events.calls, contains('split rep-in 3555 2027-02-15'));
  });

  testWidgets('after payoff: end the repayments at payoff', (tester) async {
    await pumpPanel(
      tester,
      loanSummaryJson(
        transfers: [_transfer],
        warnings: ['repaymentsContinueAfterPayoff'],
        payoffDate: '2050-06-15',
      ),
    );
    await tapKey(tester, 'loan-end-at-payoff');
    await tester.tap(find.text('End repayments'));
    await tester.pumpAndSettle();
    final u = events.updated.single;
    expect(u.id, 'rep-in');
    expect(u.endMode, EndMode.untilDate);
    expect(u.endDate, DateTime(2050, 6, 15));
  });

  testWidgets('mismatch: match the loan to my repayments', (tester) async {
    final fortnightly = repaymentIn().copyWith(
      interval: 2,
      unit: RecurrenceUnit.weeks,
      startDate: DateTime(2027, 1, 20),
    );
    await pumpPanel(
      tester,
      loanSummaryJson(
        transfers: [
          {
            ..._transfer,
            'frequency': {'rule': 'everyNWeeks', 'interval': 2, 'days': []},
          },
        ],
        warnings: ['repaymentScheduleMismatch'],
      ),
      inStream: [loanEvent(), fortnightly],
    );
    await tapKey(tester, 'loan-match-schedule');
    await tester.tap(find.text('Match'));
    await tester.pumpAndSettle();
    final u = events.updated.single;
    expect(u.id, 'loan1');
    expect(u.loan!['repaymentFrequency'], 'fortnightly');
    expect(u.loan!['firstRepaymentDate'], '2027-01-20');
    expect(u.isLoan, isTrue);
  });

  testWidgets('without actions the notices show but no buttons', (
    tester,
  ) async {
    await pumpPanel(
      tester,
      loanSummaryJson(warnings: ['belowMinimum']),
      actions: false,
      inStream: [loanEvent()],
    );
    expect(find.byKey(const ValueKey('loan-warning-no-repayments')), findsOne);
    expect(find.byKey(const ValueKey('loan-setup-repayments')), findsNothing);
    expect(find.byKey(const ValueKey('loan-use-minimum-0')), findsNothing);
  });

  testWidgets('reducing fortnightly, charged on repayment dates', (
    tester,
  ) async {
    await pumpPanel(tester, {
      ...loanSummaryJson(
        transfers: [
          {
            ..._transfer,
            'amount': '1500.00',
            'frequency': {'rule': 'everyNWeeks', 'interval': 2, 'days': []},
          },
        ],
      ),
      'repaymentFrequency': 'fortnightly',
      'chargeSchedule': 'onRepaymentDates',
      'chargeDay': null,
      'minimumRepayments': [
        {
          'from': '2027-01-29',
          'frequency': 'fortnightly',
          'amount': '1640.12',
          'reason': 'start',
        },
      ],
    });
    expect(
      rowText(tester, 'loan-summary-minimum-0'),
      'Minimum repayment | \$1,640.12 fortnightly',
    );
    expect(find.text('\$1,500.00 fortnightly'), findsOneWidget);
    expect(find.textContaining('each repayment date'), findsWidgets);
  });

  const flat = {
    'totalInterest': '2000.00',
    'instalments': 24,
    'instalmentInterest': '83.33',
    'lastInstalmentInterest': '83.41',
    'repayment': '500.00',
    'finalRepayment': '500.08',
    'equivalentReducingRatePct': '18.16',
  };

  testWidgets('flat: repayment row and the reducing-rate equivalent', (
    tester,
  ) async {
    await pumpPanel(
      tester,
      loanSummaryJson(transfers: [_transfer], flat: flat),
    );
    expect(
      rowText(tester, 'loan-summary-minimum-0'),
      'Repayment | \$500.00 monthly (final \$500.08)',
    );
    expect(find.text('About 18.16% p.a. (approx.)'), findsOneWidget);
  });

  testWidgets('flat set up: N repayments and the last one overridden', (
    tester,
  ) async {
    await pumpPanel(
      tester,
      {
        ...loanSummaryJson(flat: flat),
        'minimumRepayments': [
          {
            'from': '2027-02-15',
            'frequency': 'monthly',
            'amount': '500.00',
            'reason': 'start',
          },
        ],
      },
      inStream: [loanEvent()],
    );
    await tapKey(tester, 'loan-setup-repayments');
    expect(find.textContaining('24 repayments'), findsOneWidget);
    await tapKey(tester, 'loan-setup-create');
    final t = events.created.single;
    expect(t.endMode, EndMode.count);
    expect(t.occurrenceCount, 24);
    expect(t.amount, Decimal.parse('500'));
    expect(events.calls.last, startsWith('override '));
    expect(events.calls.last, endsWith('2029-01-15 500.08'));
  });
}
