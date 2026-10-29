// The merged Plan view: one panel, a "Reach a balance" / "Spread a total"
// switch, the shared schedule carried across, legacy entry points, saved
// scenarios and creating events from either mode.
import 'dart:async';

import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/planning/goal_models.dart';
import 'package:budget_client/features/planning/goal_panel.dart';
import 'package:budget_client/features/planning/plan_panel.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _stream = BudgetStream(
  id: 'acc',
  ownerId: 'u',
  name: 'A',
  seedBalance: Decimal.fromInt(1000),
  seedDate: DateTime(2026, 1, 1),
  lossThreshold: Decimal.zero,
);

String _d(DateTime d) => d.toIso8601String().substring(0, 10);

class _Repo extends StreamRepository {
  _Repo() : super(ApiClient());
  final goals = <GoalRequest>[];
  final solves = <SolveRequest>[];

  @override
  Future<List<Scenario>> scenarios(String streamId) async => [
    Scenario.fromJson({
      'id': 's1',
      'name': 'Holiday',
      'colorIndex': 2,
      'included': true,
      'request': _scenarioRequest.toJson(),
    }),
  ];

  @override
  Future<GoalResult> goal(String streamId, GoalRequest r) async {
    goals.add(r);
    if (r.targetBalance == null || r.endDate == null) {
      return GoalResult.fromJson({
        'status': 'incomplete',
        'solveFor': r.solveFor.name,
        'needsOneOf': [
          if (r.targetBalance == null) 'targetBalance',
          if (r.endDate == null) 'endDate',
        ],
      });
    }
    return GoalResult.fromJson({
      'status': 'solved',
      'solveFor': r.solveFor.name,
      'values': {
        'startDate': _d(r.startDate ?? DateTime(2026, 2, 2)),
        'endDate': _d(r.endDate!),
        'startBalance': '1000.00',
        'targetBalance': '${r.targetBalance}',
        'amount': '${r.amount ?? 280}',
        'interval': r.interval ?? 1,
        'unit': r.unit.name,
        'count': r.count ?? 5,
        'oneOff': '${r.oneOff ?? 0}',
        'rate': 0,
      },
      'projectedStartBalance': '1000.00',
      'baselineEndBalance': '600.00',
      'endBalance': '${r.targetBalance}',
      'lowest': {'date': '2026-02-05', 'closingBalance': '700.00'},
      'alertDate': null,
      'paymentCount': r.count ?? 5,
      'points': [
        {'date': '2026-02-01', 'closingBalance': '1000.00'},
        {'date': '2026-02-02', 'closingBalance': '1280.00'},
      ],
    });
  }

  @override
  Future<SolveResult> solve(String streamId, SolveRequest r) async {
    solves.add(r);
    if (r.amount == null || r.targetTotal == null) {
      return SolveResult.fromJson({
        'status': 'incomplete',
        'solved': <String>[],
        'values': {'interval': 1},
        'needsMore': 1,
        'needsOneOf': ['amount', 'total'],
      });
    }
    return SolveResult.fromJson({
      'status': 'solved',
      'solved': ['endDate', 'count'],
      'values': {
        'startDate': '2026-10-12',
        'endDate': '2027-01-04',
        'lastOccurrenceDate': '2027-01-04',
        'amount': '${r.amount}',
        'total': '${r.targetTotal}',
        'actualTotal': '975',
        'interval': 1,
        'unit': 'weeks',
        'count': 13,
      },
      'event': {
        'id': '',
        'streamId': 'acc',
        'name': 'Planned event',
        'direction': 'credit',
        'amount': '${r.amount}',
        'startDate': '2026-10-12',
        'recurrenceMode': 'every',
        'interval': 1,
        'unit': 'weeks',
        'endMode': 'count',
        'occurrenceCount': 13,
      },
      'previewOccurrences': [
        {'eventId': '', 'date': '2026-10-12', 'signedDelta': '75'},
      ],
    });
  }
}

class _Events extends EventRepository {
  _Events() : super(ApiClient());
  final created = <BudgetEvent>[];
  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async => [];
  @override
  Future<BudgetEvent> create(String streamId, BudgetEvent draft) async {
    created.add(draft);
    return draft.copyWith(id: 'e${created.length}');
  }
}

final _scenarioRequest = GoalRequest(
  solveFor: GoalVar.count,
  mode: GoalMode.onDate,
  startDate: DateTime(2026, 3, 2),
  endDate: DateTime(2026, 9, 28),
  startBalance: 1500,
  targetBalance: 8000,
  amount: 400,
  interval: 2,
  unit: RecurrenceUnit.weeks,
  oneOff: -250,
  rate: 3,
);

