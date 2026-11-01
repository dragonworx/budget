// 013 group D harnesses: the planner (solve sheet) and the goal panel.
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/events/solve_sheet.dart';
import 'package:budget_client/features/planning/goal_models.dart';
import 'package:budget_client/features/planning/goal_panel.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../formula/plain_golden_support.dart';

Finder k(String key) => find.byKey(ValueKey(key));

class PlanRepo extends StreamRepository {
  PlanRepo() : super(ApiClient());

  final solves = <SolveRequest>[];
  final goals = <GoalRequest>[];

  @override
  Future<SolveResult> solve(String streamId, SolveRequest request) async {
    solves.add(request);
    if (request.amount == null) {
      return SolveResult.fromJson({
        'status': 'incomplete',
        'solved': <String>[],
        'values': {'startDate': '2026-10-12', 'interval': 1},
        'needsMore': 1,
        'needsOneOf': ['endDate', 'amount', 'count'],
      });
    }
    final count = request.occurrenceCount ?? 13;
    return SolveResult.fromJson({
      'status': 'solved',
      'solved': ['endDate', if (request.occurrenceCount == null) 'count'],
      'values': {
        'startDate': '2026-10-12',
        'endDate': '2027-01-04',
        'lastOccurrenceDate': '2027-01-04',
        'amount': '${request.amount}',
        'total': '${request.amount! * Decimal.fromInt(count)}',
        'actualTotal': '${request.amount! * Decimal.fromInt(count)}',
        'interval': request.interval ?? 1,
        'unit': 'weeks',
        'count': count,
      },
      'event': {
        'id': 's1',
        'streamId': 'acc',
        'name': 'Planned income',
        'direction': 'credit',
        'amount': '${request.amount}',
        'startDate': '2026-10-12',
        'recurrenceMode': 'every',
        'interval': request.interval ?? 1,
        'unit': 'weeks',
        'endMode': 'count',
        'occurrenceCount': count,
      },
      'previewOccurrences': const [],
    });
  }

  @override
  Future<GoalResult> goal(String streamId, GoalRequest request) async {
    goals.add(request);
    return GoalResult.fromJson({
      'status': 'incomplete',
      'solveFor': request.solveFor.name,
      'needsOneOf': [
        if (request.targetBalance == null) 'targetBalance',
        if (request.endDate == null) 'endDate',
      ],
    });
  }
}

final planStream = BudgetStream(
  id: 'acc',
  ownerId: 'u',
  name: 'A',
  seedBalance: Decimal.fromInt(1000),
  seedDate: DateTime(2026, 1, 1),
  lossThreshold: Decimal.zero,
);

Future<PlanRepo> pumpPlan(
  WidgetTester tester, {
  required double width,
  SolveRequest? initial,
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = Size(width, 1500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repo = PlanRepo();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        streamRepositoryProvider.overrideWithValue(repo),
        ...overrides,
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: testTheme,
        home: Scaffold(
          body: SolveSheet(
            streamId: 'acc',
            saveOnCommit: false,
            creditOnly: true,
            initial:
                initial ??
                SolveRequest(
                  name: 'Planned income',
                  direction: EventDirection.credit,
                  unit: RecurrenceUnit.weeks,
                  startDate: DateTime(2026, 10, 12),
                ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

Future<(PlanRepo, GlobalKey<GoalPanelState>)> pumpGoal(
  WidgetTester tester, {
  required double width,
  GoalRequest? initial,
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = Size(width, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repo = PlanRepo();
  final key = GlobalKey<GoalPanelState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        streamRepositoryProvider.overrideWithValue(repo),
        ...overrides,
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: testTheme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: GoalPanel(
              key: key,
              stream: planStream,
              initial: initial,
              onResult: (_, _) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (repo, key);
}

/// The planner's count field (no key before 013).
Finder get planCount => find.widgetWithText(TextField, 'Count');

Future<void> typeIn(WidgetTester tester, Object key, String text) async {
  final f = key is Finder ? key : k(key as String);
  await tester.ensureVisible(f);
  await tester.enterText(f, text);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}
