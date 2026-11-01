// Spec 006 §4–6 at coarse zoom: group glyphs, the label budget, exact
// markers and label stability while panning.
import 'dart:math' as math;

import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/clusters.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/synthetic_series.dart';

final _seed = DateTime(2100, 1, 1);

Widget _chart(
  BalanceSeries series,
  Size size,
  DateTime viewStart,
  double days, {
  Map<String, String> names = const {},
  double lossThreshold = 0,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox.fromSize(
      size: size,
      child: BalanceChart(
        series: series,
        seedDate: _seed,
        seedBalance: series.points.first.closingBalance.toDouble(),
        lossThreshold: lossThreshold,
        viewStart: viewStart,
        visibleDays: days,
        eventNames: names,
        onViewportChanged: (_, _) {},
        onCreateOnDay: (_) {},
      ),
    ),
  ),
);

Future<void> _size(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  tearDown(() {
    debugVertexLabelKey = null;
    debugGroupGlyph = null;
    debugExactMarkers = null;
  });

  testWidgets('a lone occurrence in its period keeps its dot and label', (
    tester,
  ) async {
    const size = Size(1600, 900);
    await _size(tester, size);
    // Daily points for 35y; one occurrence every 3 years (one per bin).
    final points = <BalancePoint>[];
    final occ = <Occurrence>[];
    var bal = 100000;
    for (var i = 0; i < 12785; i++) {
      final d = DateTime(2100, 1, 1 + i);
      if (i % 1100 == 500) {
        occ.add(
          Occurrence(
            eventId: 'bonus',
            date: d,
            signedDelta: Decimal.fromInt(2500),
          ),
        );
        bal += 2500;
      }
      points.add(BalancePoint(date: d, closingBalance: Decimal.fromInt(bal)));
    }
    final labels = <String>[];
    var glyphs = 0;
    debugVertexLabelKey = (key, label, x, shown) {
      if (shown && key > 0) labels.add(label);
    };
    debugGroupGlyph = (_, _) => glyphs++;
    await tester.pumpWidget(
      _chart(
        BalanceSeries(points: points, occurrences: occ),
        size,
        _seed,
        12785,
        names: {'bonus': 'Bonus'},
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(glyphs, 0, reason: 'single occurrences never become groups');
    expect(labels, isNotEmpty);
    expect(labels.every((l) => l == 'Bonus'), isTrue);
  });

  for (final size in const [Size(1600, 900), Size(390, 844)]) {
    testWidgets('35y at ${size.width.toInt()}: group glyphs, ≤ K group '
        'labels, exact markers from the full series', (tester) async {
      await _size(tester, size);
      final s = syntheticStream(
        seedDate: _seed,
        mix: (daily: 0, weekly: 2, fortnightly: 1, monthly: 4),
        seed: 5,
      );
      final groupLabels = <int>{};
      final glyphBins = <GroupBin>[];
      List<(String, DateTime, double)> marks = const [];
      debugVertexLabelKey = (key, label, x, shown) {
        if (shown && key <= -500000000) groupLabels.add(key);
      };
      debugGroupGlyph = (b, _) => glyphBins.add(b);
      debugExactMarkers = (m) => marks = m;
      await tester.pumpWidget(
        _chart(
          s.series,
          size,
          _seed,
          12785,
          names: s.names,
          lossThreshold: s.lossThreshold,
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      final period = binPeriodFor((size.width - 80) / 12785);
      expect(glyphBins, isNotEmpty);
      expect(glyphBins.every((b) => b.period == period), isTrue);
      expect(
        groupLabels.length,
        lessThanOrEqualTo(groupLabelBudget(size.width)),
      );
      // Lowest / highest in view: the true extremes of the daily series.
      final view = [
        for (final p in s.series.points)
          if (!p.date.isBefore(_seed) &&
              p.date.isBefore(DateTime(2100, 1, 1 + 12786)))
            p,
      ];
      final lo = view.map((p) => p.closingBalance.toDouble()).reduce(math.min);
      final hi = view.map((p) => p.closingBalance.toDouble()).reduce(math.max);
      final names = {for (final m in marks) m.$1: m};
      expect(names['Lowest']!.$3, lo);
      expect(names['Highest']!.$3, hi);
      final loDay = view.firstWhere((p) => p.closingBalance.toDouble() == lo);
      expect(
        names['Lowest']!.$2,
        DateTime(loDay.date.year, loDay.date.month, loDay.date.day),
      );
    });
  }

  for (final (years, size) in const [
    (35, Size(1600, 900)),
    (35, Size(390, 844)),
    (10, Size(1600, 900)),
    (10, Size(390, 844)),
  ]) {
    testWidgets('group labels do not flicker: ${years}y at '
        '${size.width.toInt()}, 1 px per frame for 400 frames', (tester) async {
      await _size(tester, size);
      final s = syntheticStream(
        seedDate: _seed,
        mix: (daily: 0, weekly: 1, fortnightly: 1, monthly: 3),
        seed: 9,
      );
      final days = years * 365.25;
      final seen = <int, List<bool>>{};
      debugVertexLabelKey = (key, label, x, shown) {
        if (x < 130 || x > size.width - 130) return;
        (seen[key] ??= []).add(shown);
      };
      var start = DateTime(2100, 6, 1);
      Widget build() => _chart(s.series, size, start, days, names: s.names);
      await tester.pumpWidget(build());
      await tester.pump(const Duration(seconds: 1));
      seen.clear();
      final dayPerPx = days / (size.width - 80);
      for (var i = 0; i < 400; i++) {
        start = DateTime(
          2100,
          6,
          1,
        ).add(Duration(minutes: (i * dayPerPx * 1440).round()));
        await tester.pumpWidget(build());
      }
      expect(seen, isNotEmpty);
      final flicker = [
        for (final MapEntry(:key, :value) in seen.entries)
          if (value.toSet().length > 1) key,
      ];
      expect(flicker, isEmpty, reason: 'labels toggled while panning');
    });
  }
}
