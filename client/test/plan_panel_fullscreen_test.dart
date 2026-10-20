import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/planning/goal_models.dart';
import 'package:budget_client/features/planning/plan_panel.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Repo extends AccountRepository {
  _Repo() : super(ApiClient());
  @override
  Future<GoalResult> goal(String accountId, GoalRequest request) async =>
      GoalResult.fromJson({
        'status': 'incomplete',
        'solveFor': request.solveFor.name,
        'needsOneOf': ['targetBalance'],
      });
}

final _account = Account(
  id: 'acc',
  ownerId: 'u',
  name: 'A',
  seedBalance: Decimal.fromInt(1000),
  seedDate: DateTime(2026, 1, 1),
  lossThreshold: Decimal.zero,
);

Future<void> _pump(WidgetTester t, {required bool full, VoidCallback? expand}) =>
    t.pumpWidget(
      ProviderScope(
        overrides: [accountRepositoryProvider.overrideWithValue(_Repo())],
        child: MaterialApp(
          home: Scaffold(
            body: PlanPanel(
              account: _account,
              tab: PlanTab.goal,
              onTab: (_) {},
              onClose: () {},
              onPreview: (_) {},
              onDone: (_) {},
              onGoalResult: (_, _) {},
              compact: true,
              fullScreen: full,
              onExpand: expand,
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('full screen drops the panel close (app bar has it)', (t) async {
    await _pump(t, full: true);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan-close')), findsNothing);
    expect(find.byKey(const ValueKey('plan-expand')), findsNothing);
    expect(find.byKey(const ValueKey('plan-tab-scenarios')), findsOneWidget);
  });

  testWidgets('docked on phone portrait offers full screen', (t) async {
    var expanded = 0;
    await _pump(t, full: false, expand: () => expanded++);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan-close')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('plan-expand')));
    expect(expanded, 1);
  });
}
