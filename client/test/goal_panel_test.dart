import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/planning/goal_models.dart';
import 'package:budget_client/features/planning/goal_panel.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _solved(String solveFor, {String amount = '280.00'}) => {
  'status': 'solved',
  'solveFor': solveFor,
  'values': {
    'startDate': '2026-01-01',
    'endDate': '2026-01-29',
    'startBalance': '1000.00',
    'targetBalance': '2000.00',
    'amount': amount,
    'interval': 1,
    'unit': 'weeks',
    'count': 5,
    'oneOff': '0.00',
    'rate': 0,
  },
  'projectedStartBalance': '1000.00',
  'baselineEndBalance': '600.00',
  'endBalance': '2000.00',
  'lowest': {'date': '2026-01-05', 'closingBalance': '1180.00'},
  'alertDate': null,
  'paymentCount': 5,
  'points': [
    {'date': '2025-12-31', 'closingBalance': '1000.00'},
    {'date': '2026-01-01', 'closingBalance': '1280.00'},
  ],
};

class _Repo extends AccountRepository {
  _Repo() : super(ApiClient());
  final requests = <GoalRequest>[];

  @override
  Future<GoalResult> goal(String accountId, GoalRequest request) async {
    requests.add(request);
    if (request.targetBalance == null || request.endDate == null) {
      return GoalResult.fromJson({
        'status': 'incomplete',
        'solveFor': request.solveFor.name,
        'needsOneOf': [
          if (request.targetBalance == null) 'targetBalance',
          if (request.endDate == null) 'endDate',
        ],
      });
    }
    return GoalResult.fromJson(_solved(request.solveFor.name));
  }
}

final _account = Account(
  id: 'acc',
  projectId: 'p',
  name: 'A',
  currency: 'AUD',
  seedBalance: Decimal.fromInt(1000),
  seedDate: DateTime(2026, 1, 1),
  lossThreshold: Decimal.zero,
);

void main() {
  test('goal request JSON round trip', () {
    final r = GoalRequest(
      solveFor: GoalVar.endDate,
      mode: GoalMode.floor,
      unit: RecurrenceUnit.months,
      startDate: DateTime(2026, 2, 1),
      targetBalance: 500,
      amount: -40,
      interval: 2,
      oneOff: -900,
    );
    final back = GoalRequest.fromJson(r.toJson());
    expect(back.solveFor, GoalVar.endDate);
    expect(back.mode, GoalMode.floor);
    expect(back.unit, RecurrenceUnit.months);
    expect(back.amount, -40);
    expect(back.oneOff, -900);
    expect(back.startDate, DateTime(2026, 2, 1));
  });

  test('a solved goal becomes a recurring and a one-off transaction', () {
    final r = GoalResult.fromJson({
      ..._solved('amount'),
      'values': {
        ...(_solved('amount')['values'] as Map<String, dynamic>),
        'oneOff': '-250.00',
      },
    });
    final txs = r.toTransactions('acc');
    expect(txs.length, 2);
    expect(txs[0].recurrenceMode, RecurrenceMode.every);
    expect(txs[0].occurrenceCount, 5);
    expect(txs[0].direction, TransactionDirection.credit);
    expect(txs[1].direction, TransactionDirection.debit);
    expect(txs[1].amount, Decimal.parse('250.00'));
  });

  testWidgets('moving the solve slot locks the previous answer', (
    tester,
  ) async {
    final repo = _Repo();
    GoalResult? last;
    final key = GlobalKey<GoalPanelState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [accountRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          home: Scaffold(
            body: GoalPanel(
              key: key,
              account: _account,
              onResult: (_, r) => last = r,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Fill in 2 more'), findsOneWidget);

    key.currentState!.setTarget(DateTime(2026, 1, 29), 2000);
    await tester.pumpAndSettle();
    expect(last, isNotNull);
    expect(find.byKey(const ValueKey('goal-solved-amount')), findsOneWidget);
    expect(find.textContaining('Put in'), findsOneWidget);

    // Solve for the count instead: the amount (280) is locked in.
    await tester.tap(find.byKey(const ValueKey('goal-toggle-count')));
    await tester.pumpAndSettle();
    final req = repo.requests.last;
    expect(req.solveFor, GoalVar.count);
    expect(req.amount, 280);
    expect(req.targetBalance, 2000);
    expect(find.byKey(const ValueKey('goal-solved-count')), findsOneWidget);
  });
}
