// Stacked lanes: the balance line drawn as one ribbon of a lane per
// transaction (list order), dots on the left edge of their day.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/stack_lanes.dart';
import 'package:budget_client/theme/app_theme.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chip_taps.dart';

final _start = DateTime(2031, 3, 1);

Transaction _t(
  String id,
  String name, {
  TransactionDirection direction = TransactionDirection.debit,
  RecurrenceMode mode = RecurrenceMode.every,
  EndMode endMode = EndMode.never,
  DateTime? start,
  DateTime? end,
  int? count,
  bool enabled = true,
}) => Transaction(
  id: id,
  poolId: 'a',
  name: name,
  direction: direction,
  amount: Decimal.fromInt(10),
  startDate: start ?? _start,
  recurrenceMode: mode,
  interval: 1,
  unit: RecurrenceUnit.weeks,
  endMode: endMode,
  endDate: end,
  occurrenceCount: count,
  enabled: enabled,
);

void main() {
  tearDown(() {
    debugLaneDot = null;
    debugRibbon = null;
    debugRiser = null;
  });

  group('lane set', () {
    test('lanes follow the list order, then the rest in loaded order', () {
      final lanes = buildLaneSet(
        order: ['c', 'a'],
        transactions: {'a': _t('a', 'A'), 'b': _t('b', 'B'), 'c': _t('c', 'C')},
      );
      expect([for (final l in lanes.lanes) l.id], ['c', 'a', 'b']);
      expect(lanes.indexOf('a'), 1);
    });

    test('combined: the viewed pool first, then the other pools in order', () {
      final lanes = buildLaneSet(
        order: ['b', 'a'],
        transactions: {'a': _t('a', 'A'), 'b': _t('b', 'B')},
        others: {'x': _t('x', 'X'), 'y': _t('y', 'Y'), 'z': _t('z', 'Z')},
        otherOrder: ['y', 'z', 'x'],
      );
      expect([for (final l in lanes.lanes) l.id], ['b', 'a', 'y', 'z', 'x']);
    });

    test('a lane lives from the first to the last occurrence; excluded '
        'transactions have none', () {
      final lanes = buildLaneSet(
        order: const [],
        transactions: {
          'open': _t('open', 'Open'),
          'once': _t('once', 'Once', mode: RecurrenceMode.once),
          'until': _t(
            'until',
            'Until',
            endMode: EndMode.untilDate,
            end: DateTime(2031, 3, 20),
          ),
          'count': _t('count', 'Count', endMode: EndMode.count, count: 3),
          'off': _t('off', 'Off', enabled: false),
        },
      );
      expect(lanes.indexOf('off'), isNull);
      final open = lanes.lanes[lanes.indexOf('open')!];
      expect(open.end, isNull);
      expect(open.activeOn(DateTime(2040)), isTrue);
      final once = lanes.lanes[lanes.indexOf('once')!];
      expect(once.activeOn(_start), isTrue);
      expect(once.activeOn(DateTime(2031, 3, 2)), isFalse);
      final until = lanes.lanes[lanes.indexOf('until')!];
      expect(until.activeOn(DateTime(2031, 3, 20)), isTrue);
      expect(until.activeOn(DateTime(2031, 3, 21)), isFalse);
      final count = lanes.lanes[lanes.indexOf('count')!];
      // Weekly: 1st, 8th, 15th March.
      expect(count.activeOn(DateTime(2031, 3, 15)), isTrue);
      expect(count.activeOn(DateTime(2031, 3, 16)), isFalse);
    });

    test('the stack is compacted: only active lanes take a slot', () {
      final lanes = buildLaneSet(
        order: ['a', 'b', 'c'],
        transactions: {
          'a': _t('a', 'A'),
          'b': _t('b', 'B', mode: RecurrenceMode.once),
          'c': _t('c', 'C'),
        },
      );
      expect(lanes.slotOn('c', _start), (2, 3));
      expect(lanes.slotOn('c', DateTime(2031, 3, 5)), (1, 2));
      expect(lanes.slotOn('b', DateTime(2031, 3, 5)), isNull);
      expect(lanes.maxActive, 3);
    });

    test('thickness: text-sized while it fits, thinner for a heavy pool, '
        'never below the minimum', () {
      expect(laneThickness(maxActive: 4, plotHeight: 500, phone: false), 16);
      expect(laneThickness(maxActive: 4, plotHeight: 500, phone: true), 14);
      final heavy = laneThickness(maxActive: 60, plotHeight: 500, phone: false);
      expect(heavy, lessThan(laneTextMinHeight));
      expect(heavy, greaterThanOrEqualTo(minLaneHeight));
      expect(
        laneThickness(maxActive: 5000, plotHeight: 300, phone: false),
        minLaneHeight,
      );
    });
  });

  group('ribbon geometry', () {
    test('the stack is centred on the balance, in list order, no gaps', () {
      const h = 14.0;
      final tops = [for (var k = 0; k < 3; k++) laneTop(200, k, 3, h)];
      expect(tops, [200 - 21, 200 - 7, 200 + 7]);
      expect(tops[1] + h, tops[2]);
      // A higher balance (smaller y) lifts the whole stack together.
      expect(laneTop(100, 0, 3, h), tops[0] - 100);
    });

    test('plateaus split at balance steps and lane starts / ends', () {
      final lanes = buildLaneSet(
        order: ['a', 'b'],
        transactions: {
          'a': _t('a', 'A'),
          'b': _t(
            'b',
            'B',
            start: DateTime(2031, 3, 3),
            endMode: EndMode.untilDate,
            end: DateTime(2031, 3, 4),
          ),
        },
      );
      final plateaus = stackPlateaus(
        lanes: lanes,
        samples: [
          BalancePoint(date: _start, closingBalance: Decimal.fromInt(100)),
          BalancePoint(
            date: DateTime(2031, 3, 3),
            closingBalance: Decimal.fromInt(80),
          ),
        ],
        drawStart: _start,
        drawEnd: DateTime(2031, 3, 8),
        xOf: (d) => d.difference(_start).inDays * 10.0,
        minX: 0,
        maxX: 1000,
      );
      expect([for (final p in plateaus) p.x0], [0, 20, 40]);
      expect([for (final p in plateaus) p.balance], [100, 80, 80]);
      expect(
        [for (final p in plateaus) p.active],
        [
          [0],
          [0, 1],
          [0],
        ],
      );
    });
  });

  group('chart', () {
    final names = {'a': 'Rent', 'b': 'Salary', 'c': 'Gym'};

    Future<Map<String?, List<Offset>>> pump(
      WidgetTester tester,
      List<String> order, {
      Size size = const Size(1440, 800),
      double visibleDays = 30,
      List<int> balances = const [1000, 1500],
      DateTime? seedDate,
      double? seedBalance,
      List<int> dayOffsets = const [0, 7],
      Map<int, List<String>>? occurs,
      void Function(DateTime)? onCreate,
      bool actions = false,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final dots = <String?, List<Offset>>{};
      debugLaneDot = (id, c) => (dots[id] ??= []).add(c);
      final days = [
        for (final o in occurs?.keys ?? dayOffsets)
          _start.add(Duration(days: o)),
      ];
      final points = <BalancePoint>[];
      var bal = balances[0];
      for (var i = 0; i < 60; i++) {
        final d = _start.add(Duration(days: i));
        if (i == 7) bal = balances[1];
        points.add(BalancePoint(date: d, closingBalance: Decimal.fromInt(bal)));
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox.fromSize(
              size: size,
              child: BalanceChart(
                series: BalanceSeries(
                  points: points,
                  occurrences: [
                    for (final d in days)
                      for (final id
                          in occurs?[d.difference(_start).inDays] ??
                              ['a', 'b', 'c'])
                        Occurrence(
                          transactionId: id,
                          date: d,
                          signedDelta: Decimal.fromInt(id == 'b' ? 100 : -10),
                        ),
                  ],
                ),
                seedDate: seedDate ?? _start.subtract(const Duration(days: 30)),
                seedBalance: seedBalance,
                viewStart: _start.subtract(const Duration(days: 2)),
                visibleDays: visibleDays,
                transactionNames: names,
                laneOrder: order,
                transactions: {
                  'a': _t('a', 'Rent'),
                  'b': _t(
                    'b',
                    'Salary',
                    direction: TransactionDirection.credit,
                  ),
                  'c': _t('c', 'Gym'),
                },
                onViewportChanged: (_, _) {},
                onCreateOnDay: onCreate ?? (_) {},
                onNewOnDay: actions ? (_) {} : null,
                onEditTransaction: actions ? (_, _) {} : null,
                onTrimOccurrence: actions ? (_, _) {} : null,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return dots;
    }

    testWidgets('dots stack in list order, centred in their lanes', (
      tester,
    ) async {
      var dots = await pump(tester, ['c', 'a', 'b']);
      double y(String id) => dots[id]!.first.dy;
      expect(y('c'), lessThan(y('a')));
      expect(y('a'), lessThan(y('b')));
      // Lanes are flush: neighbours are one lane thickness apart.
      final layout = ChartLayout.of(const Size(1440, 800), 30);
      final h = laneThickness(
        maxActive: 3,
        plotHeight: layout.plot.height,
        phone: false,
      );
      expect(y('a') - y('c'), closeTo(h, 0.01));
      expect(y('b') - y('a'), closeTo(h, 0.01));
      // Reordering the list reorders the lanes.
      dots = await pump(tester, ['b', 'c', 'a']);
      expect(dots['b']!.first.dy, lessThan(dots['c']!.first.dy));
      expect(dots['c']!.first.dy, lessThan(dots['a']!.first.dy));
    });

    testWidgets('dots sit on the left edge of their day, not its centre', (
      tester,
    ) async {
      final dots = await pump(tester, ['a', 'b', 'c']);
      final layout = ChartLayout.of(const Size(1440, 800), 30);
      final start = _start.subtract(const Duration(days: 2));
      final left = layout.xOf(_start, start, 30);
      final dayPx = layout.plot.width / 30;
      for (final id in ['a', 'b', 'c']) {
        expect(dots[id]!.first.dx, closeTo(left, 0.01), reason: id);
        expect(dots[id]!.first.dx, lessThan(left + dayPx / 2));
      }
    });

    testWidgets('the auto-fit leaves room for half the stack above and '
        'below the line', (tester) async {
      await pump(tester, ['a', 'b', 'c'], balances: [1000, 1500]);
      final range =
          (tester.state(find.byType(BalanceChart)) as dynamic).debugYRange
              as BalanceExtents;
      final layout = ChartLayout.of(const Size(1440, 800), 30);
      final h = laneThickness(
        maxActive: 3,
        plotHeight: layout.plot.height,
        phone: false,
      );
      final span = range.max - range.min;
      double px(double v) => (range.max - v) / span * layout.plot.height;
      expect(px(1500), greaterThanOrEqualTo(h * 3 / 2));
      expect(layout.plot.height - px(0), greaterThanOrEqualTo(h * 3 / 2));
    });

    testWidgets('the ribbon is centred on the balance\'s own y, at every '
        'day, zoomed in or out', (tester) async {
      for (final days in [30.0, 9.0, 60.0]) {
        final seen = <DateTime, (Rect, double)>{};
        debugRibbon = (d, r, y) => seen[d] = (r, y);
        await pump(tester, ['a', 'b', 'c'], visibleDays: days);
        final range =
            (tester.state(find.byType(BalanceChart)) as dynamic).debugYRange
                as BalanceExtents;
        final layout = ChartLayout.of(const Size(1440, 800), days);
        double yOf(double v) =>
            layout.plot.bottom -
            (v - range.min) / (range.max - range.min) * layout.plot.height;
        expect(seen, isNotEmpty);
        for (final e in seen.entries) {
          final (rect, y) = e.value;
          final balance = e.key.isBefore(_start.add(const Duration(days: 7)))
              ? 1000.0
              : 1500.0;
          expect(rect.center.dy, closeTo(y, 0.01), reason: '${e.key}');
          expect(rect.center.dy, closeTo(yOf(balance), 0.01), reason: '$days');
        }
      }
    });

    testWidgets('the line starts at the opening: a riser joins the seed '
        'diamond to the seed day\'s ribbon', (tester) async {
      final risers = <Rect>[];
      debugRiser = risers.add;
      final seen = <DateTime, Rect>{};
      debugRibbon = (d, r, _) => seen[d] = r;
      await pump(tester, ['a', 'b', 'c'], seedDate: _start, seedBalance: 400);
      expect(risers, hasLength(1));
      final range =
          (tester.state(find.byType(BalanceChart)) as dynamic).debugYRange
              as BalanceExtents;
      final layout = ChartLayout.of(const Size(1440, 800), 30);
      double yOf(double v) =>
          layout.plot.bottom -
          (v - range.min) / (range.max - range.min) * layout.plot.height;
      final r = risers.single;
      expect(r.bottom - 1.2, closeTo(yOf(400), 0.01));
      expect(r.top + 1.2, closeTo(yOf(1000), 0.01));
      expect(r.center.dx, closeTo(seen[_start]!.left, 0.01));
    });

    testWidgets('the stack rises and falls with the balance', (tester) async {
      var dots = await pump(tester, ['a', 'b', 'c']);
      // Day 1 (balance 1000) and day 8 (1500): same lanes, one stack.
      final ys = dots['a']!;
      expect(ys.length, 2);
      final later = ys.last.dy, first = ys.first.dy;
      expect(later, lessThan(first), reason: 'a higher balance draws higher');
      final shift = first - later;
      // The whole stack moves by the same amount: lanes stay glued.
      expect(dots['b']!.first.dy - dots['b']!.last.dy, closeTo(shift, 0.01));
      expect(dots['c']!.first.dy - dots['c']!.last.dy, closeTo(shift, 0.01));
    });

    testWidgets('a lane dot inspects only its own transaction', (tester) async {
      final dots = await pump(tester, ['a', 'b', 'c']);
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      final tip = find.byKey(const ValueKey('occurrence-tooltip'));
      for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
        for (final id in ['a', 'b', 'c']) {
          await tester.tapAt(origin + dots[id]!.first, kind: kind);
          await tester.pump();
          expect(tip, findsOneWidget, reason: 'lane $id');
          for (final e in names.entries) {
            expect(
              find.descendant(of: tip, matching: find.text(e.value)),
              e.key == id ? findsWidgets : findsNothing,
              reason: '${e.value} (tapped $id, $kind)',
            );
          }
          // One transaction has no day net, only the balance after.
          expect(find.byKey(const ValueKey('day-net')), findsNothing);
          await tester.tapAt(
            origin + const Offset(700, 780),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump(const Duration(seconds: 6));
        }
      }
    });

    testWidgets('every transaction gets its own dot at every step, in its '
        'own lane', (tester) async {
      final dots = await pump(tester, ['a', 'b', 'c']);
      final layout = ChartLayout.of(const Size(1440, 800), 30);
      final h = laneThickness(
        maxActive: 3,
        plotHeight: layout.plot.height,
        phone: false,
      );
      // Two steps (day 0 and day 7) x three transactions: no grouping.
      for (final id in ['a', 'b', 'c']) {
        expect(dots[id], hasLength(2), reason: id);
      }
      expect(dots[null], isNull, reason: 'no shared orphan dot');
      for (var step = 0; step < 2; step++) {
        final ys = [
          for (final id in ['a', 'b', 'c']) dots[id]![step].dy,
        ];
        expect(ys[1] - ys[0], closeTo(h, 0.01));
        expect(ys[2] - ys[1], closeTo(h, 0.01));
      }
    });

    /// Every dot the chart draws, by step (x) then lane (y): the lane's
    /// transaction and whether it occurs on that step.
    Future<Map<double, List<({String? id, Offset c, bool idle})>>> allDots(
      WidgetTester tester,
      List<String> order, {
      required Map<int, List<String>> occurs,
      Size size = const Size(1440, 800),
      void Function(DateTime)? onCreate,
      bool actions = false,
    }) async {
      final all = <({String? id, Offset c, bool idle})>[];
      await pump(
        tester,
        order,
        size: size,
        occurs: occurs,
        onCreate: onCreate,
        actions: actions,
      );
      // Repaint with both hooks collecting.
      debugLaneIdleDot = (id, c) => all.add((id: id, c: c, idle: true));
      debugLaneDot = (id, c) => all.add((id: id, c: c, idle: false));
      addTearDown(() => debugLaneIdleDot = null);
      for (final e
          in find
              .descendant(
                of: find.byType(BalanceChart),
                matching: find.byType(CustomPaint),
              )
              .evaluate()) {
        (e.renderObject as RenderCustomPaint).markNeedsPaint();
      }
      await tester.pump();
      final byStep = <double, List<({String? id, Offset c, bool idle})>>{};
      for (final d in all) {
        (byStep[d.c.dx.roundToDouble()] ??= []).add(d);
      }
      for (final l in byStep.values) {
        l.sort((a, b) => a.c.dy.compareTo(b.c.dy));
      }
      return byStep;
    }

    testWidgets('every active lane has a dot at every step, whether or not '
        'its transaction occurs on it', (tester) async {
      // Weekly Rent, monthly Salary, a third on its own days: the ribbon
      // steps on day 0, 3 and 7.
      final steps = await allDots(
        tester,
        ['a', 'b', 'c'],
        occurs: {
          0: ['b', 'a'],
          3: ['c'],
          7: ['a', 'c'],
        },
      );
      expect(steps, hasLength(3));
      final xs = steps.keys.toList()..sort();
      final occurring = [
        ['a', 'b'],
        ['c'],
        ['a', 'c'],
      ];
      final layout = ChartLayout.of(const Size(1440, 800), 30);
      final h = laneThickness(
        maxActive: 3,
        plotHeight: layout.plot.height,
        phone: false,
      );
      for (final (i, x) in xs.indexed) {
        final col = steps[x]!;
        // One dot per lane, in list order, a lane thick apart.
        expect([for (final d in col) d.id], ['a', 'b', 'c'], reason: 'step $i');
        expect(col[1].c.dy - col[0].c.dy, closeTo(h, 0.01));
        expect(col[2].c.dy - col[1].c.dy, closeTo(h, 0.01));
        for (final d in col) {
          expect(
            d.idle,
            !occurring[i].contains(d.id),
            reason: 'step $i lane ${d.id}',
          );
        }
      }
    });

    testWidgets('a lane that starts or ends at a step has a dot there, and '
        'none past its end', (tester) async {
      // Gym (c) ends on day 3; Salary (b) starts on day 3.
      tester.view.physicalSize = const Size(1440, 800);
      final lanes = buildLaneSet(
        order: ['a', 'b', 'c'],
        transactions: {
          'a': _t('a', 'Rent'),
          'b': _t('b', 'Salary', start: _start.add(const Duration(days: 3))),
          'c': _t(
            'c',
            'Gym',
            endMode: EndMode.untilDate,
            end: _start.add(const Duration(days: 3)),
          ),
        },
      );
      List<(String?, bool)> at(int day, List<String> occurs) {
        final d = _start.add(Duration(days: day));
        final r = laneDotsForDay(
          lanes: lanes,
          group: DayGroup(d, [
            for (final id in occurs)
              Occurrence(
                transactionId: id,
                date: d,
                signedDelta: Decimal.fromInt(-10),
              ),
          ]),
          balanceY: 100,
          thickness: 10,
        );
        return [for (final x in r.dots) (x.txId, x.idle)];
      }

      expect(at(0, ['a']), [('a', false), ('c', true)]);
      expect(at(3, ['b', 'c']), [('a', true), ('b', false), ('c', false)]);
      expect(at(7, ['a', 'b']), [('a', false), ('b', false)]);
    });

    testWidgets('a dot for a transaction that does not occur inspects only '
        'that transaction, and never creates or edits', (tester) async {
      final created = <DateTime>[];
      final steps = await allDots(
        tester,
        ['a', 'b', 'c'],
        occurs: {
          0: ['a', 'b'],
          7: ['c'],
        },
        onCreate: created.add,
        actions: true,
      );
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      final xs = steps.keys.toList()..sort();
      final tip = find.byKey(const ValueKey('occurrence-tooltip'));
      for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
        // Rent (a) is idle on the second step; Gym (c) is idle on the first.
        for (final (x, id) in [(xs[1], 'a'), (xs[0], 'c'), (xs[1], 'b')]) {
          final dot = steps[x]!.firstWhere((d) => d.id == id);
          expect(dot.idle, isTrue);
          await tester.tapAt(origin + dot.c, kind: kind);
          await tester.pump();
          expect(tip, findsOneWidget, reason: '$id idle dot ($kind)');
          for (final e in names.entries) {
            expect(
              find.descendant(of: tip, matching: find.text(e.value)),
              e.key == id ? findsWidgets : findsNothing,
              reason: '${e.value} (tapped idle $id, $kind)',
            );
          }
          expect(
            find.descendant(
              of: tip,
              matching: find.textContaining(
                'Ring dot: not occurring on this day',
                findRichText: true,
              ),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: tip,
              matching: find.textContaining('Prev ', findRichText: true),
            ),
            findsOneWidget,
          );
          expect(find.byKey(const ValueKey('day-net')), findsNothing);
          expect(find.byKey(ValueKey('tip-menu-$id')), findsOneWidget);
          await tester.tapAt(
            origin + const Offset(700, 780),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump(const Duration(seconds: 6));
        }
      }
      // Taps only inspect.
      expect(created, isEmpty);
    });

    testWidgets('each net amount is drawn once per step, never per lane', (
      tester,
    ) async {
      final labels = <String>[];
      final prev = debugVertexLabelLines;
      debugVertexLabelLines = (rect, lines) => labels.add(lines.first);
      addTearDown(() => debugVertexLabelLines = prev);
      await pump(tester, ['a', 'b', 'c']);
      final chips = await chartChips(tester);
      // Two steps; each lists the day's net (+100 −10 −10 = +80) once.
      expect(chips, hasLength(2));
      final nets = labels.where((l) => l.contains('80')).toList();
      expect(nets.length, greaterThanOrEqualTo(2));
      expect(nets.every((l) => l.startsWith('+')), isTrue, reason: '$nets');
      expect(labels.where((l) => l.contains('100')), isEmpty);
    });

    testWidgets('lane labels name the transaction then its amount, green '
        'for a gain and red for a loss', (tester) async {
      final seen = <String, (String, Color)>{};
      debugLaneAmount = (name, amount, color, pill) =>
          seen[name] = (amount, color);
      addTearDown(() => debugLaneAmount = null);
      await pump(tester, ['a', 'b', 'c']);
      expect(seen.keys, containsAll(['Rent', 'Salary', 'Gym']));
      expect(seen['Salary']!.$1, startsWith('+'));
      expect(seen['Salary']!.$2, AppTheme.creditColor);
      for (final n in ['Rent', 'Gym']) {
        expect(seen[n]!.$1, anyOf(startsWith('-'), startsWith('\u2212')));
        expect(seen[n]!.$2, AppTheme.debitColor, reason: n);
      }
    });

    testWidgets('a crowded phone view still gives every step its net chip', (
      tester,
    ) async {
      final offsets = [for (var i = 0; i < 12; i++) i];
      await pump(
        tester,
        ['a', 'b', 'c'],
        size: const Size(390, 844),
        dayOffsets: offsets,
      );
      final chips = await chartChips(tester);
      expect(chips, hasLength(offsets.length));
      // Chips never pile on each other, whatever row they were pushed to.
      for (var i = 0; i < chips.length; i++) {
        for (var j = i + 1; j < chips.length; j++) {
          expect(chips[i].overlaps(chips[j]), isFalse, reason: '$i vs $j');
        }
      }
    });

    testWidgets('a phone-width lane still draws its signed amount pill'
        '', (tester) async {
      final seen = <String, String>{};
      debugLaneAmount = (name, amount, color, pill) => seen[name] = amount;
      addTearDown(() => debugLaneAmount = null);
      await pump(tester, ['a', 'b', 'c'], size: const Size(390, 844));
      for (final a in seen.values) {
        expect(a, isNotEmpty);
      }
      // A net chip near the right edge slides in rather than being cut off.
      final width = tester.getSize(find.byType(BalanceChart)).width;
      for (final r in await chartChips(tester)) {
        expect(r.right, lessThanOrEqualTo(width));
      }
    });

    testWidgets('a touch near a thin lane still picks the nearest dot', (
      tester,
    ) async {
      final dots = await pump(tester, [
        'a',
        'b',
        'c',
      ], size: const Size(390, 844));
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      final tip = find.byKey(const ValueKey('occurrence-tooltip'));
      // 20px right of the lane dot: inside the 44px touch radius.
      await tester.tapAt(
        origin + dots['b']!.first + const Offset(20, 0),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      expect(tip, findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('a heavy pool: thin lanes, no names, dots still tappable', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1440, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final dots = <String?, List<Offset>>{};
      debugLaneDot = (id, c) => (dots[id] ??= []).add(c);
      final ids = [for (var i = 0; i < 60; i++) 't$i'];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox.fromSize(
              size: const Size(1440, 800),
              child: BalanceChart(
                series: BalanceSeries(
                  points: [
                    for (var i = 0; i < 60; i++)
                      BalancePoint(
                        date: _start.add(Duration(days: i)),
                        closingBalance: Decimal.fromInt(1000 - i * 5),
                      ),
                  ],
                  occurrences: [
                    for (final id in ids)
                      Occurrence(
                        transactionId: id,
                        date: _start,
                        signedDelta: Decimal.fromInt(-5),
                      ),
                  ],
                ),
                seedDate: _start.subtract(const Duration(days: 30)),
                viewStart: _start,
                visibleDays: 30,
                transactionNames: {for (final id in ids) id: id},
                laneOrder: ids,
                transactions: {for (final id in ids) id: _t(id, 'Item $id')},
                onViewportChanged: (_, _) {},
                onCreateOnDay: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(dots.length, 60);
      final h = dots['t1']!.first.dy - dots['t0']!.first.dy;
      expect(h, inInclusiveRange(minLaneHeight, laneTextMinHeight));
      expect(tester.takeException(), isNull);
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      await tester.tapAt(
        origin + dots['t30']!.first,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('occurrence-tooltip')), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });
  });
}
