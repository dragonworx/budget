// Stacked lanes: the balance line drawn as one ribbon of a lane per
// event (list order), dots on the left edge of their day.
import 'dart:math' as math;

import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/alert_fill.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/stack_lanes.dart';
import 'package:budget_client/theme/app_theme.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chip_taps.dart';

final _start = DateTime(2031, 3, 1);

BudgetEvent _t(
  String id,
  String name, {
  EventDirection direction = EventDirection.debit,
  RecurrenceMode mode = RecurrenceMode.every,
  EndMode endMode = EndMode.never,
  DateTime? start,
  DateTime? end,
  int? count,
  bool enabled = true,
}) => BudgetEvent(
  id: id,
  streamId: 'a',
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

RecurrenceMode _mode(Set<String> once, String id) =>
    once.contains(id) ? RecurrenceMode.once : RecurrenceMode.every;

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Every menu item's label, top to bottom (the divider has none).
List<String> _menuLabels(WidgetTester tester) {
  // The action rows (the name / amount header row is not one).
  final items = find.byWidgetPredicate(
    (w) => w is PopupMenuItem && w.key != const ValueKey('dot-menu-header'),
  );
  final rows = items.evaluate().toList()
    ..sort(
      (x, y) => tester
          .getCenter(find.byWidget(x.widget))
          .dy
          .compareTo(tester.getCenter(find.byWidget(y.widget)).dy),
    );
  return [
    for (final e in rows)
      tester
          .widget<Text>(
            find.descendant(
              of: find.byWidget(e.widget),
              matching: find.byType(Text),
            ),
          )
          .data!,
  ];
}

bool _enabled(WidgetTester tester, String key) =>
    tester.widget<PopupMenuItem<int>>(find.byKey(ValueKey(key))).enabled;

void main() {
  tearDown(() {
    debugLaneDot = null;
    debugLaneDotPainted = null;
    debugRibbon = null;
    debugRiser = null;
    debugTrueLine = null;
    debugLaneName = null;
    debugLaneAmount = null;
  });

  group('lane set', () {
    test('lanes follow the list order, then the rest in loaded order', () {
      final lanes = buildLaneSet(
        order: ['c', 'a'],
        events: {'a': _t('a', 'A'), 'b': _t('b', 'B'), 'c': _t('c', 'C')},
      );
      expect([for (final l in lanes.lanes) l.id], ['c', 'a', 'b']);
      expect(lanes.indexOf('a'), 1);
    });

    test(
      'combined: the viewed stream first, then the other streams in order',
      () {
        final lanes = buildLaneSet(
          order: ['b', 'a'],
          events: {'a': _t('a', 'A'), 'b': _t('b', 'B')},
          others: {'x': _t('x', 'X'), 'y': _t('y', 'Y'), 'z': _t('z', 'Z')},
          otherOrder: ['y', 'z', 'x'],
        );
        expect([for (final l in lanes.lanes) l.id], ['b', 'a', 'y', 'z', 'x']);
      },
    );

    test('a lane lives from the first to the last occurrence; excluded '
        'events have none', () {
      final lanes = buildLaneSet(
        order: const [],
        events: {
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
        events: {
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

    test('thickness: text-sized while it fits, thinner for a heavy stream, '
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

    test('thickness keeps the stack near its dollars: full lanes up to a '
        'quarter of the plot, text-height lanes up to a third, then thin', () {
      double stack(int n, double plot, bool phone) =>
          n * laneThickness(maxActive: n, plotHeight: plot, phone: phone);
      // A few lanes: full size, as before.
      expect(laneThickness(maxActive: 3, plotHeight: 500, phone: false), 16);
      expect(laneThickness(maxActive: 3, plotHeight: 450, phone: true), 14);
      // 8: still labelled, but the stack is at most a quarter of the plot.
      for (final (plot, phone) in [(500.0, false), (450.0, true)]) {
        final h = laneThickness(maxActive: 8, plotHeight: plot, phone: phone);
        expect(h, greaterThanOrEqualTo(laneTextMinHeight));
        expect(stack(8, plot, phone), lessThanOrEqualTo(plot * 0.25 + 0.01));
      }
      // 12 on desktop: text-height lanes, within a third.
      expect(
        laneThickness(maxActive: 12, plotHeight: 500, phone: false),
        laneTextMinHeight,
      );
      expect(stack(12, 500, false), lessThanOrEqualTo(500 * 0.32));
      // 20+: thin lanes, the stack back to a quarter (a fifth on phones).
      for (final n in [20, 24, 40]) {
        expect(stack(n, 500, false), lessThanOrEqualTo(500 * 0.25 + 0.01));
        if (n < 40) {
          expect(stack(n, 450, true), lessThanOrEqualTo(450 * 0.22 + 0.01));
        }
        expect(
          laneThickness(maxActive: n, plotHeight: 500, phone: false),
          lessThan(laneTextMinHeight),
        );
      }
    });
  });

  group('ribbon geometry', () {
    test('the stack hangs just under the balance, in list order, no '
        'gaps', () {
      const h = 14.0;
      final tops = [for (var k = 0; k < 3; k++) laneTop(200, k, 3, h)];
      expect(tops, [200 + laneGap, 200 + laneGap + 14, 200 + laneGap + 28]);
      // Every lane is under the line: the first starts just below it.
      expect(tops.first, greaterThan(200));
      expect(stackBottomOf(200, 3, h), 200 + laneGap + 42);
      expect(tops[1] + h, tops[2]);
      // A higher balance (smaller y) lifts the whole stack together.
      expect(laneTop(100, 0, 3, h), tops[0] - 100);
    });

    test('plateaus split at balance steps and lane starts / ends', () {
      final lanes = buildLaneSet(
        order: ['a', 'b'],
        events: {
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
      Set<String>? only,
      List<String>? log,
      Set<String> once = const {},
      bool canEdit = true,
      double lossThreshold = 0,
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
                          eventId: id,
                          date: d,
                          signedDelta: Decimal.fromInt(id == 'b' ? 100 : -10),
                        ),
                  ],
                ),
                seedDate: seedDate ?? _start.subtract(const Duration(days: 30)),
                seedBalance: seedBalance,
                viewStart: _start.subtract(const Duration(days: 2)),
                visibleDays: visibleDays,
                eventNames: names,
                laneOrder: order,
                events: {
                  for (final e in {
                    'a': _t('a', 'Rent', mode: _mode(once, 'a')),
                    'b': _t(
                      'b',
                      'Salary',
                      direction: EventDirection.credit,
                      mode: _mode(once, 'b'),
                    ),
                    'c': _t('c', 'Gym', mode: _mode(once, 'c')),
                  }.entries)
                    if (only == null || only.contains(e.key)) e.key: e.value,
                },
                lossThreshold: lossThreshold,
                onViewportChanged: (_, _) {},
                onCreateOnDay: onCreate ?? (_) {},
                onNewOnDay: log != null && canEdit
                    ? (d) => log.add('new ${_ymd(d)}')
                    : actions
                    ? (_) {}
                    : null,
                onEditEvent: log != null && canEdit
                    ? (t, d) => log.add('edit ${t.id} ${_ymd(d)}')
                    : actions
                    ? (_, _) {}
                    : null,
                onTrimOccurrence: log != null && canEdit
                    ? (t, d) => log.add('trim ${t.id} ${_ymd(d)}')
                    : actions
                    ? (_, _) {}
                    : null,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return dots;
    }

    testWidgets('the fill turns red under the alert line, split at the step', (
      tester,
    ) async {
      AlertFill? fill;
      double? alertY;
      debugAlertFill = (f, y) {
        fill = f;
        alertY = y;
      };
      addTearDown(() => debugAlertFill = null);
      // 1000 for the first week, then 1500: an alert at 1200 is crossed
      // once, going up, on day 7's step.
      final dots = await pump(tester, ['a', 'b', 'c'], lossThreshold: 1200);
      final f = fill!;
      expect(f.crossings, hasLength(1));
      final cross = f.crossings.single;
      expect(cross.dy, alertY);
      expect(cross.dx, closeTo(dots['a']![1].dx, 12));
      expect(f.deficit, isNotEmpty);
      for (final r in f.deficit) {
        expect(r.top, closeTo(alertY!, 0.01));
        expect(r.right, lessThanOrEqualTo(cross.dx + 0.01));
      }
      for (final r in f.safe) {
        expect(r.left, greaterThanOrEqualTo(cross.dx - 0.01));
      }
      expect(AlertFill.area(f.safe), greaterThan(0));

      // Above the alert everywhere: no red at all.
      await pump(tester, ['a', 'b', 'c'], lossThreshold: 900);
      expect(fill!.deficit, isEmpty);
      expect(fill!.under, isEmpty);
      expect(fill!.crossings, isEmpty);

      // Below it everywhere: no green.
      await pump(tester, ['a', 'b', 'c'], lossThreshold: 1600);
      expect(fill!.safe, isEmpty);
      expect(AlertFill.area(fill!.deficit), greaterThan(0));
    });

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

    testWidgets('lane dots are hidden until the pointer is on their lane', (
      tester,
    ) async {
      final painted = <String?>[];
      debugLaneDotPainted = (id, _, _) => painted.add(id);
      final dots = await pump(tester, ['a', 'b', 'c']);
      expect(dots.keys, containsAll(['a', 'b', 'c']), reason: 'placed');
      expect(painted, isEmpty, reason: 'none drawn initially');
      expect(find.byKey(const ValueKey('occurrence-tooltip')), findsNothing);
    });

    /// Each lane's dot centres, by step (left to right), from the first
    /// paint.
    Map<String, List<Offset>> steps(Map<String?, List<Offset>> dots) => {
      for (final id in ['a', 'b', 'c'])
        id: (dots[id]!.take(2).toList()..sort((x, y) => x.dx.compareTo(y.dx))),
    };

    final day0 = _ymd(_start), day7 = _ymd(_start.add(const Duration(days: 7)));

    testWidgets('hovering anywhere on a lane shows only its dot, with no '
        'popup; clicking the dot opens its action menu', (tester) async {
      final painted = <(String?, Offset)>[];
      debugLaneDotPainted = (id, c, _) => painted.add((id, c));
      final log = <String>[];
      final at = steps(await pump(tester, ['a', 'b', 'c'], log: log));
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      final layout = ChartLayout.of(const Size(1440, 800), 30);
      final dayPx = layout.plot.width / 30;
      final tip = find.byKey(const ValueKey('occurrence-tooltip'));
      final menu = find.byWidgetPredicate((w) => w is PopupMenuItem);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: origin + const Offset(1300, 760));
      addTearDown(mouse.removePointer);
      await tester.pump();
      for (final id in ['a', 'b', 'c']) {
        // Mid-step, well right of the (hidden) dot: still its lane.
        final dot = at[id]![1];
        painted.clear();
        await mouse.moveTo(origin + dot + Offset(dayPx * 3.4, 1));
        await tester.pump();
        expect(tip, findsNothing, reason: 'no hover popup ($id)');
        expect(menu, findsNothing);
        // Only the hovered lane's dot, at its step's left edge.
        expect(painted, isNotEmpty);
        expect(painted.map((p) => p.$1).toSet(), {id});
        expect(painted.last.$2.dx, closeTo(dot.dx, 0.01));
        expect(painted.last.$2.dy, closeTo(dot.dy, 0.01));
      }
      // Onto the revealed dot (a few px off centre: a 32px target), click.
      final dot = at['a']![1];
      Future<void> clickDot() async {
        await mouse.moveTo(origin + dot + Offset(dayPx * 2, 1));
        await tester.pump();
        await mouse.moveTo(origin + dot + const Offset(10, 6));
        await tester.pump();
        await mouse.down(origin + dot + const Offset(10, 6));
        await mouse.up();
        await tester.pumpAndSettle();
      }

      await clickDot();
      painted.clear();
      tester
          .renderObjectList<RenderCustomPaint>(
            find.descendant(
              of: find.byType(BalanceChart),
              matching: find.byType(CustomPaint),
            ),
          )
          .forEach((r) => r.markNeedsPaint());
      await tester.pump();
      expect(painted.map((p) => p.$1).toSet(), {
        'a',
      }, reason: 'the dot stays shown under its menu');
      expect(tip, findsNothing);
      expect(_menuLabels(tester), [
        'New Event From Here',
        'Trim From Here',
        'Edit Series',
      ]);
      expect(find.byType(PopupMenuDivider), findsOneWidget);
      // Header (name, signed amount), divider, then New / Trim / Edit.
      final div = tester.getCenter(find.byType(PopupMenuDivider)).dy;
      expect(
        div,
        inExclusiveRange(
          tester.getCenter(find.byKey(const ValueKey('dot-menu-header'))).dy,
          tester.getCenter(find.byKey(const ValueKey('dot-menu-new'))).dy,
        ),
      );
      // Anchored at the click (on the dot), inside the screen.
      final m = tester.getRect(
        find
            .ancestor(
              of: find.byKey(const ValueKey('dot-menu-new')),
              matching: find.byType(Material),
            )
            .first,
      );
      expect((m.topLeft - (origin + dot)).distance, lessThan(60));
      expect(m.right, lessThanOrEqualTo(1440));
      expect(m.bottom, lessThanOrEqualTo(800));
      // Esc closes it without acting.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(log, isEmpty);
      for (final (key, want) in [
        ('dot-menu-new', 'new $day7'),
        ('dot-menu-trim', 'trim a $day7'),
        ('dot-menu-edit', 'edit a $day7'),
      ]) {
        await tester.pump(const Duration(milliseconds: 400));
        await clickDot();
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
        expect(menu, findsNothing);
        expect(log.last, want);
      }
      expect(log, hasLength(3));
      // Leaving the lanes hides the dot again (after a short grace).
      await mouse.moveTo(origin + const Offset(1300, 760));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 6));
      painted.clear();
      tester
          .renderObjectList<RenderCustomPaint>(
            find.descendant(
              of: find.byType(BalanceChart),
              matching: find.byType(CustomPaint),
            ),
          )
          .forEach((r) => r.markNeedsPaint());
      await tester.pump();
      expect(painted, isEmpty, reason: 'dots hidden again');
    });

    testWidgets('the menu says Edit Event for a once-off, Edit Series for '
        'a series', (tester) async {
      final log = <String>[];
      final at = steps(
        await pump(tester, ['a', 'b', 'c'], log: log, once: {'c'}),
      );
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      for (final (id, want) in [('c', 'Edit Event'), ('a', 'Edit Series')]) {
        await tester.tapAt(origin + at[id]![0], kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(_menuLabels(tester), [
          'New Event From Here',
          'Trim From Here',
          want,
        ], reason: id);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 400));
      }
      // The once-off's Trim goes to the page (which asks, then deletes).
      await tester.tapAt(origin + at['c']![0], kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(_enabled(tester, 'dot-menu-trim'), isTrue);
      await tester.tap(find.byKey(const ValueKey('dot-menu-trim')));
      await tester.pumpAndSettle();
      expect(log, ['trim c $day0']);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('viewers see the menu with every action disabled', (
      tester,
    ) async {
      final log = <String>[];
      final at = steps(
        await pump(tester, ['a', 'b', 'c'], log: log, canEdit: false),
      );
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      await tester.tapAt(origin + at['b']![1], kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(_menuLabels(tester), [
        'New Event From Here',
        'Trim From Here',
        'Edit Series',
      ]);
      for (final k in ['dot-menu-new', 'dot-menu-trim', 'dot-menu-edit']) {
        expect(_enabled(tester, k), isFalse, reason: k);
      }
      await tester.tap(
        find.byKey(const ValueKey('dot-menu-new')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(log, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
    });

    /// The open menu's surface, in global coordinates.
    Rect menuRect(WidgetTester tester) => tester.getRect(
      find
          .ancestor(
            of: find.byKey(const ValueKey('dot-menu-new')),
            matching: find.byType(Material),
          )
          .first,
    );

    Future<void> closeMenu(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('touch: one tap anywhere on a lane opens its menu at the '
        'tap (no reveal step, no popup, never creating)', (tester) async {
      var created = 0;
      final log = <String>[];
      final at = steps(
        await pump(
          tester,
          ['a', 'b', 'c'],
          size: const Size(390, 844),
          onCreate: (_) => created++,
          log: log,
        ),
      );
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      final dayPx = ChartLayout.of(const Size(390, 844), 30).plot.width / 30;
      final tip = find.byKey(const ValueKey('occurrence-tooltip'));
      final menu = find.byWidgetPredicate((w) => w is PopupMenuItem);
      // Mid-step, well right of the (hidden) dot.
      final tap = origin + at['c']![0] + Offset(dayPx * 4, 0);
      await tester.tapAt(tap, kind: PointerDeviceKind.touch);
      await tester.pumpAndSettle();
      expect(tip, findsNothing);
      expect(_menuLabels(tester), [
        'New Event From Here',
        'Trim From Here',
        'Edit Series',
      ]);
      expect(created, 0);
      // At the tap: its nearest corner within a few px of the finger.
      final m = menuRect(tester);
      final corner = Offset(
        tap.dx.clamp(m.left, m.right),
        tap.dy.clamp(m.top, m.bottom),
      );
      expect((corner - tap).distance, lessThanOrEqualTo(12));
      // Touch rows are 44px tall.
      expect(
        tester.getSize(find.byKey(const ValueKey('dot-menu-trim'))).height,
        greaterThanOrEqualTo(44),
      );
      await tester.tap(find.byKey(const ValueKey('dot-menu-new')));
      await tester.pumpAndSettle();
      expect(log, ['new $day0'], reason: 'the step at or before the tap');
      expect(menu, findsNothing);
      expect(created, 0);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('the menu opens with a header: the event name and its '
        'signed amount (green gain, red loss), then a divider, New, Trim, '
        'Edit', (tester) async {
      final at = steps(await pump(tester, ['a', 'b', 'c'], log: []));
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      final dayPx = ChartLayout.of(const Size(1440, 800), 30).plot.width / 30;
      for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
        for (final (id, name, amount, color) in [
          ('a', 'Rent', '−\$10.00', AppTheme.debitColor),
          ('b', 'Salary', '+\$10.00', AppTheme.creditColor),
        ]) {
          await tester.tapAt(
            origin + at[id]![1] + Offset(dayPx * 3, 0),
            kind: kind,
          );
          await tester.pumpAndSettle();
          final header = find.byKey(const ValueKey('dot-menu-header'));
          expect(header, findsOneWidget);
          expect(
            tester.widget<PopupMenuItem<int>>(header).enabled,
            isFalse,
            reason: 'a title, not an action',
          );
          final n = tester.widget<Text>(
            find.byKey(const ValueKey('dot-menu-name')),
          );
          final a = tester.widget<Text>(
            find.byKey(const ValueKey('dot-menu-amount')),
          );
          expect(n.data, name);
          expect(a.data, amount);
          expect(a.style!.color, color, reason: '$id ($kind)');
          // Order: header, divider, New, Trim, Edit (one divider).
          final ys = [
            tester.getCenter(header).dy,
            tester.getCenter(find.byType(PopupMenuDivider)).dy,
            for (final k in ['dot-menu-new', 'dot-menu-trim', 'dot-menu-edit'])
              tester.getCenter(find.byKey(ValueKey(k))).dy,
          ];
          expect(ys, [...ys]..sort(), reason: '$id ($kind)');
          expect(find.byType(PopupMenuDivider), findsOneWidget);
          await closeMenu(tester);
        }
      }
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('a long name ellipsizes; the amount stays whole', (
      tester,
    ) async {
      final at = steps(
        await pump(tester, ['a', 'b', 'c'], size: const Size(390, 844)),
      );
      // Swap in a very long name for Rent (a) via a fresh chart.
      final chart = tester.widget<BalanceChart>(find.byType(BalanceChart));
      final long = 'Rent for the flat on the corner of a very long street name';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              height: 844,
              child: BalanceChart(
                series: chart.series,
                seedDate: chart.seedDate,
                viewStart: chart.viewStart,
                visibleDays: chart.visibleDays,
                eventNames: {...chart.eventNames, 'a': long},
                laneOrder: chart.laneOrder,
                events: {...chart.events, 'a': _t('a', long)},
                onViewportChanged: (_, _) {},
                onCreateOnDay: (_) {},
                onNewOnDay: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      await tester.tapAt(
        origin + at['a']![1] + const Offset(10, 0),
        kind: PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();
      final name = find.byKey(const ValueKey('dot-menu-name'));
      final amount = find.byKey(const ValueKey('dot-menu-amount'));
      expect(tester.widget<Text>(name).data, long);
      expect(tester.widget<Text>(name).overflow, TextOverflow.ellipsis);
      final m = menuRect(tester);
      expect(tester.getRect(amount).right, lessThanOrEqualTo(m.right));
      expect(
        tester.getRect(amount).left,
        greaterThan(tester.getRect(name).right),
      );
      expect(tester.getRect(name).left, greaterThanOrEqualTo(m.left));
      expect(tester.takeException(), isNull);
      await closeMenu(tester);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('a drag (pan) along a lane, a pinch or a two-finger tap '
        'never opens the menu', (tester) async {
      final log = <String>[];
      final at = steps(
        await pump(
          tester,
          ['a', 'b', 'c'],
          size: const Size(390, 844),
          log: log,
        ),
      );
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      final menu = find.byWidgetPredicate((w) => w is PopupMenuItem);
      final p = origin + at['a']![1] + const Offset(20, 0);
      for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
        await tester.dragFrom(p, const Offset(-80, 0), kind: kind);
        await tester.pumpAndSettle();
        expect(menu, findsNothing, reason: 'pan ($kind)');
        await tester.pump(const Duration(milliseconds: 400));
      }
      // Pinch: two fingers on the lane, spreading.
      final f1 = await tester.startGesture(
        p - const Offset(15, 0),
        kind: PointerDeviceKind.touch,
        pointer: 7,
      );
      final f2 = await tester.startGesture(
        p + const Offset(15, 0),
        kind: PointerDeviceKind.touch,
        pointer: 8,
      );
      for (var i = 1; i <= 6; i++) {
        await f1.moveTo(p - Offset(15.0 + i * 12, 0));
        await f2.moveTo(p + Offset(15.0 + i * 12, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await f1.up();
      await f2.up();
      await tester.pumpAndSettle();
      expect(menu, findsNothing, reason: 'pinch');
      await tester.pump(const Duration(milliseconds: 400));
      // Two fingers down and up without moving: not a tap either.
      final g1 = await tester.startGesture(
        p,
        kind: PointerDeviceKind.touch,
        pointer: 9,
      );
      final g2 = await tester.startGesture(
        p + const Offset(30, 0),
        kind: PointerDeviceKind.touch,
        pointer: 10,
      );
      await g2.up();
      await g1.up();
      await tester.pumpAndSettle();
      expect(menu, findsNothing, reason: 'two-finger tap');
      expect(log, isEmpty);
      // A plain tap afterwards still opens it.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tapAt(p, kind: PointerDeviceKind.touch);
      await tester.pumpAndSettle();
      expect(_menuLabels(tester), hasLength(3));
      await closeMenu(tester);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('the menu always fits inside the chart: near its right, '
        'left and bottom edges it flips / shifts', (tester) async {
      for (final size in [const Size(1440, 800), const Size(390, 844)]) {
        final at = steps(await pump(tester, ['a', 'b', 'c'], size: size));
        final chart = tester.getRect(find.byType(BalanceChart));
        final plot = ChartLayout.of(size, 30).plot.shift(chart.topLeft);
        final taps = <String, Offset>{
          // The second step's lanes run off the right edge.
          'right': Offset(plot.right - 3, chart.top + at['a']![1].dy),
          // The first step's lowest lane (the stack sits low).
          'bottom': chart.topLeft + at['c']![0] + const Offset(12, 4),
          // Where the lanes begin, near the left.
          'left': chart.topLeft + at['b']![0] + const Offset(3, 0),
          'top': chart.topLeft + at['b']![1] + const Offset(40, -2),
        };
        for (final MapEntry(key: edge, value: tap) in taps.entries) {
          for (final kind in [
            PointerDeviceKind.mouse,
            PointerDeviceKind.touch,
          ]) {
            await tester.tapAt(tap, kind: kind);
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('dot-menu-header')),
              findsOneWidget,
              reason: '$edge $size $kind',
            );
            final m = menuRect(tester);
            final why = '$edge $size $kind: $m in $chart';
            expect(m.left, greaterThanOrEqualTo(chart.left), reason: why);
            expect(m.top, greaterThanOrEqualTo(chart.top), reason: why);
            expect(m.right, lessThanOrEqualTo(chart.right), reason: why);
            expect(m.bottom, lessThanOrEqualTo(chart.bottom), reason: why);
            // Every row is fully shown (nothing scrolled / clipped).
            for (final k in ['dot-menu-header', 'dot-menu-edit']) {
              final r = tester.getRect(find.byKey(ValueKey(k)));
              expect(
                m.contains(r.topLeft) &&
                    m.contains(r.bottomRight - const Offset(0.5, 0.5)),
                isTrue,
                reason: '$k $why',
              );
            }
            if (edge == 'right') {
              expect(
                m.right,
                lessThanOrEqualTo(tap.dx + 0.5),
                reason: 'flipped left: $why',
              );
            }
            await closeMenu(tester);
          }
        }
        await tester.pump(const Duration(seconds: 6));
      }
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

    testWidgets('the auto-fit leaves room for the whole stack under the '
        'line', (tester) async {
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
      // The highest balance keeps a chip's room above it ...
      expect(px(1500), greaterThan(0));
      // ... and the lowest its whole stack below, nothing clipped.
      expect(
        layout.plot.height - px(1000),
        greaterThanOrEqualTo(laneGap + h * 3),
      );
    });

    testWidgets('the ribbon hangs just under the balance\'s own y, at '
        'every day, zoomed in or out', (tester) async {
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
          expect(rect.top, closeTo(y + laneGap, 0.01), reason: '${e.key}');
          expect(
            rect.top,
            closeTo(yOf(balance) + laneGap, 0.01),
            reason: '$days',
          );
          // Fitted: the stack is never clipped by the plot.
          expect(rect.bottom, lessThanOrEqualTo(layout.plot.bottom + 0.01));
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
      expect(r.bottom - 1.8, closeTo(yOf(400), 0.01));
      expect(r.top + 1.8, closeTo(yOf(1000), 0.01));
      expect(r.center.dx, closeTo(seen[_start]!.left, 0.01));
    });

    testWidgets('a crisp true-balance line runs through a stack at the '
        'balance\'s exact y, stepping at the day edge', (tester) async {
      final pieces = <Rect>[];
      debugTrueLine = pieces.add;
      final ribbons = <DateTime, Rect>{};
      debugRibbon = (d, r, _) => ribbons[d] = r;
      await pump(tester, ['a', 'b', 'c']);
      final range =
          (tester.state(find.byType(BalanceChart)) as dynamic).debugYRange
              as BalanceExtents;
      final layout = ChartLayout.of(const Size(1440, 800), 30);
      double yOf(double v) =>
          layout.plot.bottom -
          (v - range.min) / (range.max - range.min) * layout.plot.height;
      final levels = pieces.where((r) => r.height <= 4).toList();
      final steps = pieces.where((r) => r.height > 4).toList();
      expect(levels.map((r) => r.center.dy).toSet().length, 2);
      for (final r in levels) {
        expect(r.height, closeTo(3, 0.01));
        final y = r.center.dy;
        expect(
          (y - yOf(1000)).abs() < 0.01 || (y - yOf(1500)).abs() < 0.01,
          isTrue,
          reason: '$r',
        );
      }
      // The stack hangs just under the line, at every level.
      for (final e in ribbons.entries) {
        final y = e.key.isBefore(_start.add(const Duration(days: 7)))
            ? yOf(1000)
            : yOf(1500);
        expect(e.value.top, closeTo(y + laneGap, 0.01));
      }
      // One step, at day 8's left edge, spanning the two balances.
      final step = steps.single;
      final edge = ribbons[_start.add(const Duration(days: 7))]!.left;
      expect(step.center.dx, closeTo(edge, 0.01));
      expect(step.top + 1.5, closeTo(yOf(1500), 0.01));
      expect(step.bottom - 1.5, closeTo(yOf(1000), 0.01));
    });

    testWidgets('the balance line paints over the lanes and their text, '
        'unbroken through every stack', (tester) async {
      final pieces = <Rect>[];
      final ribbons = <Rect>[];
      final order = <String>[];
      debugRibbon = (_, r, _) {
        // A new stack paint: keep only the latest frame's order.
        if (order.isNotEmpty && order.last != 'ribbon') {
          order.clear();
          pieces.clear();
          ribbons.clear();
        }
        order.add('ribbon');
        ribbons.add(r);
      };
      debugTrueLine = (r) {
        order.add('line');
        pieces.add(r);
      };
      debugLaneName = (_, _) => order.add('text');
      debugLaneAmount = (_, _, _, _) => order.add('text');
      await pump(tester, ['a', 'b', 'c']);
      expect(order, contains('text'));
      final lastLine = order.lastIndexOf('line');
      expect(order.lastIndexOf('ribbon'), lessThan(order.indexOf('line')));
      // Over the lane text: every line piece after the last name / pill.
      expect(order.indexOf('line'), greaterThan(order.lastIndexOf('text')));
      expect(lastLine, order.length - 1);
      // Every stack's whole width carries the line just over its top.
      for (final r in ribbons) {
        expect(
          pieces.any(
            (p) =>
                p.height <= 4 &&
                (p.center.dy - (r.top - laneGap)).abs() < 0.01 &&
                p.left <= r.left + 0.01 &&
                p.right >= r.right - 0.01,
          ),
          isTrue,
          reason: '$r',
        );
      }
    });

    testWidgets('a single lane hangs directly under the line', (tester) async {
      final pieces = <Rect>[];
      debugTrueLine = pieces.add;
      final ribbons1 = <Rect>[];
      debugRibbon = (_, r, _) => ribbons1.add(r);
      await pump(
        tester,
        ['a'],
        occurs: {
          0: ['a'],
          7: ['a'],
        },
        only: {'a'},
      );
      expect(ribbons1, isNotEmpty);
      expect(ribbons1.first.height, 16);
      for (final r in ribbons1) {
        expect(
          pieces.any(
            (p) =>
                p.height <= 4 &&
                (p.center.dy - (r.top - laneGap)).abs() < 0.01 &&
                p.left <= r.left + 0.01 &&
                p.right >= r.right - 0.01,
          ),
          isTrue,
        );
      }
      // And it steps with the balance at day 8.
      expect(pieces.where((p) => p.height > 4), hasLength(1));
    });

    testWidgets('20+ events: a short stack near its dollars, the '
        'true line still drawn, dots still on every lane', (tester) async {
      final pieces = <Rect>[];
      debugTrueLine = pieces.add;
      final ribbons = <Rect>[];
      debugRibbon = (_, r, _) => ribbons.add(r);
      final ids = [for (var i = 0; i < 22; i++) 't$i'];
      final dots = <String?, List<Offset>>{};
      debugLaneDot = (id, c) => (dots[id] ??= []).add(c);
      tester.view.physicalSize = const Size(1440, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BalanceChart(
              series: BalanceSeries(
                points: [
                  for (var i = 0; i < 40; i++)
                    BalancePoint(
                      date: _start.add(Duration(days: i)),
                      closingBalance: Decimal.fromInt(5000 - (i ~/ 7) * 300),
                    ),
                ],
                occurrences: [
                  for (final id in ids)
                    for (final o in [0, 7, 14])
                      Occurrence(
                        eventId: id,
                        date: _start.add(Duration(days: o)),
                        signedDelta: Decimal.fromInt(-10),
                      ),
                ],
              ),
              seedDate: _start.subtract(const Duration(days: 30)),
              viewStart: _start.subtract(const Duration(days: 2)),
              visibleDays: 30,
              eventNames: {for (final id in ids) id: id},
              laneOrder: ids,
              events: {for (final id in ids) id: _t(id, 'Item $id')},
              onViewportChanged: (_, _) {},
              onCreateOnDay: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      final plot = ChartLayout.of(const Size(1440, 800), 30).plot;
      expect(ribbons, isNotEmpty);
      for (final r in ribbons) {
        expect(r.height, lessThanOrEqualTo(plot.height * 0.25 + 0.01));
      }
      expect(pieces.where((r) => r.width > r.height), isNotEmpty);
      for (final id in ids) {
        expect(dots[id], hasLength(3), reason: id);
      }
      expect(tester.takeException(), isNull);
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

    testWidgets('a lane dot\'s menu acts on its own event only', (
      tester,
    ) async {
      final log = <String>[];
      final at = steps(await pump(tester, ['a', 'b', 'c'], log: log));
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
        for (final id in ['a', 'b', 'c']) {
          log.clear();
          // One tap or click opens the menu (no reveal step on touch).
          await tester.tapAt(origin + at[id]![0], kind: kind);
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('occurrence-tooltip')),
            findsNothing,
          );
          await tester.tap(find.byKey(const ValueKey('dot-menu-edit')));
          await tester.pumpAndSettle();
          expect(log, ['edit $id $day0'], reason: '$id ($kind)');
          await tester.pump(const Duration(seconds: 6));
        }
      }
    });

    testWidgets('every event gets its own dot at every step, in its '
        'own lane', (tester) async {
      final dots = await pump(tester, ['a', 'b', 'c']);
      final layout = ChartLayout.of(const Size(1440, 800), 30);
      final h = laneThickness(
        maxActive: 3,
        plotHeight: layout.plot.height,
        phone: false,
      );
      // Two steps (day 0 and day 7) x three events: no grouping.
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
    /// event and whether it occurs on that step.
    Future<Map<double, List<({String? id, Offset c, bool idle})>>> allDots(
      WidgetTester tester,
      List<String> order, {
      required Map<int, List<String>> occurs,
      Size size = const Size(1440, 800),
      void Function(DateTime)? onCreate,
      bool actions = false,
      List<String>? log,
    }) async {
      final all = <({String? id, Offset c, bool idle})>[];
      await pump(
        tester,
        order,
        size: size,
        occurs: occurs,
        onCreate: onCreate,
        actions: actions,
        log: log,
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
        'its event occurs on it', (tester) async {
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
        events: {
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
                eventId: id,
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

    testWidgets('a ring dot (the event not occurring there) opens the same '
        'menu; its Trim is from that step; never creates', (tester) async {
      final created = <DateTime>[];
      final log = <String>[];
      final steps = await allDots(
        tester,
        ['a', 'b', 'c'],
        occurs: {
          0: ['a', 'b'],
          7: ['c'],
        },
        onCreate: created.add,
        log: log,
      );
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      final xs = steps.keys.toList()..sort();
      final tip = find.byKey(const ValueKey('occurrence-tooltip'));
      for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
        // Rent (a) is idle on the second step; Gym (c) is idle on the first.
        for (final (x, id, day) in [
          (xs[1], 'a', day7),
          (xs[0], 'c', day0),
          (xs[1], 'b', day7),
        ]) {
          final dot = steps[x]!.firstWhere((d) => d.id == id);
          expect(dot.idle, isTrue);
          log.clear();
          await tester.tapAt(origin + dot.c, kind: kind);
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          expect(tip, findsNothing);
          expect(_menuLabels(tester), [
            'New Event From Here',
            'Trim From Here',
            'Edit Series',
          ], reason: '$id ring ($kind)');
          await tester.tap(find.byKey(const ValueKey('dot-menu-trim')));
          await tester.pumpAndSettle();
          expect(log, ['trim $id $day'], reason: '$id ring ($kind)');
          await tester.pump(const Duration(seconds: 6));
        }
      }
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

    testWidgets('lane labels name the event then its amount, green '
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

    Future<
      ({
        List<(String, Rect)> pills,
        List<(String, Rect)> names,
        Map<String?, List<Offset>> dots,
      })
    >
    labels(
      WidgetTester tester, {
      Size size = const Size(1440, 800),
      double visibleDays = 30,
    }) async {
      final pills = <(String, Rect)>[], names = <(String, Rect)>[];
      debugLaneAmount = (name, amount, color, pill) => pills.add((name, pill));
      debugLaneName = (name, rect) => names.add((name, rect));
      addTearDown(() {
        debugLaneAmount = null;
        debugLaneName = null;
      });
      final dots = await pump(
        tester,
        ['a', 'b', 'c'],
        size: size,
        visibleDays: visibleDays,
      );
      return (pills: pills, names: names, dots: dots);
    }

    testWidgets('lane amounts right-align on a shared edge per step, names '
        'stay left', (tester) async {
      final l = await labels(tester);
      // Two steps (the stack moves at day 7): one column of 3 amounts each.
      final byRight = <int, List<(String, Rect)>>{};
      for (final p in l.pills) {
        (byRight[p.$2.right.round()] ??= []).add(p);
      }
      expect(byRight, hasLength(2), reason: '${l.pills}');
      for (final col in byRight.values) {
        expect(col, hasLength(3));
        final r = col.first.$2.right;
        for (final p in col) {
          expect(p.$2.right, closeTo(r, 0.01), reason: 'same right edge');
        }
      }
      // The first column ends clear of the second step's dots.
      final firstEdge = byRight.keys.reduce(math.min).toDouble();
      final stepX = l.dots['a']!.map((o) => o.dx).reduce(math.max);
      expect(firstEdge, lessThan(stepX - 4));
      // The last segment runs off the chart: its column hugs the right edge.
      final lastEdge = byRight.keys.reduce(math.max).toDouble();
      expect(lastEdge, closeTo(1440 - 4, 1.5));
      // Each name sits left of its own amount, all names flush left.
      for (final (name, rect) in l.names) {
        final pill = l.pills.firstWhere(
          (p) =>
              p.$1 == name &&
              (p.$2.center.dy - rect.center.dy).abs() < 3 &&
              p.$2.left > rect.left,
        );
        expect(rect.right, lessThanOrEqualTo(pill.$2.left - 4));
      }
      final lefts = {
        for (final n in l.names)
          if (n.$2.left < firstEdge) n.$2.left.round(),
      };
      expect(lefts, hasLength(1), reason: 'names share a left edge');
    });

    testWidgets('when tight, names give way first, then amounts', (
      tester,
    ) async {
      // Phone, 25 days: the first step is ~110px wide: amounts only.
      final tight = await labels(
        tester,
        size: const Size(390, 844),
        visibleDays: 25,
      );
      final stepX = tight.dots['a']!.map((o) => o.dx).reduce(math.max);
      final first = tight.pills.where((p) => p.$2.right < stepX).toList();
      expect(first, hasLength(3), reason: 'every lane keeps its amount');
      expect(
        tight.names.where((n) => n.$2.left < stepX),
        isEmpty,
        reason: 'no room for names there',
      );
      final r = first.first.$2.right;
      for (final p in first) {
        expect(p.$2.right, closeTo(r, 0.01));
      }
      // Every drawn name has its amount.
      for (final (name, _) in tight.names) {
        expect(tight.pills.any((p) => p.$1 == name), isTrue);
      }
    });

    testWidgets('a step too narrow for its amount shows neither', (
      tester,
    ) async {
      // Phone, 60 days: the first step is ~45px wide.
      final l = await labels(
        tester,
        size: const Size(390, 844),
        visibleDays: 60,
      );
      final stepX = l.dots['a']!.map((o) => o.dx).reduce(math.max);
      expect(l.pills.where((p) => p.$2.left < stepX), isEmpty);
      expect(l.names.where((n) => n.$2.left < stepX), isEmpty);
      // The wide last step still labels every lane, amounts right-aligned.
      expect(l.pills, hasLength(3));
      for (final p in l.pills) {
        expect(p.$2.right, closeTo(390 - 4, 1.5));
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
      final painted = <String?>{};
      debugLaneDotPainted = (id, _, _) => painted.add(id);
      final log = <String>[];
      final at = steps(
        await pump(
          tester,
          ['a', 'b', 'c'],
          size: const Size(390, 844),
          log: log,
        ),
      );
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      // 20px right of the lane dot, on its lane: one tap opens its menu.
      await tester.tapAt(
        origin + at['b']![0] + const Offset(20, 0),
        kind: PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();
      expect(painted, contains('b'));
      await tester.tap(find.byKey(const ValueKey('dot-menu-edit')));
      await tester.pumpAndSettle();
      expect(log, ['edit b $day0']);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('a heavy stream: thin lanes, no names, dots still tappable', (
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
                        eventId: id,
                        date: _start,
                        signedDelta: Decimal.fromInt(-5),
                      ),
                  ],
                ),
                seedDate: _start.subtract(const Duration(days: 30)),
                viewStart: _start,
                visibleDays: 30,
                eventNames: {for (final id in ids) id: id},
                laneOrder: ids,
                events: {for (final id in ids) id: _t(id, 'Item $id')},
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
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dot-menu-edit')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
    });
  });
}
