import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/transactions/transactions_panel.dart';
import 'package:budget_client/widgets/ui.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Transaction tx(
  String name, {
  TransactionDirection dir = TransactionDirection.debit,
  bool enabled = true,
  String amount = '10',
  RecurrenceMode mode = RecurrenceMode.every,
}) => Transaction(
  id: name,
  poolId: 'a',
  name: name,
  direction: dir,
  amount: Decimal.parse(amount),
  startDate: DateTime(2026, 1, 31),
  recurrenceMode: mode,
  interval: mode == RecurrenceMode.once ? null : 1,
  unit: mode == RecurrenceMode.once ? null : RecurrenceUnit.months,
  endMode: EndMode.never,
  enabled: enabled,
);

void main() {
  final items = [
    tx('Salary', dir: TransactionDirection.credit, amount: '4200'),
    tx('Rent', amount: '2100'),
    tx('Gym', enabled: false),
  ];

  test('filters by text and amount', () {
    expect(filterTransactions(items, 'sal', TxFilter.all).map((t) => t.name), [
      'Salary',
    ]);
    expect(filterTransactions(items, '2100', TxFilter.all).single.name, 'Rent');
    expect(filterTransactions(items, '', TxFilter.all), hasLength(3));
  });

  test('filters by direction and enabled', () {
    expect(
      filterTransactions(items, '', TxFilter.credit).single.name,
      'Salary',
    );
    expect(filterTransactions(items, '', TxFilter.debit), hasLength(2));
    expect(filterTransactions(items, '', TxFilter.disabled).single.name, 'Gym');
    expect(filterTransactions(items, 'rent', TxFilter.credit), isEmpty);
  });

  test('next occurrence is anchored and on/after today', () {
    final t = tx('Rent');
    expect(nextOccurrence(t, DateTime(2026, 3, 1)), DateTime(2026, 3, 31));
    expect(nextOccurrence(t, DateTime(2026, 2, 28)), DateTime(2026, 2, 28));
    expect(nextOccurrence(t, DateTime(2025, 1, 1)), DateTime(2026, 1, 31));
    final once = tx('Once', mode: RecurrenceMode.once);
    expect(nextOccurrence(once, DateTime(2027, 1, 1)), DateTime(2026, 1, 31));
  });

  test('schedule hint words past, one-off and upcoming dates', () {
    expect(
      scheduleHint(tx('Rent'), DateTime(2026, 3, 1)),
      'next Tue 31 Mar 2026',
    );
    final once = tx('Once', mode: RecurrenceMode.once);
    expect(scheduleHint(once, DateTime(2027, 1, 1)), 'on Sat 31 Jan 2026');
  });

  testWidgets('KeyCap and DirectionBadge render', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(children: [KeyCap('Esc'), DirectionBadge(credit: true)]),
        ),
      ),
    );
    expect(find.text('Esc'), findsOneWidget);
    expect(find.byType(DirectionBadge), findsOneWidget);
  });

  test('startPhrase: the series\' first (seed) date', () {
    final t = tx('Rent'); // starts Sat 31 Jan 2026
    expect(startPhrase(t, DateTime(2026, 10, 22)), 'Started Sat 31 Jan 2026');
    expect(startPhrase(t, DateTime(2026, 1, 31)), 'Started Sat 31 Jan 2026');
    expect(startPhrase(t, DateTime(2026, 1, 1)), 'Starts Sat 31 Jan 2026');
    expect(
      startPhrase(t, DateTime(2026, 10, 22), compact: true),
      'Started 31 Jan 2026',
    );
  });
}
