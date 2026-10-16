import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/transactions/solve_sheet.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRepo extends AccountRepository {
  _FakeRepo() : super(ApiClient());

  final requests = <SolveRequest>[];

  @override
  Future<SolveResult> solve(String accountId, SolveRequest request) async {
    requests.add(request);
    if (request.amount == null) {
      return SolveResult.fromJson({
        'status': 'incomplete',
        'solved': <String>[],
        'values': {'startDate': '2026-10-12', 'total': '1000', 'interval': 1},
        'needsMore': 1,
        'needsOneOf': ['endDate', 'amount', 'count'],
      });
    }
    return SolveResult.fromJson({
      'status': 'solved',
      'solved': ['endDate', 'count'],
      'values': {
        'startDate': '2026-10-12',
        'endDate': '2027-01-04',
        'lastOccurrenceDate': '2027-01-04',
        'amount': '75',
        'total': '1000',
        'actualTotal': '975',
        'interval': 1,
        'unit': 'weeks',
        'count': 13,
      },
      'transaction': {
        'id': 's1',
        'accountId': 'acc',
        'name': 'Planned transaction',
        'direction': 'debit',
        'amount': '75',
        'startDate': '2026-10-12',
        'recurrenceMode': 'every',
        'interval': 1,
        'unit': 'weeks',
        'endMode': 'count',
        'occurrenceCount': 13,
      },
      'previewOccurrences': <Object>[],
    });
  }
}

void main() {
  testWidgets('start + total + weekly, then increment solves count and end', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final repo = _FakeRepo();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [accountRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          home: Scaffold(
            body: SolveSheet(
              accountId: 'acc',
              initial: SolveRequest(
                name: 'Planned transaction',
                direction: TransactionDirection.debit,
                unit: RecurrenceUnit.weeks,
                interval: 1,
                startDate: DateTime(2026, 10, 12),
                targetTotal: Decimal.parse('1000'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Fill in one more: end date, increment amount or count.'),
      findsOneWidget,
    );
    final create = find.widgetWithText(FilledButton, 'Create transaction');
    expect(tester.widget<FilledButton>(create).onPressed, isNull);

    await tester.enterText(
      find.widgetWithText(TextField, 'Increment amount'),
      '75',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(repo.requests.last.amount, Decimal.parse('75'));
    expect(repo.requests.last.occurrenceCount, isNull);
    expect(find.text('Calculated: 13 times'), findsOneWidget);
    expect(find.text('Calculated: 2027-01-04'), findsOneWidget);
    expect(find.text('Rounded from the 1000 target.'), findsOneWidget);
    expect(tester.widget<FilledButton>(create).onPressed, isNotNull);
  });

  testWidgets('Plan (credit-only) has no debit option and plans a credit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = _FakeRepo();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [accountRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          home: Scaffold(
            body: SolveSheet(
              accountId: 'acc',
              creditOnly: true,
              initial: SolveRequest(
                name: 'Planned income',
                direction: TransactionDirection.debit,
                unit: RecurrenceUnit.weeks,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Debit'), findsNothing);
    expect(find.text('Credit'), findsNothing);
    expect(find.text('Plan income'), findsOneWidget);
    expect(repo.requests, isNotEmpty);
    expect(
      repo.requests.every((r) => r.direction == TransactionDirection.credit),
      isTrue,
    );
  });
}
