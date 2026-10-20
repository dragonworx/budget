// Plan panels use the transaction editor's Every [− N +] [unit ▾] control:
// the Payment (solve) sheet, where a blank N is calculated (✦), and the
// Goal panel's frequency. Defaults map losslessly to N + unit.
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/planning/goal_models.dart';
import 'package:budget_client/features/planning/goal_panel.dart';
import 'package:budget_client/features/transactions/solve_sheet.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/widgets/recurrence_interval_field.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Solve extends AccountRepository {
  _Solve() : super(ApiClient());
  final requests = <SolveRequest>[];
  @override
  Future<SolveResult> solve(String accountId, SolveRequest request) async {
    requests.add(request);
    // The spacing is calculated whenever it's left blank.
    return SolveResult.fromJson({
      'status': 'incomplete',
      'solved': [if (request.interval == null) 'interval'],
      'values': {'startDate': '2026-10-12', 'interval': 3},
      'needsMore': 1,
      'needsOneOf': ['endDate', 'amount', 'count'],
    });
  }
}

class _Goal extends AccountRepository {
  _Goal() : super(ApiClient());
  final requests = <GoalRequest>[];
  @override
  Future<GoalResult> goal(String accountId, GoalRequest request) async {
    requests.add(request);
    return GoalResult.fromJson({
      'status': 'incomplete',
      'solveFor': request.solveFor.name,
      'needsOneOf': ['targetBalance'],
    });
  }
}

final _account = Account(
  id: 'acc',
  ownerId: 'u',
  name: 'A',
  seedBalance: Decimal.fromInt(1000),
  seedDate: DateTime(2026, 1, 1),
  lossThreshold: Decimal.zero,
);

String _text(WidgetTester tester, String key) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

RecurrenceUnit _unit(WidgetTester tester, String key) => tester
    .widget<DropdownButtonFormField<RecurrenceUnit>>(find.byKey(ValueKey(key)))
    .initialValue!;

Future<void> _touch(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  final g = await tester.startGesture(
    tester.getCenter(f),
    kind: PointerDeviceKind.touch,
  );
  await g.up();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

Future<void> _size(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<_Solve> _pumpSolve(WidgetTester tester, SolveRequest initial) async {
  final repo = _Solve();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [accountRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        home: Scaffold(
          body: SolveSheet(
            accountId: 'acc',
            initial: initial,
            creditOnly: true,
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('Payment: the default plan (weekly, spacing blank) shows '
      'Every [✦ 3] weeks; stepping fixes N; clear goes back to calculated', (
    tester,
  ) async {
    await _size(tester, const Size(390, 2000));
    final repo = await _pumpSolve(tester, defaultPlanRequest());
    expect(_text(tester, 'plan-interval'), '');
    expect(_unit(tester, 'plan-unit'), RecurrenceUnit.weeks);
    // The calculated spacing is the hint, and the unit reads for it.
    expect(find.text('3'), findsWidgets);
    expect(find.text('weeks'), findsWidgets);
    expect(repo.requests.last.interval, isNull);
    expect(repo.requests.last.unit, RecurrenceUnit.weeks);
    // + steps from the calculated value and fixes it.
    for (final k in ['plan-interval-minus', 'plan-interval-plus']) {
      final s = tester.getSize(find.byKey(ValueKey(k)));
      expect(s.width, greaterThanOrEqualTo(44));
      expect(s.height, greaterThanOrEqualTo(44));
    }
    await _touch(tester, find.byKey(const ValueKey('plan-interval-plus')));
    expect(_text(tester, 'plan-interval'), '4');
    expect(repo.requests.last.interval, 4);
    // Unit: months.
    await _touch(tester, find.byKey(const ValueKey('plan-unit')));
    await _touch(tester, find.byKey(const ValueKey('plan-unit-months')).last);
    expect(repo.requests.last.unit, RecurrenceUnit.months);
    expect(repo.requests.last.interval, 4);
    // Clear: calculated again.
    await _touch(tester, find.byKey(const ValueKey('plan-interval-clear')));
    expect(_text(tester, 'plan-interval'), '');
    expect(repo.requests.last.interval, isNull);
    expect(find.byKey(const ValueKey('plan-interval-clear')), findsNothing);
  });

  for (final (n, unit) in const [
    (1, RecurrenceUnit.weeks),
    (2, RecurrenceUnit.weeks),
    (1, RecurrenceUnit.months),
    (3, RecurrenceUnit.months),
    (1, RecurrenceUnit.years),
    (10, RecurrenceUnit.days),
  ]) {
    testWidgets('Payment: a given every $n ${unit.name} opens and solves '
        'unchanged', (tester) async {
      await _size(tester, const Size(900, 2000));
      final repo = await _pumpSolve(
        tester,
        SolveRequest(
          name: 'Plan',
          direction: TransactionDirection.credit,
          unit: unit,
          interval: n,
        ),
      );
      expect(_text(tester, 'plan-interval'), '$n');
      expect(_unit(tester, 'plan-unit'), unit);
      expect(find.text(recurrenceUnitWord(unit, n)), findsWidgets);
      expect(repo.requests.last.interval, n);
      expect(repo.requests.last.unit, unit);
    });
  }

  testWidgets('Goal: frequency is Every [− N +] [unit]; a monthly goal '
      'opens as every 1 month and steps / changes unit', (tester) async {
    await _size(tester, const Size(390, 2000));
    final repo = _Goal();
    final key = GlobalKey<GoalPanelState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [accountRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          home: Scaffold(
            body: GoalPanel(
              key: key,
              account: _account,
              initial: const GoalRequest(
                solveFor: GoalVar.amount,
                unit: RecurrenceUnit.months,
                interval: 1,
              ),
              onResult: (_, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(_text(tester, 'goal-field-interval-interval'), '1');
    expect(_unit(tester, 'goal-field-interval-unit'), RecurrenceUnit.months);
    expect(find.text('month'), findsWidgets);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('goal-field-interval-interval-minus')),
          )
          .onPressed,
      isNull,
    );
    await _touch(
      tester,
      find.byKey(const ValueKey('goal-field-interval-interval-plus')),
    );
    expect(repo.requests.last.interval, 2);
    expect(repo.requests.last.unit, RecurrenceUnit.months);
    await _touch(
      tester,
      find.byKey(const ValueKey('goal-field-interval-unit')),
    );
    await _touch(
      tester,
      find.byKey(const ValueKey('goal-field-interval-unit-weeks')).last,
    );
    expect(repo.requests.last.unit, RecurrenceUnit.weeks);
    expect(repo.requests.last.interval, 2);
    // A scenario load (e.g. quarterly) shows as every 3 months.
    key.currentState!.load(
      const GoalRequest(
        solveFor: GoalVar.amount,
        unit: RecurrenceUnit.months,
        interval: 3,
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(_text(tester, 'goal-field-interval-interval'), '3');
    expect(_unit(tester, 'goal-field-interval-unit'), RecurrenceUnit.months);
  });

  testWidgets('narrow (320px): the row fits without overflow', (tester) async {
    await _size(tester, const Size(320, 2000));
    await _pumpSolve(tester, defaultPlanRequest());
    expect(tester.takeException(), isNull);
    final r = tester.getRect(find.byKey(const ValueKey('plan-unit')));
    expect(r.right, lessThanOrEqualTo(320));
  });
}
