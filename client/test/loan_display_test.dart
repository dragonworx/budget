// Loan display on the timeline (spec 003 §9–§11): the loan label, interest
// names, a loan lane running to its payoff, a "Paid off" marker, and no
// alert colouring on a loan stream (a non-loan stream unchanged).
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/loans/loan_display.dart';
import 'package:budget_client/features/timeline/alert_fill.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/stack_lanes.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chip_taps.dart';
import 'support/fake_loans.dart';

final _start = DateTime(2031, 3, 1);

Map<String, dynamic> _period(String from, String rate) => {
  'from': from,
  'ratePct': rate,
  'type': 'fixed',
  'interestOnly': false,
  'offsetApplies': false,
};

BudgetEvent _loan() => loanEvent(
  start: '2031-03-01',
  terms: loanTermsJson(
    start: '2031-03-01',
    mode: 'advanced',
    termMonths: 360,
    periods: [_period('2031-03-01', '5.89'), _period('2033-03-01', '6.4')],
  ),
);

BudgetEvent _rent() => BudgetEvent(
  id: 'rent',
  streamId: 'acc',
  name: 'Rent',
  direction: EventDirection.debit,
  amount: Decimal.fromInt(10),
  startDate: _start,
  recurrenceMode: RecurrenceMode.every,
  interval: 1,
  unit: RecurrenceUnit.weeks,
  endMode: EndMode.never,
);

Occurrence _occ(
  String id,
  int day,
  String delta, {
  bool derived = false,
  bool payout = false,
  bool flat = false,
}) => Occurrence(
  eventId: id,
  date: _start.add(Duration(days: day)),
  signedDelta: Decimal.parse(delta),
  component: derived ? 'interest' : null,
  derived: derived,
  payout: payout,
  flat: flat,
);

