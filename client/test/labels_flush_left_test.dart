// Transaction labels: no accent bar, left edge flush with the dot's left
// edge, directly above the dot or (when above has no room) directly below.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime(2031, 3, 1);

Future<List<(String, Offset, double, Rect)>> _labels(
  WidgetTester tester,
  Size size,
  List<(int day, int delta, String name)> txns, {
  double days = 30,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  final names = <String, String>{};
  final occ = <Occurrence>[];
  final points = <BalancePoint>[];
  var bal = 1000;
  for (var i = 0; i < 60; i++) {
    final d = _start.add(Duration(days: i));
    for (final (day, delta, name) in txns) {
      if (day != i) continue;
      final id = '$name$i';
      names[id] = name;
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
  final out = <(String, Offset, double, Rect)>[];
  debugVertexLabelRect = (n, c, r, rect) => out.add((n, c, r, rect));
  await tester.pumpWidget(const SizedBox());
  out.clear();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox.fromSize(
          size: size,
          child: BalanceChart(
            series: BalanceSeries(points: points, occurrences: occ),
            currency: 'AUD',
            // Seed (and Today) markers off-view, so only dots compete.
            seedDate: _start.subtract(const Duration(days: 60)),
            viewStart: _start,
            visibleDays: days,
            transactionNames: names,
            onViewportChanged: (_, _) {},
            onCreateOnDay: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  debugVertexLabelRect = null;
  return out;
}

void _expectFlush(List<(String, Offset, double, Rect)> labels, Rect plot) {
  for (final (name, c, r, rect) in labels) {
    final ctx = '$name at $c r$r: $rect';
    expect(rect.left, closeTo(c.dx - r, 0.5), reason: 'flush left: $ctx');
    final above = rect.bottom <= c.dy - r;
    final below = rect.top >= c.dy + r;
    expect(above || below, isTrue, reason: 'above or below: $ctx');
    expect(
      (above ? c.dy - r - rect.bottom : rect.top - (c.dy + r)),
      closeTo(3, 0.5),
      reason: 'directly against the dot: $ctx',
    );
    expect(rect.top, greaterThanOrEqualTo(plot.top), reason: ctx);
    expect(rect.bottom, lessThanOrEqualTo(plot.bottom), reason: ctx);
  }
}

void main() {
  tearDown(() => debugVertexLabelRect = null);

  const txns = [
    (3, 5000, 'Bonus'),
    (8, -800, 'Rent'),
    (12, -900, 'Car'),
    (18, -3200, 'Holiday'),
    (24, 1200, 'Salary'),
  ];
  // Day 3 is the balance peak (nearest the top), day 18 the trough
  // (nearest the bottom).
  for (final size in const [Size(390, 700), Size(1440, 800)]) {
    testWidgets('labels sit flush left with the dot, above it when there '
        'is room (${size.width.toInt()}px)', (tester) async {
      addTearDown(tester.view.reset);
      final labels = await _labels(tester, size, txns);
      final plot = ChartLayout.of(size, 30).plot;
      _expectFlush(labels, plot);
      final byName = {for (final (n, c, r, rect) in labels) n: (c, r, rect)};
      expect(byName.keys, containsAll(['Bonus', 'Holiday', 'Salary']));
      for (final n in ['Bonus', 'Holiday', 'Salary']) {
        final (c, r, rect) = byName[n]!;
        expect(rect.bottom, lessThanOrEqualTo(c.dy - r), reason: '$n above');
      }
    });
  }

  for (final size in const [Size(390, 300), Size(1440, 330)]) {
    testWidgets('a dot near the top gets its label below; near the bottom '
        'above (${size.width.toInt()}px short chart)', (tester) async {
      addTearDown(tester.view.reset);
      final labels = await _labels(tester, size, [
        (3, 5000, 'Bonus'),
        (18, -3200, 'Holiday'),
        (26, 1200, 'Salary'),
      ]);
      final plot = ChartLayout.of(size, 30).plot;
      _expectFlush(labels, plot);
      final byName = {for (final (n, c, r, rect) in labels) n: (c, r, rect)};
      final (pc, pr, prect) = byName['Bonus']!;
      // No room above the peak inside the plot...
      expect(pc.dy - pr - 3 - prect.height, lessThan(plot.top + 1));
      // ...so it goes directly below.
      expect(prect.top, closeTo(pc.dy + pr + 3, 0.5));
      // The trough keeps the default: directly above.
      final (tc, tr, trect) = byName['Holiday']!;
      expect(trect.bottom, closeTo(tc.dy - tr - 3, 0.5));
    });
  }

  testWidgets('crowded days stay flush left and never overlap', (tester) async {
    addTearDown(tester.view.reset);
    const size = Size(390, 700);
    final labels = await _labels(tester, size, [
      for (var d = 2; d < 28; d++) (d, d.isEven ? 400 : -350, 'Item $d'),
      (10, -50, 'Coffee'),
      (10, -20, 'Snack'),
    ]);
    expect(labels.length, greaterThan(3));
    _expectFlush(labels, ChartLayout.of(size, 30).plot);
    for (var i = 0; i < labels.length; i++) {
      for (var j = i + 1; j < labels.length; j++) {
        expect(
          labels[i].$4.overlaps(labels[j].$4),
          isFalse,
          reason: '${labels[i].$1} overlaps ${labels[j].$1}',
        );
      }
    }
  });
}
