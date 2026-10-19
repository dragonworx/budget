import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime(2031, 3, 1);

void main() {
  testWidgets('labels do not flicker while panning in small steps', (
    tester,
  ) async {
    const size = Size(390, 600);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final names = <String, String>{};
    final occ = <Occurrence>[];
    final points = <BalancePoint>[];
    var bal = 3000;
    for (var i = -60; i < 120; i++) {
      final d = _start.add(Duration(days: i));
      final r = (i * 7919) % 11;
      if (r < 4) {
        final id = 't$i';
        final delta = r.isEven ? 2400 - r * 300 : -(180 + r * 90);
        names[id] = '${['Salary', 'Groceries', 'Rent', 'Car rego'][r]} $i';
        occ.add(
          Occurrence(
            transactionId: id,
            date: d,
            signedDelta: Decimal.fromInt(delta),
          ),
        );
        bal += delta;
      }
      points.add(BalancePoint(date: d, closingBalance: Decimal.fromInt(bal)));
    }
    var viewStart = _start;
    Widget build() => MaterialApp(
      home: Scaffold(
        body: SizedBox.fromSize(
          size: size,
          child: BalanceChart(
            series: BalanceSeries(points: points, occurrences: occ),
            currency: 'AUD',
            seedDate: _start.subtract(const Duration(days: 60)),
            viewStart: viewStart,
            visibleDays: 30,
            transactionNames: names,
            onViewportChanged: (_, _) {},
            onCreateOnDay: (_) {},
          ),
        ),
      ),
    );
    // name -> per-frame visibility, only while the dot is well inside the
    // plot (edges legitimately add or drop labels).
    final seen = <String, List<bool>>{};
    debugVertexLabel = (name, x, labelled) {
      if (x < 90 || x > size.width - 90) return;
      (seen[name] ??= []).add(labelled);
    };
    addTearDown(() => debugVertexLabel = null);
    await tester.pumpWidget(build());
    await tester.pump(const Duration(seconds: 1));
    seen.clear();
    // Pan 0.05 day (~0.65 px) per frame across 20 days.
    for (var i = 0; i < 400; i++) {
      viewStart = _start.add(Duration(minutes: (i * 0.05 * 1440).round()));
      await tester.pumpWidget(build());
    }
    expect(seen.length, greaterThan(10));
    final flicker = <String>[
      for (final MapEntry(:key, :value) in seen.entries)
        if (value.toSet().length > 1) key,
    ];
    expect(
      flicker,
      isEmpty,
      reason: 'label visibility changed while its dot was mid-plot',
    );
  });
}
