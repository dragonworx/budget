import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/selection_period.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime(2026, 10, 1);
const _days = 30.0;
const _size = Size(1000, 500);

class _H {
  DateTime viewStart = _start;
  double visibleDays = _days;
  final viewports = <DateTime>[];
  final created = <DateTime>[];
  final planned = <PeriodSummary>[];
}

/// Balance 1000 until 15 Oct, where a +1000 credit (one dot) lifts it to
/// 2000. Fitted y range: paddedRange(1000, 2000, include 0) = −240..2240.
Future<_H> _pump(WidgetTester tester) async {
  tester.view.physicalSize = _size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = _H();
  final points = [
    for (var i = -30; i < 60; i++)
      BalancePoint(
        date: _start.add(Duration(days: i)),
        closingBalance: Decimal.fromInt(i >= 14 ? 2000 : 1000),
      ),
  ];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SizedBox.fromSize(
            size: _size,
            child: BalanceChart(
              series: BalanceSeries(
                points: points,
                occurrences: [
                  Occurrence(
                    transactionId: 'bonus',
                    date: DateTime(2026, 10, 15),
                    signedDelta: Decimal.fromInt(1000),
                  ),
                ],
              ),
              transactionNames: const {'bonus': 'Bonus'},
              currency: 'AUD',
              seedDate: _start.subtract(const Duration(days: 30)),
              viewStart: h.viewStart,
              visibleDays: h.visibleDays,
              onViewportChanged: (s, d) => setState(() {
                h.viewStart = s;
                h.visibleDays = d;
                h.viewports.add(s);
              }),
              onCreateOnDay: h.created.add,
              onPlanPeriod: h.planned.add,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return h;
}

ChartLayout get _l => ChartLayout.of(_size, _days);
double _x(int i) => _l.plot.left + (i + 0.5) / _days * _l.plot.width;
double _y(double v) => _l.plot.bottom - (v + 240) / 2480 * _l.plot.height;
double get _dayPx => _l.plot.width / _days;

final _card = find.byKey(const ValueKey('selection-card'));
final _tip = find.byKey(const ValueKey('occurrence-tooltip'));
String _range(WidgetTester t) =>
    t.widget<Text>(find.byKey(const ValueKey('selection-range'))).data!;
String _txt(WidgetTester t, String k) =>
    t.widget<Text>(find.byKey(ValueKey(k))).data!;

Future<TestGesture> _hold(
  WidgetTester tester,
  Offset p, {
  PointerDeviceKind kind = PointerDeviceKind.touch,
}) async {
  final g = await tester.startGesture(p, kind: kind);
  await tester.pump(const Duration(milliseconds: 520));
  return g;
}

Future<void> _select(WidgetTester tester, int from, int to) async {
  final g = await _hold(tester, Offset(_x(from), _y(1600)));
  await g.moveTo(Offset(_x(to), _y(1600)));
  await tester.pump();
  await g.up();
  await tester.pump();
}

Future<void> _drag(WidgetTester tester, String key, double dx) async {
  final f = find.byKey(ValueKey(key));
  final g = await tester.startGesture(tester.getCenter(f));
  for (var i = 1; i <= 10; i++) {
    await g.moveBy(Offset(dx / 10, 0));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await tester.pump();
}

void main() {
  testWidgets('selection card Plan… hands over the range, edits nothing', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _select(tester, 5, 20);
    final plan = find.byKey(const ValueKey('sel-plan'));
    expect(plan, findsOneWidget);
    await tester.ensureVisible(plan);
    await tester.tap(plan);
    await tester.pump();
    expect(h.planned, hasLength(1));
    expect(h.planned.single.start, DateTime(2026, 10, 6));
    expect(h.planned.single.end, DateTime(2026, 10, 21));
    expect(h.planned.single.startBalance, 1000);
    expect(h.created, isEmpty);
  });

  testWidgets('hold in empty space selects; drag while held extends', (
    tester,
  ) async {
    final h = await _pump(tester);
    final g = await _hold(tester, Offset(_x(4), _y(1600)));
    expect(_card, findsOneWidget);
    expect(_range(tester), '5 Oct 2026');
    await g.moveTo(Offset(_x(19), _y(1600)));
    await tester.pump();
    await g.up();
    await tester.pump();
    expect(_range(tester), '5 Oct – 20 Oct 2026');
    expect(_txt(tester, 'selection-start-balance'), contains('1,000'));
    expect(_txt(tester, 'selection-end-balance'), contains('2,000'));
    expect(_txt(tester, 'selection-gains'), contains('1,000'));
    expect(_txt(tester, 'selection-losses'), contains('0'));
    expect(_txt(tester, 'selection-net'), startsWith('+'));
    expect(find.text('Bonus'), findsNothing, reason: 'totals only, no list');
    expect(_txt(tester, 'selection-count'), '1');
    // 30 Sep-wide view = day precision: 5..20 Oct inclusive.
    expect(_txt(tester, 'selection-duration'), '2 Weeks, 2 Days');
    expect(h.viewports, isEmpty, reason: 'selecting never pans');
    expect(h.created, isEmpty);
  });

  testWidgets('hold in the fill under the line selects', (tester) async {
    await _pump(tester);
    final g = await _hold(tester, Offset(_x(4), _y(400)));
    expect(_card, findsOneWidget);
    await g.up();
  });

  testWidgets('hold on the line stroke does not select', (tester) async {
    await _pump(tester);
    for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      final dy = kind == PointerDeviceKind.touch ? 10.0 : 5.0;
      final g = await _hold(tester, Offset(_x(4), _y(1000) - dy), kind: kind);
      expect(_card, findsNothing);
      expect(_tip, findsNothing);
      await g.up();
      await tester.pump(const Duration(seconds: 6));
    }
  });

  testWidgets('hold near a dot shows its info, not a selection', (
    tester,
  ) async {
    await _pump(tester);
    final dot = Offset(_x(14), _y(2000));
    final g = await _hold(tester, dot + const Offset(-20, -25));
    expect(_card, findsNothing);
    expect(_tip, findsOneWidget);
    await g.up();
    await tester.pump();
    expect(_tip, findsOneWidget, reason: 'still pinned after lift');
  });

  testWidgets('mouse press-hold in empty space selects', (tester) async {
    await _pump(tester);
    final g = await _hold(
      tester,
      Offset(_x(8), _y(400)),
      kind: PointerDeviceKind.mouse,
    );
    expect(_card, findsOneWidget);
    await g.up();
  });

  testWidgets('quick tap and early drag do not select', (tester) async {
    final h = await _pump(tester);
    await tester.tapAt(Offset(_x(4), _y(1600)));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_card, findsNothing);
    await tester.dragFrom(Offset(_x(10), _y(1600)), const Offset(-120, 0));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_card, findsNothing);
    expect(h.viewports, isNotEmpty, reason: 'drag from empty space pans');
  });

  testWidgets('drag the end, start and body', (tester) async {
    await _pump(tester);
    await _select(tester, 4, 9);
    expect(_range(tester), '5 Oct – 10 Oct 2026');
    await _drag(tester, 'selection-end', 5 * _dayPx);
    expect(_range(tester), '5 Oct – 15 Oct 2026');
    await _drag(tester, 'selection-start', -2 * _dayPx);
    expect(_range(tester), '3 Oct – 15 Oct 2026');
    await _drag(tester, 'selection-body', 3 * _dayPx);
    expect(_range(tester), '6 Oct – 18 Oct 2026');
    // Start dragged past the end swaps the edges.
    await _drag(tester, 'selection-start', 15 * _dayPx);
    expect(_range(tester), '18 Oct – 21 Oct 2026');
  });

  testWidgets('only the close button dismisses; taps and navigation keep it', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _select(tester, 4, 6);
    final range = _range(tester);
    await tester.tapAt(Offset(_x(25), _y(1600)));
    await tester.pump();
    expect(_card, findsOneWidget, reason: 'tap outside keeps it');
    expect(_tip, findsNothing);

    final mouse = TestPointer(9, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(Offset(_x(20), _y(400))));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 50)));
    await tester.pump();
    expect(h.viewports, isNotEmpty);
    expect(_card, findsOneWidget, reason: 'wheel zoom keeps it');
    expect(_range(tester), range);

    await tester.tap(find.byKey(const ValueKey('selection-close')));
    await tester.pump();
    expect(_card, findsNothing);
    expect(find.byKey(const ValueKey('selection-band')), findsNothing);
  });

  testWidgets('drag inside the band moves it without panning', (tester) async {
    final h = await _pump(tester);
    await _select(tester, 4, 9);
    // Inside the band (not on a handle), touch and no hold.
    final g = await tester.startGesture(
      Offset(_x(7), _y(1600)),
      kind: PointerDeviceKind.touch,
    );
    for (var i = 1; i <= 10; i++) {
      await g.moveBy(Offset(4 * _dayPx / 10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump();
    expect(_range(tester), '9 Oct – 14 Oct 2026');
    expect(h.viewports, isEmpty, reason: 'x-range unchanged');
    // A tap inside does nothing.
    await tester.tapAt(Offset(_x(11), _y(1600)));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_range(tester), '9 Oct – 14 Oct 2026');
  });

  testWidgets('drag outside pans and keeps the selection dates', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _select(tester, 4, 9);
    final before = tester.getRect(find.byKey(const ValueKey('selection-band')));
    final g = await tester.startGesture(
      Offset(_x(27), _y(1600)),
      kind: PointerDeviceKind.touch,
    );
    for (var i = 1; i <= 10; i++) {
      await g.moveBy(Offset(-3 * _dayPx / 10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump(const Duration(milliseconds: 600));
    expect(h.viewports, isNotEmpty, reason: 'panned');
    expect(_card, findsOneWidget);
    expect(_range(tester), '5 Oct – 10 Oct 2026');
    final after = tester.getRect(find.byKey(const ValueKey('selection-band')));
    expect(after.left - before.left, closeTo(-3 * _dayPx, 2));
    expect(_tip, findsNothing);
  });

  testWidgets('card drags by its header, clamps, persists, resets', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _select(tester, 4, 8);
    final before = tester.getTopLeft(_card);
    final range = _range(tester);
    await _drag(tester, 'selection-card-handle', -120);
    final after = tester.getTopLeft(_card);
    expect(after.dx, closeTo(before.dx - 120, 1));
    expect(_range(tester), range, reason: 'selection did not move');
    expect(h.viewports, isEmpty, reason: 'card drag never pans');
    // Far drag clamps inside the chart.
    await _drag(tester, 'selection-card-handle', -5000);
    expect(tester.getTopLeft(_card).dx, greaterThanOrEqualTo(0));
    // Park it far right, clear of the selection's edge handles.
    await _drag(tester, 'selection-card-handle', 5000);
    expect(tester.getTopRight(_card).dx, lessThanOrEqualTo(_size.width));
    final parked = tester.getTopLeft(_card);
    // Selection edge drag keeps the card where the user put it.
    await _drag(tester, 'selection-end', 3 * _dayPx);
    expect(tester.getTopLeft(_card), parked);
    // Close, reselect: default placement again.
    await tester.tap(find.byKey(const ValueKey('selection-close')));
    await tester.pump();
    await _select(tester, 4, 8);
    expect(tester.getTopLeft(_card), before);
  });

  testWidgets('card drags from any point: stats, count row; close still taps', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _select(tester, 4, 19);
    final range = _range(tester);
    Future<void> dragFrom(Finder f, Offset by) async {
      final g = await tester.startGesture(tester.getCenter(f));
      for (var i = 1; i <= 10; i++) {
        await g.moveBy(by / 10);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump();
    }

    var at = tester.getTopLeft(_card);
    await dragFrom(
      find.byKey(const ValueKey('sel-row-gains')),
      const Offset(-80, 30),
    );
    expect(tester.getTopLeft(_card), at + const Offset(-80, 30));
    at = tester.getTopLeft(_card);
    await dragFrom(find.byKey(const ValueKey('sel-row-count')), const Offset(-40, 20));
    expect(tester.getTopLeft(_card), at + const Offset(-40, 20));
    expect(_range(tester), range);
    expect(h.viewports, isEmpty, reason: 'card drag never pans');
    expect(h.created, isEmpty);
    await tester.tap(find.byKey(const ValueKey('selection-close')));
    await tester.pump();
    expect(_card, findsNothing);
  });

  testWidgets('card shrink-wraps its content width', (tester) async {
    await _pump(tester);
    await _select(tester, 4, 19);
    final w = tester.getSize(_card).width;
    // Test font (Ahem) is wide; real fonts measure far narrower.
    expect(w, lessThan(400));
    expect(w, lessThanOrEqualTo(_size.width * 0.85));
  });
}
