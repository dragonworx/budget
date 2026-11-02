import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/events/event_types.dart';
import 'package:budget_client/features/events/events_panel.dart';
import 'package:budget_client/widgets/ui.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

BudgetEvent tx(
  String name, {
  EventDirection dir = EventDirection.debit,
  bool enabled = true,
  String amount = '10',
  RecurrenceMode mode = RecurrenceMode.every,
}) => BudgetEvent(
  id: name,
  streamId: 'a',
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
    tx('Salary', dir: EventDirection.credit, amount: '4200'),
    tx('Rent', amount: '2100'),
    tx('Gym', enabled: false),
  ];

  test('filters by category', () {
    final withCats = [
      for (final t in items) t.copyWith(categoryId: 'cat-${t.name}'),
    ];
    expect(filterEvents(withCats, allEventTypes), hasLength(3));
    expect(
      filterEvents(withCats, allEventTypes, category: 'cat-Rent').single.name,
      'Rent',
    );
    expect(
      filterEvents(withCats, {EventType.credit}, category: 'cat-Rent'),
      isEmpty,
    );
  });

  test('filters by type; hidden events stay in their type', () {
    expect(filterEvents(items, {EventType.credit}).single.name, 'Salary');
    expect(filterEvents(items, {EventType.debit}), hasLength(2));
    expect(filterEvents(items, {EventType.transfer, EventType.sync}), isEmpty);
    expect(filterEvents(items, allEventTypes), hasLength(3));
  });

  test('none selected shows every event; a selection is a union', () {
    expect(filterEvents(items, const {}), hasLength(3));
    expect(
      filterEvents(items, {EventType.credit, EventType.debit}),
      hasLength(3),
    );
    final xfer = tx('Save')
        .copyWith(transfer: const TransferLink(peerStreamId: 'b'));
    final loan = tx('Mortgage').copyWith(kind: 'loan');
    final all = [...items, xfer, loan];
    expect(filterEvents(all, const {}), all);
    expect(
      filterEvents(all, {
        EventType.credit,
        EventType.transfer,
      }).map((t) => t.name),
      ['Salary', 'Save'],
    );
  });

  test('a transfer is only Transfer; a loan counts by its direction', () {
    final xfer = tx('Save')
        .copyWith(transfer: const TransferLink(peerStreamId: 'b'));
    final loan = tx('Mortgage').copyWith(kind: 'loan');
    expect(eventTypeOf(xfer), EventType.transfer);
    expect(filterEvents([xfer], {EventType.debit}), isEmpty);
    expect(filterEvents([xfer], {EventType.transfer}), [xfer]);
    expect(eventTypeOf(loan), EventType.debit);
    expect(filterEvents([loan], allEventTypes), [loan]);
  });

  test('the four types: labels, order and icons', () {
    expect(EventType.values.map((t) => t.label), [
      'Credit',
      'Debit',
      'Transfer',
      'Sync',
    ]);
    expect(allEventTypes, EventType.values.toSet());
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