void main() {
  tearDown(() {
    debugAlertFill = null;
    debugLaneAmount = null;
    debugDateMarker = null;
  });

  group('labels', () {
    test('principal and the rate in force on the day', () {
      final t = _loan();
      expect(loanLabel(t, on: DateTime(2031, 6, 1)), 'Loan \$600,000 · 5.89%');
      expect(loanLabel(t, on: DateTime(2033, 3, 1)), 'Loan \$600,000 · 6.40%');
      // Before the start: the first period.
      expect(loanLabel(t, on: DateTime(2030, 1, 1)), 'Loan \$600,000 · 5.89%');
      final flat = loanEvent(
        start: '2031-03-01',
        amount: '10000.50',
        terms: loanTermsJson(
          start: '2031-03-01',
          interestType: 'flat',
          rate: '10',
          termMonths: 24,
        ),
      );
      expect(loanLabel(flat, on: _start), 'Loan \$10,000.50 · 10.00% flat');
      expect(loanLabel(_rent()), isNull);
    });

    test('derived interest names', () {
      expect(
        derivedOccurrenceName(_occ('l', 0, '-1', derived: true)),
        'Interest charged',
      );
      expect(
        derivedOccurrenceName(_occ('l', 0, '-1', derived: true, flat: true)),
        'Flat interest instalment',
      );
      expect(
        derivedOccurrenceName(_occ('l', 0, '-1', derived: true, payout: true)),
        'Payout interest',
      );
      expect(
        derivedOccurrenceName(
          _occ('l', 0, '-1', derived: true, payout: true, flat: true),
        ),
        'Remaining flat interest (no rebate)',
      );
      expect(derivedOccurrenceName(_occ('l', 0, '-1')), isNull);
    });

    test('a loan lane runs to its payoff, else its term end; others as '
        'before', () {
      final loan = _loan();
      final rent = _rent();
      final events = {'loan1': loan, 'rent': rent};
      final plain = buildLaneSet(order: ['loan1', 'rent'], events: events);
      final l = plain.lanes.firstWhere((x) => x.id == 'loan1');
      expect(l.start, _start);
      expect(l.end, DateTime(2061, 3, 1));
      expect(
        l.amountText,
        'Loan \$600,000 · ${loanLabel(loan)!.split('· ')[1]}',
      );
      final paid = buildLaneSet(
        order: ['loan1', 'rent'],
        events: events,
        loanPayoffs: {'loan1': DateTime(2045, 7, 15)},
      );
      expect(
        paid.lanes.firstWhere((x) => x.id == 'loan1').end,
        DateTime(2045, 7, 15),
      );
      // The non-loan lane is untouched either way.
      for (final set in [plain, paid]) {
        final r = set.lanes.firstWhere((x) => x.id == 'rent');
        expect(r.start, _start);
        expect(r.end, isNull);
        expect(r.amountText, isNull);
        expect(r.amount, -10);
      }
    });

    test('a loan stream: the flag or a loan among the events', () {
      expect(streamHasLoan(null, [_rent()]), isFalse);
      expect(streamHasLoan(null, [_rent(), _loan()]), isTrue);
    });
  });

  group('chart', () {
    Future<void> pump(
      WidgetTester tester, {
      required bool alerts,
      Map<String, DateTime> payoffs = const {},
      List<String> log = const [],
    }) async {
      tester.view.physicalSize = const Size(1440, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final points = <BalancePoint>[
        for (var i = 0; i < 60; i++)
          BalancePoint(
            date: _start.add(Duration(days: i)),
            closingBalance: Decimal.fromInt(i < 14 ? -600000 : -602900),
          ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1440,
              height: 800,
              child: BalanceChart(
                series: BalanceSeries(
                  points: points,
                  occurrences: [
                    _occ('loan1', 0, '-600000'),
                    _occ('rent', 7, '-10'),
                    _occ('loan1', 14, '-2900', derived: true),
                  ],
                ),
                seedDate: _start.subtract(const Duration(days: 30)),
                viewStart: _start.subtract(const Duration(days: 2)),
                visibleDays: 40,
                eventNames: const {'loan1': 'Home loan', 'rent': 'Rent'},
                laneOrder: const ['loan1', 'rent'],
                events: {'loan1': _loan(), 'rent': _rent()},
                lossThreshold: 0,
                alerts: alerts,
                loanPayoffs: payoffs,
                onViewportChanged: (_, _) {},
                onCreateOnDay: (_) {},
                onNewOnDay: (_) {},
                onEditEvent: (t, _) => log.add('edit ${t.id}'),
                onTrimOccurrence: (t, _) => log.add('trim ${t.id}'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('a loan stream far below zero shows no alert; the same '
        'chart with alerts is red as before', (tester) async {
      AlertFill? fill;
      double? alertY;
      debugAlertFill = (f, y) {
        fill = f;
        alertY = y;
      };
      await pump(tester, alerts: false);
      expect(fill!.deficit, isEmpty);
      expect(fill!.under, isEmpty);
      expect(fill!.crossings, isEmpty);
      expect(AlertFill.area(fill!.safe), greaterThan(0));
      final rect = tester.getRect(find.byType(BalanceChart));
      expect(alertY, greaterThan(rect.bottom), reason: 'no "Alert <" line');

      await pump(tester, alerts: true);
      expect(AlertFill.area(fill!.deficit), greaterThan(0));
      expect(fill!.safe, isEmpty);
    });

    testWidgets('the loan lane reads its principal and rate; others keep '
        'their signed amount', (tester) async {
      final seen = <String, String>{};
      debugLaneAmount = (name, amount, _, _) => seen[name] = amount;
      await pump(tester, alerts: false);
      expect(seen['Home loan'], 'Loan \$600,000 · 5.89%');
      expect(seen['Rent'], startsWith('−'));
    });

    testWidgets('a "Paid off" marker at the payoff date', (tester) async {
      final marks = <String, DateTime>{};
      debugDateMarker = (label, date, _) => marks[label] = date;
      await pump(tester, alerts: false);
      expect(marks.containsKey('Paid off'), isFalse);
      final payoff = _start.add(const Duration(days: 20));
      await pump(tester, alerts: false, payoffs: {'loan1': payoff});
      expect(marks['Paid off'], payoff);
    });

    testWidgets('an interest dot reads "Interest charged" and offers no '
        'trim (no skip / override exists for it)', (tester) async {
      final log = <String>[];
      await pump(tester, alerts: false, log: log);
      await revealDayTip(
        tester,
        PointerDeviceKind.mouse,
        shown: () => find.text('Interest charged').evaluate().isNotEmpty,
      );
      expect(find.text('Interest charged'), findsOneWidget);
      expect(find.textContaining('Home loan'), findsWidgets);
      await tester.tap(
        find.byKey(const ValueKey('tip-menu-loan1')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tip-menu-edit-loan1')), findsOneWidget);
      expect(find.byKey(const ValueKey('tip-menu-trim-loan1')), findsNothing);
      expect(find.textContaining('Skip'), findsNothing);
      expect(find.textContaining('Once-off'), findsNothing);
    });
  });
}
