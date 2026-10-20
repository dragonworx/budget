import 'dart:ui';

import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/occurrence_info.dart';
import 'package:budget_client/features/timeline/trim.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime(2031, 3, 1);

Transaction _tx(
  String id, {
  RecurrenceMode mode = RecurrenceMode.every,
  EndMode end = EndMode.never,
  DateTime? endDate,
  DateTime? start,
  int? count,
  bool enabled = true,
}) => Transaction(
  id: id,
  poolId: 'a',
  name: 'Tx $id',
  direction: TransactionDirection.debit,
  amount: Decimal.fromInt(100),
  startDate: start ?? _start,
  recurrenceMode: mode,
  interval: mode == RecurrenceMode.every ? 1 : null,
  unit: mode == RecurrenceMode.every ? RecurrenceUnit.weeks : null,
  endMode: end,
  endDate: endDate,
  occurrenceCount: count,
  enabled: enabled,
  version: 3,
);

Occurrence _occ(String id, int day, [int delta = -100]) => Occurrence(
  transactionId: id,
  date: _start.add(Duration(days: day)),
  signedDelta: Decimal.fromInt(delta),
);

void main() {
  final txs = {
    'once': _tx('once', mode: RecurrenceMode.once),
    'ended': _tx(
      'ended',
      end: EndMode.untilDate,
      endDate: _start.add(const Duration(days: 9)),
    ),
    'off': _tx('off', enabled: false),
  };

  test('canTrimOn: only earlier than an existing end, after the start', () {
    final day = _start.add(const Duration(days: 9));
    expect(canTrimOn(txs['ended']!, day), isFalse, reason: 'already ends then');
    expect(
      canTrimOn(txs['ended']!, day.subtract(const Duration(days: 1))),
      isTrue,
    );
    expect(
      canTrimOn(_tx('late', start: _start.add(const Duration(days: 20))), day),
      isFalse,
    );
    expect(canTrimOn(txs['once']!, day), isFalse);
    expect(canTrimOn(txs['off']!, day), isFalse);
    expect(canTrimOn(_tx('c', end: EndMode.count, count: 9), day), isTrue);
  });

  test('popup Trim: only on an occurrence with a later one to drop', () {
    DateTime w(int n) => _start.add(Duration(days: 7 * n));
    expect(canTrimAtOccurrence(_tx('n'), w(0)), isTrue, reason: 'first');
    expect(canTrimAtOccurrence(_tx('n'), w(5)), isTrue);
    final c = _tx('c', end: EndMode.count, count: 3);
    expect(canTrimAtOccurrence(c, w(1)), isTrue);
    expect(canTrimAtOccurrence(c, w(2)), isFalse, reason: 'already last');
    // Ends mid-week: the last occurrence is before the end date.
    final u = _tx(
      'u',
      end: EndMode.untilDate,
      endDate: w(3).add(const Duration(days: 3)),
    );
    expect(canTrimAtOccurrence(u, w(2)), isTrue);
    expect(canTrimAtOccurrence(u, w(3)), isFalse, reason: 'already last');
    expect(
      canTrimAtOccurrence(_tx('o', mode: RecurrenceMode.once), _start),
      isFalse,
    );
    expect(canTrimAtOccurrence(_tx('d', enabled: false), w(1)), isFalse);
  });

  test('trimmed series ends on the day (inclusive), version kept', () {
    final day = DateTime(2031, 3, 14, 12);
    final t = trimmedTransaction(_tx('c', end: EndMode.count, count: 9), day);
    expect(t.endMode, EndMode.untilDate);
    expect(t.endDate, DateTime(2031, 3, 14));
    expect(t.occurrenceCount, isNull);
    expect(t.version, 3);
    expect(t.toCreateJson()['endDate'], '2031-03-14');
  });

  testWidgets('date drag: "+" from the press on, follows the day, never trims; '
      'release only pins (even far up); no drag-to-cancel', (tester) async {
    const size = Size(600, 500);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final rent = _tx('rent');
    final occ = [for (var d = 0; d < 60; d += 7) _occ('rent', d)];
    final points = [
      for (var i = -5; i < 60; i++)
        BalancePoint(
          date: _start.add(Duration(days: i)),
          closingBalance: Decimal.fromInt(
            5000 -
                100 *
                    occ
                        .where(
                          (o) =>
                              o.date.difference(_start).inDays <= i && i >= 0,
                        )
                        .length,
          ),
        ),
    ];
    final created = <DateTime>[];
    final trimmed = <DateTime>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox.fromSize(
            size: size,
            child: BalanceChart(
              series: BalanceSeries(points: points, occurrences: occ),
              seedDate: _start.subtract(const Duration(days: 5)),
              viewStart: _start,
              visibleDays: 30,
              transactions: {'rent': rent},
              transactionNames: const {'rent': 'Rent'},
              onViewportChanged: (_, _) {},
              onCreateOnDay: created.add,
              // Editors: the popup's ⋮ Trim is wired, the drag ignores it.
              onTrimOccurrence: (_, d) => trimmed.add(d),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final layout = ChartLayout.of(size, 30);
    double xOf(int day) =>
        layout.plot.left + (day + 0.5) / 30 * layout.plot.width;
    final add = find.byKey(const ValueKey('pick-add'));
    Rect bubble() => tester.getRect(find.byKey(const ValueKey('pick-bubble')));
    for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      created.clear();
      final g = await tester.startGesture(
        Offset(xOf(10), layout.axis.center.dy),
        kind: kind,
      );
      await tester.pump();
      // On press: the day's "+" is already there.
      expect(add, findsOneWidget, reason: '$kind: + on press');
      expect(find.text('Release, then tap +'), findsOneWidget);
      // It follows the picked day while dragging along the footer.
      for (final day in [12, 15, 18]) {
        await g.moveTo(Offset(xOf(day), layout.axis.center.dy));
        await tester.pump();
        expect(add, findsOneWidget, reason: '$kind: + mid-drag day $day');
        expect(
          bubble().center.dx,
          closeTo(xOf(day), 1),
          reason: 'bubble (and its +) centred on the picked day',
        );
        expect(tester.getRect(add).right, lessThanOrEqualTo(bubble().right));
      }
      // Into the balance fill and far up: no Trim prompt, preview or
      // scissors, and no cancel state — the + stays.
      for (final dy in [30.0, 120.0, layout.axis.top - layout.plot.top - 4]) {
        await g.moveTo(Offset(xOf(18), layout.axis.top - dy));
        await tester.pump();
        expect(add, findsOneWidget, reason: '$kind: + ${dy}px up');
        expect(find.text('Release, then tap +'), findsOneWidget);
      }
      expect(find.text('Release to cancel'), findsNothing);
      for (final k in ['pick-trim', 'trim-preview', 'pick-trim-action']) {
        expect(find.byKey(ValueKey(k)), findsNothing);
      }
      expect(find.textContaining('Trim'), findsNothing);
      expect(find.textContaining('ends'), findsNothing);
      // Back down and release: pinned, nothing created or trimmed.
      await g.moveTo(Offset(xOf(18), layout.axis.center.dy));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(created, isEmpty, reason: 'release never acts');
      expect(trimmed, isEmpty, reason: 'a drag never trims');
      expect(add, findsOneWidget);
      expect(find.text('Tap + to add here'), findsOneWidget);
      expect(bubble().center.dx, closeTo(xOf(18), 1));
      await tester.tap(add, kind: kind);
      await tester.pump();
      expect(created, [_start.add(const Duration(days: 18))]);
      expect(trimmed, isEmpty);
      // A drag released far up the screen still pins its day (+ and
      // close), keeps tracking sideways up there, and creates nothing; close
      // dismisses it.
      final g2 = await tester.startGesture(
        Offset(xOf(5), layout.axis.center.dy),
        kind: kind,
      );
      await tester.pump();
      expect(add, findsOneWidget);
      await g2.moveTo(Offset(xOf(5), layout.plot.top + 4));
      await g2.moveTo(Offset(xOf(8), layout.plot.top + 4));
      await tester.pump();
      expect(add, findsOneWidget);
      expect(bubble().center.dx, closeTo(xOf(8), 1));
      await g2.up();
      await tester.pump();
      expect(add, findsOneWidget);
      expect(find.byKey(const ValueKey('pick-close')), findsOneWidget);
      expect(find.text('Tap + to add here'), findsOneWidget);
      expect(
        find.text(formatOccurrenceDate(_start.add(const Duration(days: 8)))),
        findsOneWidget,
      );
      expect(created, hasLength(1), reason: 'release never creates');
      await tester.tap(find.byKey(const ValueKey('pick-close')), kind: kind);
      await tester.pump();
      expect(find.byKey(const ValueKey('pick-bubble')), findsNothing);
      expect(created, hasLength(1));
      await tester.pump(const Duration(seconds: 1));
    }
  });
}
