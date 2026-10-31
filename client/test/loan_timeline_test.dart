// A loan stream's timeline (spec 003 §9–§14): More → Loan summary, the
// planner off with its notice, no alerts, the loan label in the Events
// list, the lane to the payoff; a non-loan stream unchanged.
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/loans/loan_display.dart';
import 'package:budget_client/features/loans/loan_summary_sheet.dart';
import 'package:budget_client/features/planning/plan_panel.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/timeline_page.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth.dart';
import 'support/fake_categories.dart';
import 'support/fake_loans.dart';

final _now = DateTime.now();
DateTime _d(int o) => DateTime(_now.year, _now.month, _now.day + o);
String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

BudgetStream _stream({required bool loan}) => BudgetStream(
  id: 'acc',
  ownerId: 'u1',
  name: loan ? 'Mortgage' : 'Everyday',
  seedBalance: Decimal.zero,
  seedDate: _d(-60),
  lossThreshold: Decimal.zero,
  role: Role.owner,
  hasLoan: loan,
);

final _loan = loanEvent(
  start: _ymd(_d(-30)),
  terms: loanTermsJson(start: _ymd(_d(-30)), rate: '5.89'),
);

final _rent = BudgetEvent(
  id: 'rent',
  streamId: 'acc',
  name: 'Rent',
  direction: EventDirection.debit,
  amount: Decimal.parse('500'),
  startDate: _d(10),
  recurrenceMode: RecurrenceMode.once,
  endMode: EndMode.never,
);

final _payoff = _d(20);

class _Repo extends FakeLoanStreamRepository {
  _Repo(this.stream)
    : super(
        streams: [stream],
        summary: stream.hasLoan
            ? loanSummaryJson(payoffDate: _ymd(_payoff))
            : null,
      );
  final BudgetStream stream;
  @override
  Future<BudgetStream> get(String id) async => stream;
  @override
  Future<void> markOpened(String id) async {}
  @override
  Future<BalanceSeries> balance(
    String streamId, {
    required DateTime from,
    required DateTime to,
  }) async => BalanceSeries(
    points: [
      for (
        var d = from;
        !d.isAfter(to);
        d = DateTime(d.year, d.month, d.day + 1)
      )
        BalancePoint(
          date: d,
          closingBalance: Decimal.parse(
            stream.hasLoan && !d.isBefore(_d(-30)) ? '-600000' : '-100',
          ),
        ),
    ],
    occurrences: const [],
  );
}

class _TxRepo extends EventRepository {
  _TxRepo(this.loan) : super(ApiClient());
  final bool loan;
  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async => [
    if (loan) _loan,
    _rent,
  ];
}

Future<void> _pump(WidgetTester tester, Size size, {required bool loan}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 0.75;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final c = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(user: adminUser),
      ),
      streamRepositoryProvider.overrideWithValue(_Repo(_stream(loan: loan))),
      categoryRepositoryProvider.overrideWith(
        (ref) => FakeCategoryRepository(ref.watch(eventRepositoryProvider)),
      ),
      eventRepositoryProvider.overrideWithValue(_TxRepo(loan)),
    ],
  );
  addTearDown(c.dispose);
  await c.read(authProvider.future);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: TimelinePage(streamId: 'acc')),
    ),
  );
  await tester.pumpAndSettle();
}

List<String> _moreKeys(WidgetTester tester) {
  final items =
      find
          .byWidgetPredicate((w) => w is PopupMenuItem<String>)
          .evaluate()
          .toList()
        ..sort(
          (a, b) => tester
              .getTopLeft(find.byWidget(a.widget))
              .dy
              .compareTo(tester.getTopLeft(find.byWidget(b.widget)).dy),
        );
  return [for (final e in items) '${(e.widget.key! as ValueKey).value}'];
}

/// The Events list (docked or as a panel).
Future<void> _openList(WidgetTester tester) async {
  if (find.byKey(const ValueKey('panel-new-menu')).evaluate().isNotEmpty) {
    return;
  }
  await tester.tap(find.byKey(const ValueKey('open-events')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('More → Loan summary right after Stream settings opens the '
      'summary; not offered on a non-loan stream', (tester) async {
    await _pump(tester, const Size(800, 900), loan: true);
    await tester.tap(find.byKey(const ValueKey('timeline-more')));
    await tester.pumpAndSettle();
    final keys = _moreKeys(tester);
    expect(keys.take(2), ['more-settings', 'timeline-loan-summary']);
    await tester.tap(find.byKey(const ValueKey('timeline-loan-summary')));
    await tester.pumpAndSettle();
    expect(find.byType(LoanSummaryDialog), findsOneWidget);
    expect(find.byKey(const ValueKey('loan-summary-owed')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('loan-summary-close')));
    await tester.pumpAndSettle();
    expect(find.byType(LoanSummaryDialog), findsNothing);

    // Wide: Stream settings is a header icon, so Loan summary leads More.
    await _pump(tester, const Size(1440, 900), loan: true);
    await tester.tap(find.byKey(const ValueKey('timeline-more')));
    await tester.pumpAndSettle();
    expect(_moreKeys(tester).first, 'timeline-loan-summary');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await _pump(tester, const Size(800, 900), loan: false);
    await tester.tap(find.byKey(const ValueKey('timeline-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timeline-loan-summary')), findsNothing);
    expect(_moreKeys(tester).first, 'more-settings');
  });

  testWidgets('loan stream: chart without alerts, lane to the payoff, '
      'planner off; a non-loan stream keeps all of it', (tester) async {
    await _pump(tester, const Size(1440, 900), loan: true);
    var chart = tester.widget<BalanceChart>(find.byType(BalanceChart));
    expect(chart.alerts, isFalse);
    expect(chart.loanPayoffs, {'loan1': _payoff});
    expect(chart.planDisabledReason, loanPlanningMessage);
    // The docked Events list: the loan's label; Plan disabled, explained.
    await _openList(tester);
    expect(find.text('Loan \$600,000 · 5.89%'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('panel-new-menu')));
    await tester.pumpAndSettle();
    final plan = tester.widget<MenuItemButton>(
      find.byKey(const ValueKey('new-option-plan')),
    );
    expect(plan.onPressed, isNull);
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && w.message == loanPlanningMessage,
      ),
      findsWidgets,
    );
    await tester.tap(find.byKey(const ValueKey('new-option-plan')));
    await tester.pumpAndSettle();
    expect(find.byType(PlanPanel), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await _pump(tester, const Size(1440, 900), loan: false);
    chart = tester.widget<BalanceChart>(find.byType(BalanceChart));
    expect(chart.alerts, isTrue);
    expect(chart.loanPayoffs, isEmpty);
    expect(chart.planDisabledReason, isNull);
    await _openList(tester);
    await tester.tap(find.byKey(const ValueKey('panel-new-menu')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MenuItemButton>(find.byKey(const ValueKey('new-option-plan')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('new-option-plan')));
    await tester.pumpAndSettle();
    expect(find.byType(PlanPanel), findsOneWidget);
  });
}
