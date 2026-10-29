import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/events/solve_sheet.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRepo extends StreamRepository {
  _FakeRepo() : super(ApiClient());

  final requests = <SolveRequest>[];

  @override
  Future<SolveResult> solve(String streamId, SolveRequest request) async {
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
      'event': {
        'id': 's1',
        'streamId': 'acc',
        'name': 'Planned event',
        'direction': 'debit',
        'amount': '75',
        'startDate': '2026-10-12',
        'recurrenceMode': 'every',
        'interval': 1,
        'unit': 'weeks',
        'endMode': 'count',
        'occurrenceCount': 13,
      },
      'previewOccurrences': [
        for (final d in ['2026-10-12', '2026-10-19', '2026-10-26'])
          {'eventId': 's1', 'date': d, 'signedDelta': '-75'},
      ],
      // The balance-target gap only the old summary showed.
      'balanceTarget': {
        'projectedBalance': '200',
        'targetBalance': '1200',
        'gap': '1000',
      },
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
        overrides: [streamRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          home: Scaffold(
            body: SolveSheet(
              streamId: 'acc',
              initial: SolveRequest(
                name: 'Planned event',
                direction: EventDirection.debit,
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
      find.text('Fill in one more: end date, amount each time or count.'),
      findsOneWidget,
    );
    final create = find.widgetWithText(FilledButton, 'Create event');
    expect(tester.widget<FilledButton>(create).onPressed, isNull);

    await tester.enterText(
      find.widgetWithText(TextField, 'Amount each time'),
      '75',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(repo.requests.last.amount, Decimal.parse('75'));
    expect(repo.requests.last.occurrenceCount, isNull);
    expect(find.text('Calculated: 13 times'), findsOneWidget);
    expect(find.text('Calculated: 2027-01-04'), findsOneWidget);
    expect(tester.widget<FilledButton>(create).onPressed, isNotNull);
  });

  testWidgets('a complete plan shows no summary panel: no schedule, total, '
      'rounding, calculated / assumed lines or date chips; the hint panel is '
      'gone and Create stays reachable and works', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = _FakeRepo();
    SolveResult? committed;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [streamRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          home: Scaffold(
            body: SolveSheet(
              streamId: 'acc',
              initial: SolveRequest(
                name: 'Planned event',
                direction: EventDirection.debit,
                unit: RecurrenceUnit.weeks,
                interval: 1,
                startDate: DateTime(2026, 10, 12),
                targetTotal: Decimal.parse('1000'),
                amount: Decimal.parse('75'),
              ),
              saveOnCommit: false,
              onDone: (r) => committed = r,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(repo.requests, isNotEmpty);
    expect(find.textContaining('Fill in one more'), findsNothing);
    expect(find.byIcon(Icons.lightbulb_outline), findsNothing);
    expect(find.textContaining('every week, 13 times'), findsNothing);
    expect(find.textContaining('Total 975'), findsNothing);
    expect(find.textContaining('Rounded from'), findsNothing);
    expect(find.textContaining('Calculated: end date'), findsNothing);
    expect(find.textContaining('Assumed:'), findsNothing);
    expect(
      find.byKey(const ValueKey('plan-balance-target-info')),
      findsNothing,
    );
    expect(find.byType(Chip), findsNothing);
    expect(find.byIcon(Icons.check_circle_outline), findsNothing);

    final create = find.byKey(const ValueKey('solve-commit'));
    await tester.ensureVisible(create);
    expect(tester.widget<FilledButton>(create).onPressed, isNotNull);
    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(committed?.event?.amount, Decimal.parse('75'));
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
        overrides: [streamRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          home: Scaffold(
            body: SolveSheet(
              streamId: 'acc',
              creditOnly: true,
              initial: SolveRequest(
                name: 'Planned income',
                direction: EventDirection.debit,
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
      repo.requests.every((r) => r.direction == EventDirection.credit),
      isTrue,
    );
  });
}
