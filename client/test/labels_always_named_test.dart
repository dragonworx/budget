// Every event label that is drawn shows the day total AND at least one
// event name: never the amount alone, never just "+N more". Checked
// across widths × heights × zooms on crowded data, together with the label
// rules (flush left with the dot, never overlapping, never covering a dot).
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime(2031, 3, 1);

const _long = [
  'Monthly streaming subscription',
  'Car insurance (comprehensive)',
  'Groceries',
  'Electricity and gas bill',
  'Coffee',
  'Salary',
];

/// Crowded data: an event most days, several on some days, long names.
List<(int, int, String)> _crowded(int days) => [
  for (var d = 0; d < days; d++) ...[
    if (d % 4 != 3)
      (d, d % 7 == 0 ? 2400 : -(40 + (d * 37) % 400), '${_long[d % 6]} $d'),
    if (d % 3 == 0) (d, -25, 'Extra $d'),
    if (d % 5 == 0) (d, -60, 'Lunch with the team $d'),
    if (d % 10 == 0) (d, 120, 'Refund $d'),
  ],
];

typedef _Label = (List<String> lines, Rect rect, Offset? center, double r);

Future<List<_Label>> _labels(
  WidgetTester tester,
  Size size,
  List<(int, int, String)> txns,
  double days,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  final names = <String, String>{};
  final occ = <Occurrence>[];
  final points = <BalancePoint>[];
  var bal = 3000;
  for (var i = 0; i < 400; i++) {
    final d = _start.add(Duration(days: i));
    for (final (day, delta, name) in txns) {
      if (day != i) continue;
      names[name] = name;
      occ.add(
        Occurrence(eventId: name, date: d, signedDelta: Decimal.fromInt(delta)),
      );
      bal += delta;
    }
    points.add(BalancePoint(date: d, closingBalance: Decimal.fromInt(bal)));
  }
  final lines = <(Rect, List<String>)>[];
  final rects = <Rect, (Offset, double)>{};
  debugVertexLabelLines = (rect, l) => lines.add((rect, l));
  debugVertexLabelRect = (n, c, r, rect) => rects[rect] = (c, r);
  await tester.pumpWidget(const SizedBox());
  lines.clear();
  rects.clear();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox.fromSize(
          size: size,
          child: BalanceChart(
            series: BalanceSeries(points: points, occurrences: occ),
            seedDate: _start.subtract(const Duration(days: 60)),
            viewStart: _start,
            visibleDays: days,
            eventNames: names,
            onViewportChanged: (_, _) {},
            onCreateOnDay: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  // Only the last paint counts (a frame may repaint).
  final out = <_Label>[];
  final seen = <Rect>{};
  for (final (rect, l) in lines.reversed) {
    if (!rects.containsKey(rect) || !seen.add(rect)) continue;
    final (c, r) = rects[rect]!;
    out.add((l, rect, c, r));
  }
  debugVertexLabelLines = null;
  debugVertexLabelRect = null;
  return out;
}

final _more = RegExp(r'^\+\d+ more$');

void _expectNamed(List<_Label> labels, String ctx) {
  for (final (lines, rect, _, _) in labels) {
    final why = '$ctx: $lines at $rect';
    expect(lines.length, greaterThanOrEqualTo(2), reason: 'amount-only $why');
    final name = lines[1];
    expect(_more.hasMatch(name), isFalse, reason: 'no name line $why');
    // A readable name: at least a couple of real characters, not just "…".
    expect(
      name.replaceAll('…', '').trim().length,
      greaterThanOrEqualTo(2),
      reason: why,
    );
  }
}

void _expectGeometry(List<_Label> labels, Rect plot, String ctx) {
  for (var i = 0; i < labels.length; i++) {
    final (lines, rect, c, r) = labels[i];
    final why = '$ctx: $lines at $rect (dot $c r$r)';
    expect(rect.left, closeTo(c!.dx - r, 0.5), reason: 'flush left $why');
    final above = rect.bottom <= c.dy - r + 0.01;
    final below = rect.top >= c.dy + r - 0.01;
    expect(above || below, isTrue, reason: 'above or below $why');
    final gap = above ? c.dy - r - rect.bottom : rect.top - (c.dy + r);
    expect(gap, greaterThanOrEqualTo(2.5), reason: why);
    expect(gap, lessThanOrEqualTo(maxVertexLabelOffset + 3.5), reason: why);
    // Inside the plot vertically (a label at the view's side edge may be
    // clipped as it pans in or out).
    expect(rect.top, greaterThanOrEqualTo(plot.top), reason: why);
    expect(rect.bottom, lessThanOrEqualTo(plot.bottom), reason: why);
    for (var j = i + 1; j < labels.length; j++) {
      expect(
        rect.overlaps(labels[j].$2),
        isFalse,
        reason: '$why overlaps ${labels[j].$1}',
      );
    }
  }
}

void main() {
  tearDown(() {
    debugVertexLabelLines = null;
    debugVertexLabelRect = null;
  });

  final data = _crowded(380);
  for (final size in const [
    Size(320, 600),
    Size(390, 300),
    Size(390, 844),
    Size(768, 500),
    Size(1024, 700),
    Size(1440, 330),
    Size(1440, 900),
  ]) {
    testWidgets('every drawn label has the amount and a name '
        '(${size.width.toInt()}×${size.height.toInt()}, all zooms)', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      var total = 0;
      for (final days in const [7.0, 14.0, 30.0, 60.0, 90.0, 180.0, 365.0]) {
        final ctx = '${size.width.toInt()}×${size.height.toInt()} ${days}d';
        final labels = await _labels(tester, size, data, days);
        total += labels.length;
        _expectNamed(labels, ctx);
        _expectGeometry(labels, ChartLayout.of(size, days).plot, ctx);
      }
      expect(total, greaterThan(0));
    });
  }

  testWidgets('a single event always shows its own name', (tester) async {
    addTearDown(tester.view.reset);
    final labels = await _labels(tester, const Size(390, 300), [
      for (var d = 0; d < 30; d++)
        (d, d.isEven ? 300 : -280, 'A rather long event name $d'),
    ], 30);
    expect(labels, isNotEmpty);
    for (final (lines, _, _, _) in labels) {
      expect(lines.length, 2, reason: '$lines');
      expect(lines[1], startsWith('A '), reason: '$lines');
    }
  });

  testWidgets('a busy day with room for one name line shows the first name '
      'then "+N more" on that line', (tester) async {
    addTearDown(tester.view.reset);
    // A short chart: only the total and one line fit above or below the dot.
    final labels = await _labels(tester, const Size(1440, 150), [
      (10, -100, 'Rent'),
      (10, -100, 'Gym'),
      (10, -100, 'Phone'),
      (11, 500, 'Bonus'),
    ], 30);
    final day = labels.where((l) => l.$1.first == r'−$300').toList();
    expect(day, hasLength(1));
    expect(day.single.$1, [r'−$300', 'Rent +2 more']);
  });
}
