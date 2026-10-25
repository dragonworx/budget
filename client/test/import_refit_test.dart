import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Regression: an import into a stream whose line was flat at $0 left the
// balance range fitted to the flat line (±$1), so the imported bills drew
// off the plot (no dots, "flat" graph) while the heat map showed them.

final _seed = DateTime(2026, 10, 1);
final _today = DateTime(2026, 10, 22);

BalanceSeries _flat() => BalanceSeries(
  points: [
    for (var i = 0; i < 90; i++)
      BalancePoint(
        date: _seed.add(Duration(days: i)),
        closingBalance: Decimal.zero,
      ),
  ],
);

/// Ali's Bills import: three bills on the selected day, one 6 days later,
/// monthly (−$933.00, then −$89.99).
BalanceSeries _bills({double base = 0}) {
  final points = <BalancePoint>[];
  for (var i = 0; i < 90; i++) {
    final d = _seed.add(Duration(days: i));
    var v = base;
    for (var m = 0; m < 3; m++) {
      if (!d.isBefore(DateTime(2026, 10 + m, 22))) v -= 933.0;
      if (!d.isBefore(DateTime(2026, 10 + m, 28))) v -= 89.99;
    }
    points.add(
      BalancePoint(
        date: d,
        closingBalance: Decimal.parse(v.toStringAsFixed(2)),
      ),
    );
  }
  return BalanceSeries(points: points);
}

class _H {
  BalanceSeries series = _flat();
  int fitToken = 0;
  BalanceExtents? restore;
  int restoreToken = 0;
  int edit = 0;
  late StateSetter set;
}

Future<_H> _pump(WidgetTester tester, {BalanceExtents? restore}) async {
  tester.view.physicalSize = const Size(1000, 500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = _H()..restore = restore;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            h.set = setState;
            return SizedBox(
              width: 1000,
              height: 500,
              child: BalanceChart(
                series: h.series,
                seedDate: _seed,
                seedBalance: 0,
                currencyScale: 100,
                viewStart: _today.subtract(const Duration(days: 7)),
                visibleDays: 30,
                fitToken: h.fitToken,
                restoreYRange: h.restore,
                yRestoreToken: h.restoreToken,
                dataEditToken: h.edit,
                onViewportChanged: (_, _) {},
                onCreateOnDay: (_) {},
              ),
            );
          },
        ),
      ),
    ),
  );
  await tester.pump();
  return h;
}

BalanceExtents _y(WidgetTester tester) =>
    (tester.state(find.byType(BalanceChart)) as dynamic).debugYRange
        as BalanceExtents;

Future<void> _update(WidgetTester tester, _H h, void Function() f) async {
  h.set(f);
  await tester.pump();
}

void main() {
  testWidgets('a fit of a line flat at \$0 uses the currency scale, not ±\$1', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _update(tester, h, () => h.fitToken++); // e.g. Go to today
    final y = _y(tester);
    expect(y.max - y.min, greaterThanOrEqualTo(100));
    expect(y.min, lessThan(0));
  });

  testWidgets('importing bills into a flat stream refits so the line shows', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _update(tester, h, () => h.fitToken++);
    // The import's refetched balance arrives.
    await _update(
      tester,
      h,
      () => h
        ..edit += 1
        ..series = _bills(),
    );
    final y = _y(tester);
    // The whole visible line (down to both bill dates) is in range.
    expect(y.min, lessThanOrEqualTo(-(933 + 89.99)));
    expect(y.max, greaterThanOrEqualTo(0));
  });

  testWidgets('…also from the opening (currency-scale) range', (tester) async {
    final h = await _pump(tester);
    final before = _y(tester);
    await _update(
      tester,
      h,
      () => h
        ..edit += 1
        ..series = _bills(),
    );
    expect(_y(tester).min, lessThan(before.min));
    expect(_y(tester).min, lessThanOrEqualTo(-(933 + 89.99)));
  });

  testWidgets('a change that still fits keeps the range', (tester) async {
    final h = await _pump(tester);
    await _update(
      tester,
      h,
      () => h
        ..edit += 1
        ..series = _bills(),
    );
    final y = _y(tester);
    await _update(
      tester,
      h,
      () => h
        ..edit += 1
        ..series = _bills(base: 50),
    );
    expect(_y(tester).min, y.min);
    expect(_y(tester).max, y.max);
  });

  testWidgets('a sync from someone else (no edit here) keeps the range', (
    tester,
  ) async {
    final h = await _pump(tester);
    final y = _y(tester);
    h.set(() => h.series = _bills());
    await tester.pump();
    expect(_y(tester).min, y.min);
    expect(_y(tester).max, y.max);
  });

  testWidgets('the edit waits for its refreshed balance', (tester) async {
    final h = await _pump(tester);
    final y = _y(tester);
    // Token first (the refetch is in flight; the same line is redrawn) …
    h.set(
      () => h
        ..edit += 1
        ..series = _flat(),
    );
    await tester.pump();
    expect(_y(tester).min, y.min);
    // … then the new balance arrives.
    h.set(() => h.series = _bills());
    await tester.pump();
    expect(_y(tester).min, lessThanOrEqualTo(-(933 + 89.99)));
  });

  testWidgets('a balance range the line was already outside is kept (the '
      'user panned / zoomed it)', (tester) async {
    const chosen = BalanceExtents(5000, 6000);
    final h = await _pump(tester, restore: chosen);
    await _update(
      tester,
      h,
      () => h
        ..edit += 1
        ..series = _bills(base: 10000),
    );
    await _update(
      tester,
      h,
      () => h
        ..edit += 1
        ..series = _bills(base: 9000),
    );
    expect(_y(tester).min, chosen.min);
    expect(_y(tester).max, chosen.max);
  });

  testWidgets('a saved range that fitted the flat line (±\$1) is dropped '
      'once the imported data is in view', (tester) async {
    await _pump(tester, restore: const BalanceExtents(-1, 1));
    // Reopened after the import: the data is already there.
    await tester.pumpWidget(const SizedBox());
    final h2 = _H();
    tester.view.physicalSize = const Size(1000, 500);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 500,
            child: BalanceChart(
              series: _bills(),
              seedDate: _seed,
              seedBalance: 0,
              currencyScale: 100,
              viewStart: _today.subtract(const Duration(days: 7)),
              visibleDays: 30,
              restoreYRange: const BalanceExtents(-1, 1),
              yRestoreToken: h2.restoreToken,
              onViewportChanged: (_, _) {},
              onCreateOnDay: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_y(tester).min, lessThanOrEqualTo(-(933 + 89.99)));
  });

  testWidgets('a saved zoom on the balance axis is kept on reopen', (
    tester,
  ) async {
    // Line spans about −$1,023…$0 here; a saved −$1,500…−$500 zoom stays.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 500,
            child: BalanceChart(
              series: _bills(),
              seedDate: _seed,
              seedBalance: 0,
              currencyScale: 100,
              viewStart: _today.subtract(const Duration(days: 7)),
              visibleDays: 30,
              restoreYRange: const BalanceExtents(-1500, -500),
              onViewportChanged: (_, _) {},
              onCreateOnDay: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_y(tester).min, -1500);
    expect(_y(tester).max, -500);
  });
}
