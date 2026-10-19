import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/occurrence_info.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime(2026, 10, 1);
const _days = 30.0;
const _size = Size(1000, 500);

class _Harness {
  DateTime viewStart = _start;
  double visibleDays = _days;
  final created = <DateTime>[];
  final viewports = <DateTime>[];
}

Future<_Harness> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1000, 500);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 0.75;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.view.reset);
  final h = _Harness();
  final points = [
    for (var i = -60; i < 120; i++)
      BalancePoint(
        date: _start.add(Duration(days: i)),
        closingBalance: Decimal.fromInt(1000 + i),
      ),
  ];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SizedBox.fromSize(
            size: _size,
            child: BalanceChart(
              series: BalanceSeries(points: points),
              currency: 'AUD',
              seedDate: _start.subtract(const Duration(days: 60)),
              viewStart: h.viewStart,
              visibleDays: h.visibleDays,
              onViewportChanged: (start, days) => setState(() {
                h.viewStart = start;
                h.visibleDays = days;
                h.viewports.add(start);
              }),
              onCreateOnDay: h.created.add,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return h;
}

ChartLayout get _layout => ChartLayout.of(_size, _days);

/// Centre x of [day] in the initial view.
double _x(int dayIndex) =>
    _layout.plot.left + (dayIndex + 0.5) / _days * _layout.plot.width;

double get _axisY => _layout.axis.center.dy;

void main() {
  testWidgets('tap on the axis pins the line + bubble; only "+" creates', (
    tester,
  ) async {
    for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      final h = await _pump(tester);
      await tester.tapAt(Offset(_x(4), _axisY), kind: kind);
      await tester.pump(const Duration(seconds: 3));
      expect(h.created, isEmpty, reason: 'a tap never creates by itself');
      expect(find.byKey(const ValueKey('pick-bubble')), findsOneWidget);
      expect(
        find.text(formatOccurrenceDate(DateTime(2026, 10, 5))),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('pick-add')), kind: kind);
      await tester.pump();
      expect(h.created, [DateTime(2026, 10, 5)]);
      expect(find.byKey(const ValueKey('pick-bubble')), findsNothing);
      expect(h.viewports, isEmpty);
    }
  });

  testWidgets('a pinned line goes on close, tap-away, Esc or navigation', (
    tester,
  ) async {
    final h = await _pump(tester);
    final bubble = find.byKey(const ValueKey('pick-bubble'));
    Future<void> pin() async {
      await tester.tapAt(Offset(_x(6), _axisY), kind: PointerDeviceKind.touch);
      await tester.pump();
      expect(bubble, findsOneWidget);
    }

    await pin();
    await tester.tap(find.byKey(const ValueKey('pick-close')));
    await tester.pump();
    expect(bubble, findsNothing);
    await pin();
    await tester.tapAt(const Offset(40, 40), kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(bubble, findsNothing, reason: 'tap-away');
    await pin();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(bubble, findsNothing, reason: 'Esc');
    await pin();
    // A tap on the bubble itself (not its buttons) keeps it.
    await tester.tapAt(
      tester.getRect(bubble).centerLeft + const Offset(16, 0),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    expect(bubble, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // pans
    await tester.pump();
    expect(h.viewports, isNotEmpty);
    expect(bubble, findsNothing, reason: 'navigation');
    expect(h.created, isEmpty);
  });

  testWidgets('drag along the axis shows the date and picks on release', (
    tester,
  ) async {
    final h = await _pump(tester);
    final g = await tester.startGesture(
      Offset(_x(2), _axisY),
      kind: PointerDeviceKind.mouse,
    );
    await g.moveTo(Offset(_x(10), _axisY));
    await tester.pump();
    expect(find.byKey(const ValueKey('pick-bubble')), findsOneWidget);
    expect(
      find.text(formatOccurrenceDate(DateTime(2026, 10, 11))),
      findsOneWidget,
    );
    expect(h.viewports, isEmpty, reason: 'axis drags must not pan');
    await g.up();
    await tester.pump();
    expect(h.created, isEmpty, reason: 'release only pins');
    expect(find.byKey(const ValueKey('pick-bubble')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pick-add')));
    await tester.pump();
    expect(h.created, [DateTime(2026, 10, 11)]);
    expect(find.byKey(const ValueKey('pick-bubble')), findsNothing);
  });

  testWidgets('dragging well above the axis cancels; back down re-arms', (
    tester,
  ) async {
    final h = await _pump(tester);
    final g = await tester.startGesture(
      Offset(_x(3), _axisY),
      kind: PointerDeviceKind.touch,
    );
    await g.moveTo(Offset(_x(3), _layout.axis.top - 120));
    await tester.pump();
    expect(find.text('Release to cancel'), findsOneWidget);
    await g.up();
    await tester.pump();
    expect(h.created, isEmpty);
    expect(find.byKey(const ValueKey('pick-bubble')), findsNothing);

    final g2 = await tester.startGesture(Offset(_x(3), _axisY));
    await g2.moveTo(Offset(_x(3), _layout.axis.top - 120));
    await g2.moveTo(Offset(_x(6), _axisY));
    await tester.pump();
    expect(find.text('Release, then tap +'), findsOneWidget);
    await g2.up();
    await tester.pump();
    expect(h.created, isEmpty);
    await tester.tap(find.byKey(const ValueKey('pick-add')));
    expect(h.created, [DateTime(2026, 10, 7)]);
  });

  testWidgets('Esc cancels a date drag', (tester) async {
    final h = await _pump(tester);
    final g = await tester.startGesture(
      Offset(_x(3), _axisY),
      kind: PointerDeviceKind.mouse,
    );
    await g.moveTo(Offset(_x(8), _axisY));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('pick-bubble')), findsNothing);
    await g.up();
    await tester.pump();
    expect(h.created, isEmpty);
  });

  testWidgets('auto-scrolls past the right and left edges', (tester) async {
    final h = await _pump(tester);
    final g = await tester.startGesture(
      Offset(_x(15), _axisY),
      kind: PointerDeviceKind.touch,
    );
    await g.moveTo(Offset(_size.width - 2, _axisY));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(h.viewStart.isAfter(_start), isTrue);
    await g.up();
    await tester.pump();
    expect(h.created, isEmpty);
    await tester.tap(find.byKey(const ValueKey('pick-add')));
    await tester.pump();
    final picked = h.created.single;
    expect(picked.isAfter(DateTime(2026, 10, 31)), isTrue);

    final startAfterRight = h.viewStart;
    final g2 = await tester.startGesture(Offset(_x(15), _axisY));
    await g2.moveTo(Offset(10, _axisY));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(h.viewStart.isBefore(startAfterRight), isTrue);
    // Moving back inside stops scrolling.
    await g2.moveTo(Offset(_x(15), _axisY));
    await tester.pump(const Duration(milliseconds: 16));
    final stopped = h.viewStart;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(h.viewStart, stopped);
    await g2.up();
    await tester.pump();
  });

  testWidgets('dragging the chart pans and never picks', (tester) async {
    final h = await _pump(tester);
    final g = await tester.startGesture(
      Offset(_x(15), 200),
      kind: PointerDeviceKind.touch,
    );
    await g.moveTo(Offset(_x(5), 200));
    await tester.pump();
    expect(find.byKey(const ValueKey('pick-bubble')), findsNothing);
    await g.up();
    await tester.pump();
    expect(h.viewStart.isAfter(_start), isTrue);
    expect(h.created, isEmpty);
  });

  testWidgets('pinch zooms time around the focus', (tester) async {
    final h = await _pump(tester);
    final a = await tester.startGesture(
      Offset(_x(10), 200),
      kind: PointerDeviceKind.touch,
      pointer: 1,
    );
    final b = await tester.startGesture(
      Offset(_x(20), 200),
      kind: PointerDeviceKind.touch,
      pointer: 2,
    );
    await a.moveTo(Offset(_x(5), 200));
    await b.moveTo(Offset(_x(25), 200));
    await tester.pump();
    expect(h.visibleDays, lessThan(_days));
    await a.up();
    await b.up();
    await tester.pump();
    expect(h.created, isEmpty);
  });

  test('auto-scroll speed scales with depth and is capped', () {
    expect(autoScrollDays(0, 30), 0);
    expect(autoScrollDays(20, 30), closeTo(7.5, 1e-9));
    expect(autoScrollDays(-40, 30), closeTo(-15, 1e-9));
    expect(autoScrollDays(400, 30), autoScrollDays(120, 30));
  });
}