class _H {
  _H(this.repo, this.events);
  final _Repo repo;
  final _Events events;
  final goalKey = GlobalKey<GoalPanelState>();
  PlanTab tab = PlanTab.goal;
  final done = <SolveResult>[];
}

Future<_H> _pump(WidgetTester t, {PlanTab tab = PlanTab.goal}) async {
  t.view.physicalSize = const Size(520, 2600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final h = _H(_Repo(), _Events())..tab = tab;
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        streamRepositoryProvider.overrideWithValue(h.repo),
        eventRepositoryProvider.overrideWithValue(h.events),
        scenarioResultsProvider.overrideWith(
          (ref, id) async => [
            for (final s in await h.repo.scenarios(id)) (s, null),
          ],
        ),
        insightsProvider.overrideWith(
          (ref, id) => Completer<BalanceInsights>().future,
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => PlanPanel(
              stream: _stream,
              tab: h.tab,
              onTab: (v) => setState(() => h.tab = v),
              onClose: () {},
              onPreview: (_) {},
              onDone: h.done.add,
              onGoalResult: (_, _) {},
              goalKey: h.goalKey,
              // As the timeline wires it.
              onLoadScenario: (sc) {
                setState(() => h.tab = PlanTab.goal);
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => h.goalKey.currentState?.load(sc.request),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  return h;
}

Future<void> _settle(WidgetTester t) async {
  await t.pump(const Duration(milliseconds: 400));
  await t.pumpAndSettle();
}

Finder _field(String label) => find.widgetWithText(TextField, label);

void main() {
  testWidgets('one Plan view: the switch reads "Reach a balance" / '
      '"Spread a total"; each mode shows its own extras', (t) async {
    final h = await _pump(t);
    expect(find.text('Reach a balance'), findsOneWidget);
    expect(find.text('Spread a total'), findsOneWidget);
    expect(find.text('Plan a goal'), findsNothing);
    expect(find.text('Plan a payment'), findsNothing);
    // Reach a balance: target / start balance, end-date vs stay-above,
    // one-off and interest.
    for (final k in [
      'goal-field-targetBalance',
      'goal-field-startBalance',
      'goal-field-oneOff',
      'goal-field-rate',
      'goal-mode',
    ]) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }

    await t.tap(find.byKey(const ValueKey('plan-mode-total')));
    await t.pumpAndSettle();
    expect(h.tab, PlanTab.payment);
    // Spread a total: total and the schedule; no balance fields of its own.
    expect(_field('Total amount'), findsOneWidget);
    expect(_field('Amount each time'), findsOneWidget);
    expect(find.text('Count'), findsWidgets);
    expect(find.text('Target balance (optional)'), findsNothing);
    expect(find.byKey(const ValueKey('plan-target-balance')), findsNothing);
    expect(find.byKey(const ValueKey('plan-total-from-balance')), findsNothing);
    expect(find.text('Increment amount'), findsNothing);
    // Order: total first, then start, end, amount each time, count.
    double y(Finder f) => t.getTopLeft(f).dy;
    expect(y(_field('Total amount')), lessThan(y(find.text('Start date'))));
    expect(y(find.text('Start date')), lessThan(y(find.text('End date'))));
    expect(y(find.text('End date')), lessThan(y(_field('Amount each time'))));
    expect(h.repo.solves.last.targetBalance, isNull);

    await t.tap(find.byKey(const ValueKey('plan-mode-balance')));
    await t.pumpAndSettle();
    expect(h.tab, PlanTab.goal);
    expect(t.takeException(), isNull);
  });

  testWidgets('switching carries the schedule both ways (start, end, amount '
      'each time, frequency, count); a solved value is not carried', (t) async {
    final h = await _pump(t);
    h.goalKey.currentState!.load(
      GoalRequest(
        solveFor: GoalVar.count,
        startDate: DateTime(2026, 2, 2),
        endDate: DateTime(2026, 6, 29),
        targetBalance: 5000,
        amount: 250,
        interval: 2,
        unit: RecurrenceUnit.weeks,
      ),
    );
    await t.pumpAndSettle();

    await t.tap(find.text('Spread a total'));
    await _settle(t);
    var s = h.repo.solves.last;
    expect(s.startDate, DateTime(2026, 2, 2));
    expect(s.endDate, DateTime(2026, 6, 29));
    expect(s.amount, Decimal.parse('250'));
    expect(s.interval, 2);
    expect(s.unit, RecurrenceUnit.weeks);
    // Count was the balance mode's solved value: left blank here.
    expect(s.occurrenceCount, isNull);
    expect(s.direction, EventDirection.credit);

    await t.enterText(_field('Amount each time'), '300');
    await t.enterText(_field('Count'), '6');
    await _settle(t);

    final before = h.repo.goals.length;
    await t.tap(find.text('Reach a balance'));
    await _settle(t);
    expect(h.repo.goals.length, greaterThan(before));
    final g = h.repo.goals.last;
    expect(g.startDate, DateTime(2026, 2, 2));
    expect(g.endDate, DateTime(2026, 6, 29));
    expect(g.amount, 300);
    expect(g.interval, 2);
    expect(g.unit, RecurrenceUnit.weeks);
    expect(g.count, 6);
    // Everything in the schedule is locked now: the solve slot moves to
    // the target balance.
    expect(g.solveFor, GoalVar.targetBalance);
    expect(
      find.byKey(const ValueKey('goal-solved-targetBalance')),
      findsOneWidget,
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('a money-out amount does not carry into Spread a total (it '
      'plans income); the start date does', (t) async {
    final h = await _pump(t);
    h.goalKey.currentState!.load(
      GoalRequest(
        solveFor: GoalVar.count,
        startDate: DateTime(2026, 2, 2),
        endDate: DateTime(2026, 6, 29),
        targetBalance: 0,
        amount: -120,
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Spread a total'));
    await _settle(t);
    expect(h.repo.solves.last.amount, isNull);
    expect(h.repo.solves.last.startDate, DateTime(2026, 2, 2));
  });

  testWidgets('a carried amount is locked in Reach a balance: the solve '
      'slot moves to the end date', (t) async {
    final h = await _pump(t, tab: PlanTab.payment);
    await t.enterText(_field('Total amount'), '600');
    await t.enterText(_field('Amount each time'), '50');
    await _settle(t);
    await t.tap(find.text('Reach a balance'));
    await _settle(t);
    final g = h.repo.goals.last;
    expect(g.amount, 50);
    expect(g.solveFor, GoalVar.endDate);
    expect(find.byKey(const ValueKey('goal-solved-endDate')), findsOneWidget);
    // The total is the other mode's own: not a balance.
    expect(g.targetBalance, isNull);
    expect(find.textContaining('target balance'), findsWidgets);
  });

  testWidgets('a saved scenario loads unchanged into Reach a balance', (
    t,
  ) async {
    final h = await _pump(t, tab: PlanTab.payment);
    await t.tap(find.byKey(const ValueKey('plan-tab-scenarios')));
    await t.pumpAndSettle();
    expect(h.tab, PlanTab.scenarios);
    await t.tap(find.byKey(const ValueKey('scenario-load-s1')));
    await t.pumpAndSettle();
    expect(h.tab, PlanTab.goal);
    final r = h.repo.goals.last;
    expect(r.toJson(), _scenarioRequest.toJson());
    expect(find.byKey(const ValueKey('goal-solved-count')), findsOneWidget);
    // Complete: no summary panel.
    expect(find.byKey(const ValueKey('goal-status')), findsNothing);
  });

  testWidgets('Reach a balance: Add plan to stream creates the recurring '
      'payment and the one-off', (t) async {
    final h = await _pump(t);
    h.goalKey.currentState!.load(_scenarioRequest);
    await t.pumpAndSettle();
    final add = find.byKey(const ValueKey('goal-add-events'));
    await t.ensureVisible(add);
    await t.tap(add);
    await t.pumpAndSettle();
    expect(h.events.created, hasLength(2));
    final rec = h.events.created[0];
    expect(rec.direction, EventDirection.credit);
    expect(rec.amount, Decimal.parse('400'));
    expect(rec.recurrenceMode, RecurrenceMode.every);
    expect(rec.interval, 2);
    expect(rec.unit, RecurrenceUnit.weeks);
    expect(rec.occurrenceCount, 5);
    expect(rec.startDate, DateTime(2026, 3, 2));
    final one = h.events.created[1];
    expect(one.direction, EventDirection.debit);
    expect(one.amount, Decimal.parse('250'));
    expect(one.recurrenceMode, RecurrenceMode.once);
  });

  testWidgets('Spread a total: Add plan to stream creates one income event', (
    t,
  ) async {
    final h = await _pump(t, tab: PlanTab.payment);
    await t.enterText(_field('Total amount'), '1000');
    await t.enterText(_field('Amount each time'), '75');
    await _settle(t);
    expect(h.repo.solves.last.targetTotal, Decimal.parse('1000'));
    final add = find.widgetWithText(FilledButton, 'Add plan to stream');
    await t.ensureVisible(add);
    await t.tap(add);
    await t.pumpAndSettle();
    expect(h.events.created, hasLength(1));
    final e = h.events.created.single;
    expect(e.direction, EventDirection.credit);
    expect(e.amount, Decimal.parse('75'));
    expect(e.occurrenceCount, 13);
    expect(h.done, hasLength(1));
  });
}
