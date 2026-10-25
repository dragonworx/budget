import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/reminders/reminders_model.dart';
import 'package:budget_client/features/reminders/reminders_page.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

BudgetEvent tx(
  String id, {
  EventDirection dir = EventDirection.debit,
  String amount = '10',
  DateTime? start,
  RecurrenceMode mode = RecurrenceMode.once,
  RecurrenceUnit unit = RecurrenceUnit.weeks,
  int interval = 1,
  EndMode end = EndMode.never,
  int? count,
  bool enabled = true,
}) => BudgetEvent(
  id: id,
  streamId: 'a',
  name: id,
  direction: dir,
  amount: Decimal.parse(amount),
  startDate: start ?? DateTime(2026, 10, 19),
  recurrenceMode: mode,
  interval: mode == RecurrenceMode.once ? null : interval,
  unit: mode == RecurrenceMode.once ? null : unit,
  endMode: end,
  occurrenceCount: count,
  enabled: enabled,
);

final stream = BudgetStream(
  id: 'a',
  ownerId: 'u',
  name: 'Everyday',
  seedBalance: Decimal.zero,
  seedDate: DateTime(2026, 1, 1),
  lossThreshold: Decimal.zero,
);

void main() {
  final today = DateTime(2026, 10, 19);

  test('expands recurring and one-off occurrences within range', () {
    final items = expandOccurrences(
      [
        tx('weekly', mode: RecurrenceMode.every, start: DateTime(2025, 1, 6)),
        tx('once', start: DateTime(2026, 10, 21)),
        tx('off', start: DateTime(2026, 10, 20), enabled: false),
        tx(
          'counted',
          mode: RecurrenceMode.every,
          unit: RecurrenceUnit.days,
          start: DateTime(2026, 10, 18),
          end: EndMode.count,
          count: 3,
        ),
      ],
      from: today,
      to: DateTime(2026, 10, 25),
      skipped: {skipKey('counted', DateTime(2026, 10, 19))},
    );
    final names = items.map((i) => '${i.event.id}@${i.date.day}');
    // 2025-01-06 and 2026-10-19 are both Mondays.
    expect(names, ['weekly@19', 'counted@20', 'once@21']);
  });

  test('monthly anchored on the 31st clamps to month end', () {
    final dates = occurrenceDatesBetween(
      tx(
        'm',
        mode: RecurrenceMode.every,
        unit: RecurrenceUnit.months,
        start: DateTime(2026, 1, 31),
      ),
      DateTime(2026, 2, 1),
      DateTime(2026, 4, 30),
    ).toList();
    expect(dates, [
      DateTime(2026, 2, 28),
      DateTime(2026, 3, 31),
      DateTime(2026, 4, 30),
    ]);
  });

  test('groups by day with gain / loss / mixed totals', () {
    final items = expandOccurrences(
      [
        tx('pay', dir: EventDirection.credit, amount: '1000'),
        tx('rent', amount: '400'),
        tx('coffee', amount: '5', start: DateTime(2026, 10, 20)),
        tx(
          'gift',
          dir: EventDirection.credit,
          amount: '50',
          start: DateTime(2026, 10, 21),
        ),
      ],
      from: today,
      to: DateTime(2026, 10, 21),
    );
    final byDay = groupByDay(items);
    expect(byDay.keys, [today, DateTime(2026, 10, 20), DateTime(2026, 10, 21)]);
    final t0 = DayTotals.of(byDay[today]!);
    expect(t0.count, 2);
    expect(t0.gains, Decimal.parse('1000'));
    expect(t0.losses, Decimal.parse('400'));
    expect(t0.net, Decimal.parse('600'));
    expect(t0.tone, DayTone.mixed);
    expect(DayTotals.of(byDay[DateTime(2026, 10, 20)]!).tone, DayTone.loss);
    expect(DayTotals.of(byDay[DateTime(2026, 10, 21)]!).tone, DayTone.gain);
    expect(DayTotals.empty.tone, DayTone.none);
  });

  test('ranges and month grid', () {
    expect(ReminderRange.today.endFrom(today), today);
    expect(ReminderRange.week.endFrom(today), DateTime(2026, 10, 25));
    expect(ReminderRange.month.endFrom(today), DateTime(2026, 11, 18));
    final g = monthGrid(DateTime(2026, 10));
    expect(g.length % 7, 0);
    expect(g.first, DateTime(2026, 9, 28)); // Monday
    expect(g.first.weekday, DateTime.monday);
    expect(g.contains(DateTime(2026, 10, 31)), isTrue);
  });

  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          eventsProvider.overrideWith(() => _FakeTx()),
          balanceProvider.overrideWith(
            (ref, q) async => const BalanceSeries(points: []),
          ),
        ],
        child: MaterialApp(
          home: RemindersPage(stream: stream, today: today),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('side by side when wide, stacked when tall', (tester) async {
    await pump(tester, const Size(1440, 900));
    expect(find.byKey(const ValueKey('reminders-row')), findsOneWidget);
    expect(find.text('pay'), findsOneWidget);
    await pump(tester, const Size(390, 844));
    expect(find.byKey(const ValueKey('reminders-column')), findsOneWidget);
    final cal = tester.getRect(find.byKey(const ValueKey('reminders-grid')));
    final list = tester.getRect(find.byKey(const ValueKey('reminders-list')));
    expect(cal.bottom, lessThanOrEqualTo(list.top));
  });

  testWidgets('badge counts and tap shows tooltip + highlights list', (
    tester,
  ) async {
    await pump(tester, const Size(1440, 900));
    final badge = find.byKey(const ValueKey('reminders-badge-2026-10-19'));
    expect(
      find.descendant(of: badge, matching: find.text('2')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('reminders-day-2026-10-19')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reminders-tooltip')), findsOneWidget);
    expect(find.text('Net'), findsOneWidget);
  });
}

class _FakeTx extends EventsNotifier {
  @override
  Future<List<BudgetEvent>> build(String arg) async => [
    tx('pay', dir: EventDirection.credit, amount: '1000'),
    tx('rent', amount: '400'),
  ];
}
