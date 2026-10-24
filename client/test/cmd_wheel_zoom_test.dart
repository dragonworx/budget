// The wheel pans (vertical → $ axis, horizontal / Shift → time); Cmd, Option
// or Ctrl + wheel scales about the pointer: vertical delta → the $ axis (the
// balance under the pointer stays put), horizontal delta → the time axis (the
// date under the pointer stays put). A trackpad pinch zooms time there.
import 'dart:math' as math;

import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime(2031, 3, 1);

class _Host extends StatefulWidget {
  const _Host(this.log);
  final List<(DateTime, double)> log;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  DateTime start = _start;
  double days = 30;
  BalanceExtents? y;

  void shiftDays(double n) => setState(() => start = addDays(start, n));

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 1440,
        height: 800,
        child: BalanceChart(
          series: BalanceSeries(
            points: [
              for (var i = 0; i < 400; i++)
                BalancePoint(
                  date: _start.add(Duration(days: i)),
                  closingBalance: Decimal.fromInt(1000 + (i % 30) * 40),
                ),
            ],
          ),
          seedDate: _start.subtract(const Duration(days: 30)),
          viewStart: start,
          visibleDays: days,
          onViewportChanged: (s, d) => setState(() {
            start = s;
            days = d;
            widget.log.add((s, d));
          }),
          onYRangeChanged: (r) => y = r,
          onCreateOnDay: (_) {},
        ),
      ),
    ),
  );
}

