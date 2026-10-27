// The balance line's step dots: a permanent dot wherever the line steps
// (the net of that day's events), with a hover / tap tooltip showing the
// net change and the balance after it, and guides to both axes.
import 'dart:ui';

import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/step_dots.dart';
import 'package:budget_client/theme/app_theme.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chip_taps.dart';

DateTime _day(int i) => DateTime(2031, 3, 1 + i);

Occurrence _o(
  String id,
  int day,
  int amount, {
  bool skipped = false,
  bool netted = false,
  String? stream,
}) => Occurrence(
  eventId: id,
  date: _day(day),
  signedDelta: Decimal.fromInt(amount),
  skipped: skipped,
  netted: netted,
  streamId: stream,
);

/// Daily closes from day -5 to day 60: [seed] plus every counted
/// occurrence so far (netted transfers move nothing).
BalanceSeries _series(List<Occurrence> occ, {int seed = 5000, int days = 60}) {
  final points = <BalancePoint>[];
  for (var i = -5; i <= days; i++) {
    final d = _day(i);
    var bal = seed;
    for (final o in occ) {
      if (o.skipped || o.netted || o.date.isAfter(d)) continue;
      bal += o.signedDelta.toBigInt().toInt();
    }
    points.add(BalancePoint(date: d, closingBalance: Decimal.fromInt(bal)));
  }
  return BalanceSeries(points: points, occurrences: occ);
}

/// Day 0: four events (+1800 −1100 −400 −200) net +100. Day 3: −400.
/// Day 7: −500 and +500 net to zero (no step). Day 10: +250.
final _mixed = [
  _o('b', 0, 1800),
  _o('a', 0, -1100),
  _o('c', 0, -400),
  _o('d', 0, -200),
  _o('c', 3, -400),
  _o('a', 7, -500),
  _o('b', 7, 500),
  _o('b', 10, 250),
];

BudgetEvent _t(String id, String name, EventDirection dir) => BudgetEvent(
  id: id,
  streamId: 's',
  name: name,
  direction: dir,
  amount: Decimal.fromInt(10),
  startDate: _day(0),
  recurrenceMode: RecurrenceMode.every,
  interval: 1,
  unit: RecurrenceUnit.weeks,
  endMode: EndMode.never,
);

final _events = {
  'a': _t('a', 'Rent', EventDirection.debit),
  'b': _t('b', 'Salary', EventDirection.credit),
  'c': _t('c', 'Groceries', EventDirection.debit),
  'd': _t('d', 'Gym', EventDirection.debit),
};

