import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime(2026, 10, 1);
const _days = 30.0;
const _size = Size(1000, 500);

Future<(List<(DateTime, double)>, List<DateTime>, List<DateTime>)> _pump(
  WidgetTester tester, {
  required bool targetMode,
}) async {
  tester.view.physicalSize = _size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final targets = <(DateTime, double)>[];
  final viewports = <DateTime>[];
  final created = <DateTime>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox.fromSize(
          size: _size,
          child: BalanceChart(
            series: BalanceSeries(
              points: [
                for (var i = -30; i < 60; i++)
                  BalancePoint(
                    date: _start.add(Duration(days: i)),
                    closingBalance: Decimal.fromInt(i >= 14 ? 2000 : 1000),
                  ),
              ],
            ),
            seedDate: _start.subtract(const Duration(days: 30)),
            viewStart: _start,
            visibleDays: _days,
            onViewportChanged: (s, _) => viewports.add(s),
            onCreateOnDay: created.add,
            targetMode: targetMode,
            onTargetChanged: (d, v) => targets.add((d, v)),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return (targets, viewports, created);
}

ChartLayout get _l => ChartLayout.of(_size, _days);
double _x(int i) => _l.plot.left + (i + 0.5) / _days * _l.plot.width;
// Fitted y range: −240..2240 (see selection_mode_test).
double _y(double v) => _l.plot.bottom - (v + 240) / 2480 * _l.plot.height;

void main() {
  testWidgets('target tool: tap sets the target day and balance', (t) async {
    final (targets, viewports, created) = await _pump(t, targetMode: true);
    await t.tapAt(Offset(_x(10), _y(1500)));
    await t.pump(const Duration(milliseconds: 400));
    expect(targets, isNotEmpty);
    expect(targets.last.$1, DateTime(2026, 10, 11));
    expect(targets.last.$2, closeTo(1500, 10));
    expect(created, isEmpty, reason: 'taps never create transactions');
  });

  testWidgets('target tool: dragging moves the target, not the view', (
    t,
  ) async {
    final (targets, viewports, _) = await _pump(t, targetMode: true);
    final g = await t.startGesture(Offset(_x(5), _y(1200)));
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(Offset(_x(5 + i), _y(1200 + i * 50)));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await t.pump(const Duration(milliseconds: 400));
    expect(viewports, isEmpty);
    expect(targets.last.$1, DateTime(2026, 10, 16));
    expect(targets.last.$2, closeTo(1700, 10));
  });

  testWidgets('without the tool, drags pan as before', (t) async {
    final (targets, viewports, _) = await _pump(t, targetMode: false);
    await t.dragFrom(Offset(_x(15), _y(1500)), const Offset(-200, 0));
    await t.pump(const Duration(milliseconds: 400));
    expect(targets, isEmpty);
    expect(viewports, isNotEmpty);
  });
}
