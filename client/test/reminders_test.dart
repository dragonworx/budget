import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/reminders/reminders_model.dart';
import 'package:budget_client/features/reminders/reminders_page.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/theme/app_theme.dart';
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
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('reminders-list')),
        matching: find.text('pay'),
      ),
      findsOneWidget,
    );
    await pump(tester, const Size(390, 844));
    expect(find.byKey(const ValueKey('reminders-column')), findsOneWidget);
    final cal = tester.getRect(find.byKey(const ValueKey('reminders-grid')));
    final list = tester.getRect(find.byKey(const ValueKey('reminders-list')));
    expect(cal.bottom, lessThanOrEqualTo(list.top));
  });

  Color? colorOf(WidgetTester tester, Finder cell, String name) => tester
      .widget<Text>(find.descendant(of: cell, matching: find.text(name)))
      .style
      ?.color;

  testWidgets('day cells list event names, green gains and red losses', (
    tester,
  ) async {
    fakeEvents = defaultEvents;
    await pump(tester, const Size(1440, 900));
    expect(
      find.byKey(const ValueKey('reminders-badge-2026-10-19')),
      findsNothing,
    );
    final cell = find.byKey(const ValueKey('reminders-names-2026-10-19'));
    expect(cell, findsOneWidget);
    expect(colorOf(tester, cell, 'pay'), AppTheme.creditColor);
    expect(colorOf(tester, cell, 'rent'), AppTheme.debitColor);
    // Gains (largest first) above losses, as the list orders them.
    expect(
      tester
          .getTopLeft(find.descendant(of: cell, matching: find.text('pay')))
          .dy,
      lessThan(
        tester
            .getTopLeft(find.descendant(of: cell, matching: find.text('rent')))
            .dy,
      ),
    );
    expect(find.byKey(const ValueKey('reminders-names-more')), findsNothing);
    // Days without events have no list.
    expect(
      find.byKey(const ValueKey('reminders-names-2026-10-20')),
      findsNothing,
    );
  });

  test('name list fits rows to height', () {
    const row = DayNameList.fontSize * DayNameList.lineHeight;
    expect(DayNameList.fit(3, row * 3), (names: 3, more: 0));
    expect(DayNameList.fit(5, row * 3), (names: 2, more: 3));
    expect(DayNameList.fit(5, row * 1.5), (names: 1, more: 4));
    expect(DayNameList.fit(5, row * 0.5), (names: 0, more: 5));
    expect(DayNameList.fit(0, 100), (names: 0, more: 0));
    const small = DayNameList.compactFontSize * DayNameList.compactLineHeight;
    expect(DayNameList.fit(4, small * 1.02, compact: true), (
      names: 1,
      more: 3,
    ));
  });

  for (final size in const [Size(320, 568), Size(390, 844), Size(1440, 900)]) {
    testWidgets('busy day clips with "+N more", no overflow at $size', (
      tester,
    ) async {
      fakeEvents = [
        for (var i = 0; i < 12; i++)
          tx(
            'Long event name number $i',
            dir: i.isEven ? EventDirection.credit : EventDirection.debit,
            amount: '${100 + i}',
          ),
      ];
      addTearDown(() => fakeEvents = defaultEvents);
      await pump(tester, size);
      expect(tester.takeException(), isNull);
      final cell = find.byKey(const ValueKey('reminders-names-2026-10-19'));
      // ignore: avoid_print
      print(
        'cell ${tester.getRect(find.byKey(const ValueKey('reminders-day-2026-10-19')))} names ${tester.getRect(cell)}',
      );
      final more = find.descendant(
        of: cell,
        matching: find.textContaining(RegExp(r'^ ?\+\d+')),
      );
      expect(more, findsOneWidget);
      final shown = find
          .descendant(of: cell, matching: find.textContaining('Long event'))
          .evaluate()
          .length;
      final n = int.parse(
        RegExp(r'\d+').firstMatch(tester.widget<Text>(more).data!)!.group(0)!,
      );
      expect(shown + n, 12);
      // Wide cells spell it out; narrow ones keep just the count.
      if (size.width >= 1000) {
        expect(tester.widget<Text>(more).data, endsWith('more'));
      }
      // Each name is one ellipsised line.
      final first = tester.widget<Text>(
        find
            .descendant(of: cell, matching: find.textContaining('Long event'))
            .first,
      );
      expect(first.maxLines, 1);
      expect(first.overflow, TextOverflow.ellipsis);
      // The visible list stays inside its day cell.
      final day = tester.getRect(
        find.byKey(const ValueKey('reminders-day-2026-10-19')),
      );
      expect(tester.getRect(more).bottom, lessThanOrEqualTo(day.bottom + 0.5));
    });
  }

  testWidgets('day cell semantics list the events', (tester) async {
    fakeEvents = defaultEvents;
    final handle = tester.ensureSemantics();
    await pump(tester, const Size(1440, 900));
    final node = tester.getSemantics(
      find.byKey(const ValueKey('reminders-day-semantics-2026-10-19')),
    );
    expect(node.label, contains('Monday 19 October, 2 events'));
    expect(node.label, contains('pay gain'));
    expect(node.label, contains('rent loss'));
    final empty = tester.getSemantics(
      find.byKey(const ValueKey('reminders-day-semantics-2026-10-20')),
    );
    expect(empty.label, contains('no events'));
    handle.dispose();
  });

  testWidgets('tap shows tooltip + highlights list', (tester) async {
    fakeEvents = defaultEvents;
    await pump(tester, const Size(1440, 900));
    await tester.tap(find.byKey(const ValueKey('reminders-day-2026-10-19')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reminders-tooltip')), findsOneWidget);
    expect(find.text('Net'), findsOneWidget);
  });
}

List<BudgetEvent> fakeEvents = defaultEvents;
final defaultEvents = [
  tx('pay', dir: EventDirection.credit, amount: '1000'),
  tx('rent', amount: '400'),
];

class _FakeTx extends EventsNotifier {
  @override
  Future<List<BudgetEvent>> build(String arg) async => fakeEvents;
}
