import 'dart:ui';

import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
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
  accountId: 'a',
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
  group('pickZone', () {
    test('footer creates, fill trims, above the line discards', () {
      PickZone z(double y, {bool canTrim = true}) =>
          pickZone(y: y, axisTop: 400, lineY: 200, canTrim: canTrim);
      expect(z(410), PickZone.create);
      expect(z(390), PickZone.create, reason: 'finger slop above footer');
      expect(z(300), PickZone.trim);
      expect(z(200), PickZone.trim, reason: 'on the line counts as fill');
      expect(z(150), PickZone.discard);
    });
    test('no trim target: old behaviour (56px slack, then discard)', () {
      PickZone z(double y) =>
          pickZone(y: y, axisTop: 400, lineY: 200, canTrim: false);
      expect(z(360), PickZone.create);
      expect(z(300), PickZone.discard);
    });
  });

  group('chooseTrimTarget', () {
    final txs = {
      'once': _tx('once', mode: RecurrenceMode.once),
      'a': _tx('a'),
      'b': _tx('b'),
      'ended': _tx(
        'ended',
        end: EndMode.untilDate,
        endDate: _start.add(const Duration(days: 9)),
      ),
      'off': _tx('off', enabled: false),
    };
    final occ = [
      _occ('once', 20),
      _occ('a', 3),
      _occ('a', 17),
      _occ('a', 24),
      _occ('b', 12),
      _occ('ended', 14),
      _occ('off', 11),
    ];
    Offset dot(Occurrence o) =>
        Offset(o.date.difference(_start).inDays * 10.0, 100);

    test('nearest next occurrence of a trimmable series wins', () {
      final day = _start.add(const Duration(days: 10));
      final near12 = chooseTrimTarget(
        day: day,
        pointer: const Offset(115, 150),
        transactions: txs,
        occurrences: occ,
        dotOf: dot,
      )!;
      expect(near12.transaction.id, 'b');
      final near17 = chooseTrimTarget(
        day: day,
        pointer: const Offset(175, 150),
        transactions: txs,
        occurrences: occ,
        dotOf: dot,
      )!;
      expect(near17.transaction.id, 'a');
      expect(near17.removed.map((o) => o.date.day), [18, 25]);
    });

    test('nothing after the day, or only one-offs: no target', () {
      expect(
        chooseTrimTarget(
          day: _start.add(const Duration(days: 30)),
          pointer: Offset.zero,
          transactions: txs,
          occurrences: occ,
          dotOf: dot,
        ),
        isNull,
      );
    });

    test('canTrimOn: only earlier than an existing end, after the start', () {
      final day = _start.add(const Duration(days: 9));
      expect(
        canTrimOn(txs['ended']!, day),
        isFalse,
        reason: 'already ends then',
      );
      expect(
        canTrimOn(txs['ended']!, day.subtract(const Duration(days: 1))),
        isTrue,
      );
      expect(
        canTrimOn(
          _tx('late', start: _start.add(const Duration(days: 20))),
          day,
        ),
        isFalse,
      );
      expect(canTrimOn(txs['once']!, day), isFalse);
      expect(canTrimOn(txs['off']!, day), isFalse);
      expect(canTrimOn(_tx('c', end: EndMode.count, count: 9), day), isTrue);
    });
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

  test('trimmed preview removes later deltas cumulatively', () {
    final points = [
      for (var i = 0; i < 6; i++)
        BalancePoint(
          date: _start.add(Duration(days: i)),
          closingBalance: Decimal.fromInt(
            1000 - (i >= 2 ? 100 : 0) - (i >= 4 ? 100 : 0),
          ),
        ),
    ];
    final out = trimmedPoints(points, [_occ('a', 2), _occ('a', 4)]);
    expect(out.map((p) => p.closingBalance.toDouble()), everyElement(1000));
  });

  testWidgets(
    'drag from the footer into the fill offers Trim; release pins, scissors trims',
    (tester) async {
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
      final trims = <(String, DateTime, int)>[];
      final created = <DateTime>[];
      Widget chart({TrimOnDay? onTrim}) => MaterialApp(
        home: Scaffold(
          body: SizedBox.fromSize(
            size: size,
            child: BalanceChart(
              series: BalanceSeries(points: points, occurrences: occ),
              currency: 'AUD',
              seedDate: _start.subtract(const Duration(days: 5)),
              viewStart: _start,
              visibleDays: 30,
              transactions: {'rent': rent},
              transactionNames: const {'rent': 'Rent'},
              onViewportChanged: (_, _) {},
              onCreateOnDay: created.add,
              onTrimOnDay: onTrim,
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        chart(onTrim: (t, d, n) => trims.add((t.id, d, n))),
      );
      await tester.pump();
      final layout = ChartLayout.of(size, 30);
      final x = layout.plot.left + 10.5 / 30 * layout.plot.width;
      final g = await tester.startGesture(
        Offset(x, layout.axis.center.dy),
        kind: PointerDeviceKind.touch,
      );
      await g.moveTo(Offset(x, layout.axis.top - 60));
      await tester.pump();
      expect(find.byKey(const ValueKey('pick-trim')), findsOneWidget);
      expect(find.textContaining('Tx rent ends'), findsOneWidget);
      expect(find.byKey(const ValueKey('trim-preview')), findsOneWidget);
      // Above the line: discard.
      await g.moveTo(Offset(x, layout.plot.top + 2));
      await tester.pump();
      expect(find.byKey(const ValueKey('pick-trim')), findsNothing);
      expect(find.text('Release to cancel'), findsOneWidget);
      await g.moveTo(Offset(x, layout.axis.top - 60));
      await tester.pump();
      await g.up();
      await tester.pump();
      // Release only pins the line + bubble (preview kept); scissors acts.
      expect(trims, isEmpty, reason: 'release never trims by itself');
      expect(find.byKey(const ValueKey('pick-trim')), findsOneWidget);
      expect(find.byKey(const ValueKey('trim-preview')), findsOneWidget);
      expect(find.byKey(const ValueKey('pick-add')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pick-trim-action')));
      await tester.pump();
      expect(find.byKey(const ValueKey('pick-bubble')), findsNothing);
      expect(created, isEmpty, reason: 'a trim never creates');
      expect(trims, hasLength(1));
      expect(trims.single.$1, 'rent');
      expect(trims.single.$2, DateTime(2031, 3, 11));
      expect(trims.single.$3, greaterThan(0));

      // Viewers (no onTrimOnDay): the fill is a plain discard, never Trim.
      await tester.pumpWidget(chart());
      await tester.pump();
      final g2 = await tester.startGesture(
        Offset(x, layout.axis.center.dy),
        kind: PointerDeviceKind.touch,
      );
      await g2.moveTo(Offset(x, layout.axis.top - 120));
      await tester.pump();
      expect(find.byKey(const ValueKey('pick-trim')), findsNothing);
      await g2.up();
      await tester.pump();
      expect(trims, hasLength(1));
      expect(created, isEmpty);
    },
  );
}