void main() {
  late List<(DateTime, double)> log;

  Future<_HostState> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    log = [];
    await tester.pumpWidget(_Host(log));
    await tester.pump();
    return tester.state<_HostState>(find.byType(_Host));
  }

  dynamic chart(WidgetTester tester) => tester.state(find.byType(BalanceChart));
  BalanceExtents yRange(WidgetTester tester) =>
      chart(tester).debugYRange as BalanceExtents;

  Future<void> wheel(
    WidgetTester tester,
    Offset at,
    Offset delta, {
    LogicalKeyboardKey? key = LogicalKeyboardKey.metaLeft,
  }) async {
    if (key != null) await tester.sendKeyDownEvent(key);
    final p = TestPointer(7, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(p.hover(at));
    await tester.sendEventToBinding(p.scroll(delta));
    if (key != null) await tester.sendKeyUpEvent(key);
    await tester.pump();
  }

  double valueAt(WidgetTester tester, BalanceExtents r, double y) {
    final plot = ChartLayout.of(const Size(1440, 800), 30).plot;
    return r.min + (plot.bottom - y) / plot.height * (r.max - r.min);
  }

  double dayAt(_HostState s, double x) {
    final plot = ChartLayout.of(const Size(1440, 800), 30).plot;
    return dayCoord(s.start) + (x - plot.left) / plot.width * s.days;
  }

  testWidgets('Cmd + vertical wheel scales the \$ axis about the pointer', (
    tester,
  ) async {
    final s = await pump(tester);
    final origin = tester.getTopLeft(find.byType(BalanceChart));
    final before = yRange(tester);
    final at = const Offset(700, 300);
    final v0 = valueAt(tester, before, at.dy);
    await wheel(tester, origin + at, const Offset(0, 200));
    final out = yRange(tester);
    expect(out.max - out.min, greaterThan(before.max - before.min));
    expect(valueAt(tester, out, at.dy), closeTo(v0, 1e-6), reason: 'fixed');
    expect(
      (out.max - out.min) / (before.max - before.min),
      closeTo(math.exp(200 * 0.0016), 1e-9),
    );
    expect(log, isEmpty, reason: 'the time axis is untouched');
    expect(s.days, 30);
    // And back in, about a different point.
    final at2 = const Offset(400, 600);
    final v1 = valueAt(tester, out, at2.dy);
    await wheel(tester, origin + at2, const Offset(0, -200));
    final inn = yRange(tester);
    expect(inn.max - inn.min, lessThan(out.max - out.min));
    expect(valueAt(tester, inn, at2.dy), closeTo(v1, 1e-6));
    expect(log, isEmpty);
  });

  testWidgets('Cmd + horizontal wheel scales the time axis about the pointer', (
    tester,
  ) async {
    final s = await pump(tester);
    final origin = tester.getTopLeft(find.byType(BalanceChart));
    final y0 = yRange(tester);
    const at = Offset(900, 300);
    final d0 = dayAt(s, at.dx);
    await wheel(tester, origin + at, const Offset(200, 0));
    expect(s.days, greaterThan(30), reason: 'positive zooms out');
    expect(dayAt(s, at.dx), closeTo(d0, 1e-6), reason: 'date fixed');
    final y1 = yRange(tester);
    expect(y1.min, y0.min);
    expect(y1.max, y0.max, reason: 'the \$ axis is untouched');
    final wide = s.days;
    final d1 = dayAt(s, at.dx);
    await wheel(tester, origin + at, const Offset(-300, 0));
    expect(s.days, lessThan(wide));
    expect(dayAt(s, at.dx), closeTo(d1, 1e-6));
  });

  testWidgets('both deltas at once scale both axes about the pointer', (
    tester,
  ) async {
    final s = await pump(tester);
    final origin = tester.getTopLeft(find.byType(BalanceChart));
    final y0 = yRange(tester);
    const at = Offset(500, 450);
    final d0 = dayAt(s, at.dx), v0 = valueAt(tester, y0, at.dy);
    await wheel(tester, origin + at, const Offset(-150, -180));
    expect(s.days, lessThan(30));
    final y1 = yRange(tester);
    expect(y1.max - y1.min, lessThan(y0.max - y0.min));
    expect(dayAt(s, at.dx), closeTo(d0, 1e-6));
    expect(valueAt(tester, y1, at.dy), closeTo(v0, 1e-6));
  });

  testWidgets('a small drift on the other axis is ignored', (tester) async {
    final s = await pump(tester);
    final origin = tester.getTopLeft(find.byType(BalanceChart));
    await wheel(tester, origin + const Offset(700, 300), const Offset(4, 200));
    expect(s.days, 30);
    expect(log, isEmpty);
  });

  testWidgets('the zoom stays within the limits', (tester) async {
    final s = await pump(tester);
    final origin = tester.getTopLeft(find.byType(BalanceChart));
    for (var i = 0; i < 40; i++) {
      await wheel(
        tester,
        origin + const Offset(700, 300),
        const Offset(400, 400),
      );
    }
    expect(s.days, maxVisibleDays);
    final r = yRange(tester);
    expect(r.max - r.min, lessThanOrEqualTo(maxBalanceSpan));
    for (var i = 0; i < 80; i++) {
      await wheel(
        tester,
        origin + const Offset(700, 300),
        const Offset(-400, -400),
      );
    }
    expect(s.days, minVisibleDays);
    final n = yRange(tester);
    expect(n.max - n.min, greaterThanOrEqualTo(minBalanceSpan - 1e-4));
  });

  testWidgets('the y change is a deliberate range: it survives a refresh', (
    tester,
  ) async {
    final s = await pump(tester);
    final origin = tester.getTopLeft(find.byType(BalanceChart));
    await wheel(tester, origin + const Offset(700, 300), const Offset(0, -300));
    final zoomed = yRange(tester);
    s.shiftDays(3);
    await tester.pump();
    final after = yRange(tester);
    expect(after.min, zoomed.min);
    expect(after.max, zoomed.max);
  });

  for (final key in [
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.controlLeft,
  ]) {
    testWidgets('${key.keyLabel} + wheel scales about the pointer on both '
        'axes', (tester) async {
      final s = await pump(tester);
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      final y0 = yRange(tester);
      const at = Offset(1100, 220);
      final v0 = valueAt(tester, y0, at.dy);
      await wheel(tester, origin + at, const Offset(0, 150), key: key);
      final y1 = yRange(tester);
      expect(y1.max - y1.min, greaterThan(y0.max - y0.min));
      expect(valueAt(tester, y1, at.dy), closeTo(v0, 1e-6));
      expect(s.days, 30, reason: 'vertical delta: \$ axis only');
      final d0 = dayAt(s, at.dx);
      await wheel(tester, origin + at, const Offset(-150, 0), key: key);
      expect(s.days, lessThan(30));
      expect(dayAt(s, at.dx), closeTo(d0, 1e-6), reason: 'date fixed');
    });
  }

  testWidgets('plain vertical wheel pans the \$ axis, no scaling', (
    tester,
  ) async {
    final s = await pump(tester);
    final origin = tester.getTopLeft(find.byType(BalanceChart));
    final y0 = yRange(tester);
    final span = y0.max - y0.min;
    final plot = ChartLayout.of(const Size(1440, 800), 30).plot;
    await wheel(
      tester,
      origin + const Offset(300, 300),
      const Offset(0, 100),
      key: null,
    );
    await tester.pump(const Duration(milliseconds: 600));
    final y1 = yRange(tester);
    expect(y1.max - y1.min, closeTo(span, 1e-6), reason: 'no scale');
    expect(
      y1.min,
      closeTo(y0.min - 100 / plot.height * span, 1e-6),
      reason: 'wheel down shows lower balances',
    );
    expect(s.days, 30);
    expect(log, isEmpty, reason: 'time untouched');
    await wheel(
      tester,
      origin + const Offset(900, 600),
      const Offset(0, -100),
      key: null,
    );
    expect(yRange(tester).min, closeTo(y0.min, 1e-6));
    // Deliberate: survives a refresh.
    s.shiftDays(2);
    await tester.pump();
    expect(yRange(tester).min, closeTo(y0.min, 1e-6));
  });

  testWidgets('horizontal wheel and Shift+vertical wheel pan time', (
    tester,
  ) async {
    final s = await pump(tester);
    final origin = tester.getTopLeft(find.byType(BalanceChart));
    final y0 = yRange(tester);
    final plot = ChartLayout.of(const Size(1440, 800), 30).plot;
    final start = dayCoord(s.start);
    await wheel(
      tester,
      origin + const Offset(300, 300),
      const Offset(200, 0),
      key: null,
    );
    expect(s.days, 30, reason: 'pans, no zoom');
    expect(dayCoord(s.start) - start, closeTo(200 / plot.width * 30, 1e-6));
    await wheel(
      tester,
      origin + const Offset(300, 300),
      const Offset(0, -200),
      key: LogicalKeyboardKey.shiftLeft,
    );
    expect(dayCoord(s.start), closeTo(start, 1e-6));
    expect(s.days, 30);
    final y1 = yRange(tester);
    expect(y1.min, y0.min, reason: 'Shift: the \$ axis stays');
    expect(y1.max, y0.max);
  });

  Future<void> pinch(
    WidgetTester tester,
    Offset at,
    double scale, {
    LogicalKeyboardKey? key,
  }) async {
    if (key != null) await tester.sendKeyDownEvent(key);
    final p = TestPointer(8, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(p.hover(at));
    await tester.sendEventToBinding(p.scale(scale));
    if (key != null) await tester.sendKeyUpEvent(key);
    await tester.pump();
  }

  testWidgets('trackpad pinch (browser Ctrl+wheel scale) zooms time about '
      'the pointer, every event', (tester) async {
    final s = await pump(tester);
    final origin = tester.getTopLeft(find.byType(BalanceChart));
    final y0 = yRange(tester);
    const at = Offset(1000, 400);
    final d0 = dayAt(s, at.dx);
    for (var i = 0; i < 5; i++) {
      await pinch(tester, origin + at, 1.05);
    }
    expect(s.days, closeTo(30 / math.pow(1.05, 5), 1e-6));
    expect(dayAt(s, at.dx), closeTo(d0, 1e-6));
    expect(yRange(tester).min, y0.min);
    for (var i = 0; i < 5; i++) {
      await pinch(tester, origin + at, 1 / 1.05);
    }
    expect(s.days, closeTo(30, 1e-6));
    expect(dayAt(s, at.dx), closeTo(d0, 1e-6));
  });

  testWidgets('several wheel / pinch events in one frame compound', (
    tester,
  ) async {
    final s = await pump(tester);
    final origin = tester.getTopLeft(find.byType(BalanceChart));
    const at = Offset(800, 400);
    final d0 = dayAt(s, at.dx);
    final p = TestPointer(8, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(p.hover(origin + at));
    for (var i = 0; i < 4; i++) {
      await tester.sendEventToBinding(p.scale(1.1));
    }
    await tester.pump();
    expect(s.days, closeTo(30 / math.pow(1.1, 4), 1e-6));
    expect(dayAt(s, at.dx), closeTo(d0, 1e-6));
    final start = dayCoord(s.start), days = s.days;
    final plot = ChartLayout.of(const Size(1440, 800), 30).plot;
    for (var i = 0; i < 3; i++) {
      await tester.sendEventToBinding(p.scroll(const Offset(100, 0)));
    }
    await tester.pump();
    expect(dayCoord(s.start) - start, closeTo(300 / plot.width * days, 1e-6));
  });

  testWidgets('a real Ctrl key + scale signal (Windows Ctrl+wheel) scales '
      'the \$ axis like Cmd+wheel', (tester) async {
    final s = await pump(tester);
    final origin = tester.getTopLeft(find.byType(BalanceChart));
    final y0 = yRange(tester);
    const at = Offset(600, 500);
    final v0 = valueAt(tester, y0, at.dy);
    await pinch(
      tester,
      origin + at,
      math.exp(-100 / 200),
      key: LogicalKeyboardKey.controlLeft,
    );
    final y1 = yRange(tester);
    expect(
      (y1.max - y1.min) / (y0.max - y0.min),
      closeTo(math.exp(100 * 0.0016), 1e-9),
    );
    expect(valueAt(tester, y1, at.dy), closeTo(v0, 1e-6));
    expect(s.days, 30);
  });
}