void main() {
  group('steps', () {
    test('a day nets its gains and losses into one step', () {
      final steps = balanceSteps(_series(_mixed), lineStart: _day(-5));
      expect([for (final s in steps) s.day], [_day(0), _day(3), _day(10)]);
      final first = steps.first;
      expect(first.before, 5000);
      expect(first.balance, 5100);
      expect(first.delta, 100);
      expect(first.events, 4);
      expect(steps[1].delta, -400);
      expect(steps[1].balance, 4700);
      expect(steps[2].delta, 250);
      expect(steps[2].events, 1);
    });

    test('a day whose events net to zero has no step', () {
      final steps = balanceSteps(_series(_mixed), lineStart: _day(-5));
      expect(steps.where((s) => s.day == _day(7)), isEmpty);
    });

    test('combined view: a transfer between the streams nets out, and is '
        'not counted', () {
      final steps = balanceSteps(
        _series([
          _o('t', 2, -500, netted: true, stream: 'x'),
          _o('t2', 2, 500, netted: true, stream: 'y'),
          _o('t', 5, -500, netted: true, stream: 'x'),
          _o('t2', 5, 500, netted: true, stream: 'y'),
          _o('ins', 5, -220, stream: 'y'),
        ]),
        lineStart: _day(-5),
      );
      expect(steps, hasLength(1));
      expect(steps.single.day, _day(5));
      expect(steps.single.delta, -220);
      expect(steps.single.events, 1);
    });

    test('skipped occurrences move nothing and are not counted', () {
      final steps = balanceSteps(
        _series([_o('a', 1, -100, skipped: true), _o('b', 1, 40)]),
        lineStart: _day(-5),
      );
      expect(steps.single.delta, 40);
      expect(steps.single.events, 1);
    });

    test('no step on or before where the line starts', () {
      final steps = balanceSteps(_series(_mixed), lineStart: _day(0));
      expect([for (final s in steps) s.day], [_day(3), _day(10)]);
    });

    test('deltas and balances read to the cent, signed', () {
      expect(formatStepDelta(-100), '−\$100.00');
      expect(formatStepDelta(250), '+\$250.00');
      expect(formatStepDelta(1234.5), '+\$1,234.50');
      expect(formatStepBalance(5100), '\$5,100.00');
      expect(formatStepEvents(1), '1 event');
      expect(formatStepEvents(5), '5 events');
    });

    test('the tooltip sits over its dot, inside the plot', () {
      const bounds = Rect.fromLTWH(50, 20, 400, 300);
      const size = Size(140, 70);
      // Room above: centred over the dot.
      var p = placeStepTip(size, const Offset(250, 200), 12, bounds);
      expect(p, const Offset(180, 118));
      // Near the top: below the dot instead.
      p = placeStepTip(size, const Offset(250, 40), 12, bounds);
      expect(p.dy, 52);
      // Near the left / right edges: slid inside.
      p = placeStepTip(size, const Offset(55, 200), 12, bounds);
      expect(p.dx, 54);
      p = placeStepTip(size, const Offset(448, 200), 12, bounds);
      expect(p.dx + size.width, 446);
      // Bottom-right corner: still fully inside.
      p = placeStepTip(size, const Offset(449, 319), 12, bounds);
      expect(bounds.contains(p), isTrue);
      expect(bounds.contains(p + const Offset(140, 70)), isTrue);
    });

    test('dense zooms thin the dots so none touch; roomy ones keep all', () {
      final steps = [
        for (var i = 0; i < 200; i++)
          BalanceStep(day: _day(i), before: 0, balance: 1, events: 1),
      ];
      const plot = Rect.fromLTWH(0, 0, 600, 400);
      List<StepDot> at(double dayPx) => visibleStepDots(
        steps: steps,
        xOf: (d) => d.difference(_day(0)).inHours / 24 * dayPx + 2,
        yOf: (_) => 200,
        plot: plot,
        dayPx: dayPx,
      );
      final dense = at(3);
      expect(dense.length, lessThan(200));
      expect(dense, isNotEmpty);
      for (var i = 1; i < dense.length; i++) {
        expect(
          dense[i].center.dx - dense[i - 1].center.dx,
          greaterThanOrEqualTo(stepDotMinGap(dense[i].radius)),
        );
      }
      final roomy = at(40);
      // Every step in view (x 2..602 on a 600px plot, 40px a day) is kept.
      expect(roomy.length, 16);
      expect(roomy.first.radius, 4.5);
      expect(dense.first.radius, 3.5);
    });

    test('hit targets: 22px with a mouse, 44px by touch', () {
      final d = StepDot(
        BalanceStep(day: _day(0), before: 0, balance: 1, events: 1),
        const Offset(100, 100),
        4.5,
      );
      expect(stepDotAt([d], const Offset(110, 100), touch: false), d);
      expect(stepDotAt([d], const Offset(112, 100), touch: false), isNull);
      expect(stepDotAt([d], const Offset(121, 100), touch: true), d);
      expect(stepDotAt([d], const Offset(123, 100), touch: true), isNull);
    });
  });

  group('chart', () {
    tearDown(() {
      debugStepDotPainted = null;
      debugLaneDotPainted = null;
      debugLaneDot = null;
    });

    /// Pumps the chart; returns each drawn step dot's centre by day.
    Future<Map<DateTime, Offset>> pump(
      WidgetTester tester, {
      Size size = const Size(1440, 800),
      double visibleDays = 20,
      List<Occurrence>? occ,
      List<DateTime>? created,
      List<String>? log,
      Map<String, List<Offset>>? lanes,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final dots = <DateTime, Offset>{};
      debugStepDotPainted = (s, c, r, active) {
        if (!active) dots[s.day] = c;
      };
      debugLaneDot = (id, c) {
        if (id != null && lanes != null) (lanes[id] ??= []).add(c);
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox.fromSize(
              size: size,
              child: BalanceChart(
                series: _series(occ ?? _mixed),
                seedDate: _day(-5),
                seedBalance: 5000,
                viewStart: _day(-2),
                visibleDays: visibleDays,
                eventNames: {for (final e in _events.values) e.id: e.name},
                laneOrder: const ['a', 'b', 'c', 'd'],
                events: _events,
                lossThreshold: -100000,
                onViewportChanged: (_, _) {},
                onCreateOnDay: (d) => created?.add(d),
                onNewOnDay: (d) => log?.add('new $d'),
                onEditEvent: (t, d) => log?.add('edit ${t.id}'),
                onTrimOccurrence: (t, d) => log?.add('trim ${t.id}'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return dots;
    }

    Finder tip() => find.byKey(const ValueKey('step-tooltip'));
    String text(WidgetTester tester, String key) {
      final w = tester.widget<Text>(find.byKey(ValueKey(key)));
      return w.data ?? w.textSpan!.toPlainText();
    }

    testWidgets('a permanent dot on the line at every non-zero step, none '
        'for a zero-net day, and no lane dots', (tester) async {
      final lanePainted = <String?>[];
      debugLaneDotPainted = (id, _, _) => lanePainted.add(id);
      final dots = await pump(tester);
      expect(dots.keys.toSet(), {_day(0), _day(3), _day(10)});
      // On the balance line: higher balance, higher on screen.
      expect(dots[_day(0)]!.dy, lessThan(dots[_day(3)]!.dy));
      expect(dots[_day(10)]!.dy, lessThan(dots[_day(3)]!.dy));
      expect(tip(), findsNothing, reason: 'tooltips only on hover / tap');
      expect(lanePainted.where((id) => id != null), isEmpty);
    });

    testWidgets('hovering a dot shows the date, the net change, the balance '
        'and the event count, with the balance on the y axis', (tester) async {
      final dots = await pump(tester);
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: origin + const Offset(1400, 40));
      addTearDown(mouse.removePointer);
      await tester.pump();
      await mouse.moveTo(origin + dots[_day(0)]! + const Offset(4, -3));
      await tester.pump();
      expect(tip(), findsOneWidget);
      expect(text(tester, 'step-tooltip-date'), contains('1st March'));
      expect(text(tester, 'step-tooltip-delta'), '+\$100.00');
      expect(text(tester, 'step-tooltip-balance'), 'Balance \$5,100.00');
      expect(text(tester, 'step-tooltip-events'), '4 events');
      final delta = tester.widget<Text>(
        find.byKey(const ValueKey('step-tooltip-delta')),
      );
      expect(delta.style!.color, AppTheme.creditColor);
      // The y-axis guide labels the balance at the step.
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(const ValueKey('y-highlight')),
                matching: find.byType(Text),
              ),
            )
            .data,
        '\$5,100.00',
      );
      final pill = tester.getRect(find.byKey(const ValueKey('y-highlight')));
      expect(pill.center.dy, closeTo(origin.dy + dots[_day(0)]!.dy, 1.5));
      expect(find.byKey(const ValueKey('x-highlight')), findsOneWidget);
      // Inside the chart.
      final chart = tester.getRect(find.byType(BalanceChart));
      final r = tester.getRect(tip());
      expect(chart.contains(r.topLeft) && chart.contains(r.bottomRight), true);
      // A loss reads red; no event menu or popup.
      await mouse.moveTo(origin + dots[_day(3)]!);
      await tester.pump();
      expect(text(tester, 'step-tooltip-delta'), '−\$400.00');
      expect(text(tester, 'step-tooltip-balance'), 'Balance \$4,700.00');
      expect(text(tester, 'step-tooltip-events'), '1 event');
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('step-tooltip-delta')))
            .style!
            .color,
        AppTheme.debitColor,
      );
      expect(find.byKey(const ValueKey('occurrence-tooltip')), findsNothing);
      expect(find.byType(PopupMenuItem<int>), findsNothing);
      // Off the dot: gone.
      await mouse.moveTo(origin + const Offset(1400, 40));
      await tester.pump();
      expect(tip(), findsNothing);
      expect(find.byKey(const ValueKey('y-highlight')), findsNothing);
    });

    testWidgets('a tap shows it (never creating or editing); a tap elsewhere '
        'or on another dot dismisses / switches it', (tester) async {
      final created = <DateTime>[];
      final log = <String>[];
      final dots = await pump(tester, created: created, log: log);
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      // Within the 44px touch target, above and left of the dot (its net
      // chip sits above-right).
      await tester.tapAt(
        origin + dots[_day(0)]! + const Offset(-8, -12),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(tip(), findsOneWidget);
      expect(text(tester, 'step-tooltip-delta'), '+\$100.00');
      expect(find.byKey(const ValueKey('y-highlight')), findsOneWidget);
      // Another dot switches.
      await tester.tapAt(
        origin + dots[_day(10)]!,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(text(tester, 'step-tooltip-delta'), '+\$250.00');
      // It stays (touch has no hover to end it).
      await tester.pump(const Duration(seconds: 8));
      expect(tip(), findsOneWidget);
      // Elsewhere (empty plot, away from dots and lanes): dismissed.
      await tester.tapAt(
        origin + const Offset(1400, 40),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(tip(), findsNothing);
      expect(created, isEmpty);
      expect(log, isEmpty);
      expect(find.byType(PopupMenuItem<int>), findsNothing);
      // A mouse click pins it too.
      await tester.tapAt(
        origin + dots[_day(3)]!,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(text(tester, 'step-tooltip-delta'), '−\$400.00');
      expect(created, isEmpty);
      expect(log, isEmpty);
    });

    testWidgets('a pan or pinch from a dot never shows the tooltip', (
      tester,
    ) async {
      final dots = await pump(tester);
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      final at = origin + dots[_day(3)]!;
      final g = await tester.startGesture(at, kind: PointerDeviceKind.touch);
      await g.moveBy(const Offset(-40, 0));
      await tester.pump();
      await g.moveBy(const Offset(-80, 0));
      await tester.pump();
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tip(), findsNothing);
      final a = await tester.startGesture(at, kind: PointerDeviceKind.touch);
      final b = await tester.startGesture(
        at + const Offset(120, 0),
        kind: PointerDeviceKind.touch,
      );
      await a.moveBy(const Offset(-30, 0));
      await b.moveBy(const Offset(30, 0));
      await tester.pump();
      await a.up();
      await b.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tip(), findsNothing);
    });

    testWidgets('the lane tap menu still opens on a lane, away from the dot', (
      tester,
    ) async {
      final lanes = <String, List<Offset>>{};
      final log = <String>[];
      await pump(tester, lanes: lanes, log: log);
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      // Groceries' lane (third) at the first step, a little right of it.
      final lane = lanes['c']!.first;
      for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
        await tester.tapAt(origin + lane + const Offset(30, 0), kind: kind);
        await tester.pumpAndSettle();
        expect(tip(), findsNothing, reason: '$kind');
        expect(find.byKey(const ValueKey('dot-menu-new')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('dot-menu-edit')));
        await tester.pumpAndSettle();
        expect(log.last, 'edit c');
        await tester.pump(const Duration(milliseconds: 600));
      }
    });

    testWidgets('a net chip still opens its whole-day popup', (tester) async {
      await pump(tester);
      await revealDayTip(tester, PointerDeviceKind.touch);
      expect(find.byKey(const ValueKey('day-net')), findsOneWidget);
      expect(tip(), findsNothing);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('zoomed far out, dots thin out so none touch', (tester) async {
      final occ = [for (var i = 0; i < 58; i++) _o('c', i, i.isEven ? -10 : 7)];
      final dots = await pump(
        tester,
        occ: occ,
        visibleDays: 60,
        size: const Size(390, 844),
      );
      final xs = dots.values.map((c) => c.dx).toList()..sort();
      expect(xs.length, lessThan(58));
      expect(xs, isNotEmpty);
      for (var i = 1; i < xs.length; i++) {
        expect(xs[i] - xs[i - 1], greaterThanOrEqualTo(stepDotMinGap(3.5)));
      }
    });

    testWidgets('near the right edge the tooltip stays inside the chart', (
      tester,
    ) async {
      final dots = await pump(
        tester,
        occ: [..._mixed, _o('b', 17, 90)],
        size: const Size(390, 844),
      );
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      final edge = dots[_day(17)]!;
      await tester.tapAt(origin + edge, kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tip(), findsOneWidget);
      final r = tester.getRect(tip());
      expect(r.right, lessThanOrEqualTo(origin.dx + 390));
      expect(r.left, greaterThanOrEqualTo(origin.dx));
      expect(r.top, greaterThanOrEqualTo(origin.dy));
    });
  });

  test('day groups stay the source of the event count', () {
    final g = groupByDay(_mixed).first;
    expect(g.active.length, 4);
  });
}
