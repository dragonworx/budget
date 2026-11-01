// Phase 1 perf: the indexed / binary-searched helpers must give exactly the
// answers of the linear scans they replace. The old versions are kept here
// verbatim (as `old*`) and compared on seeded random inputs.
import 'dart:math' as math;

import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/step_dots.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

const cases = 1500;

// ---- old linear copies -------------------------------------------------

bool oldCrowded(List<Offset> labeledAt, Offset c, double gap, double h) =>
    labeledAt.any((at) {
      final dx = (c.dx - at.dx).abs();
      final dy = (c.dy - at.dy).abs();
      return dx < gap && dy < h + 18;
    });

int? oldNearestPointIndex(
  List<Offset> points,
  Offset pos, {
  double maxDistance = double.infinity,
}) {
  int? best;
  var bestD = double.infinity;
  for (var i = 0; i < points.length; i++) {
    final d = (points[i] - pos).distanceSquared;
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  if (best == null) return null;
  if (maxDistance.isFinite && bestD > maxDistance * maxDistance) return null;
  return best;
}

List<StepDot> oldVisibleStepDots({
  required List<BalanceStep> steps,
  required double Function(DateTime day) xOf,
  required double Function(double value) yOf,
  required Rect plot,
  required double dayPx,
}) {
  final r = stepDotRadius(dayPx);
  final gap = stepDotMinGap(r);
  final out = <StepDot>[];
  double? lastX;
  for (final s in steps) {
    final c = stepCenter(s.day, s.balance, xOf: xOf, yOf: yOf);
    final x = c.dx, y = c.dy;
    if (x < plot.left - r) continue;
    if (x > plot.right + r) break;
    if (y < plot.top - r || y > plot.bottom + r) continue;
    if (lastX != null && x - lastX < gap) continue;
    out.add(StepDot(s, c, r));
    lastX = x;
  }
  return out;
}

StepDot? oldStepDotAt(List<StepDot> dots, Offset pos, {required bool touch}) {
  final hit = stepDotHitRadius(touch: touch);
  StepDot? best;
  var bestD = double.infinity;
  for (final d in dots) {
    final dist = (d.center - pos).distance;
    if (dist <= math.max(hit, d.radius) && dist < bestD) {
      best = d;
      bestD = dist;
    }
  }
  return best;
}

StepDot? oldStepDotOn(List<StepDot> dots, DateTime day) {
  for (final d in dots) {
    if (d.step.day == day) return d;
  }
  return null;
}

List<DayGroup> oldDayFilter(
  List<DayGroup> groups,
  DateTime seed,
  DateTime from,
  DateTime to,
) => [
  for (final g in groups)
    if (!(g.day.isBefore(seed) ||
        !addCalendarDays(g.day, 1).isAfter(from) ||
        g.day.isAfter(to)))
      g,
];

/// The [_dots] label lookup: the first dot within 1.5px.
int? oldLabelDot(List<Offset> dots, Offset at) {
  for (var i = 0; i < dots.length; i++) {
    if ((dots[i] - at).distance < 1.5) return i;
  }
  return null;
}

int? newLabelDot(List<Offset> dots, Offset at) {
  final from = lowerBoundByX(dots, (o) => o.dx, at.dx - 2.5);
  final to = upperBoundByX(dots, (o) => o.dx, at.dx + 2.5);
  for (var i = from; i < to; i++) {
    if ((dots[i] - at).distance < 1.5) return i;
  }
  return null;
}

// ---- inputs --------------------------------------------------------------

const plot = Rect.fromLTWH(48, 20, 1500, 820);

/// Sorted x positions with ties and near-ties (same day, lanes).
List<Offset> sortedPoints(math.Random r, int n, {bool grid = false}) {
  final out = <Offset>[];
  var x = plot.left - 60 + r.nextDouble() * 20;
  for (var i = 0; i < n; i++) {
    final step = switch (r.nextInt(4)) {
      0 => 0.0,
      1 => r.nextDouble() * 0.6,
      2 => r.nextDouble() * 8,
      _ => r.nextDouble() * 40,
    };
    x += grid ? step.roundToDouble() : step;
    out.add(Offset(x, plot.top - 20 + r.nextDouble() * (plot.height + 40)));
  }
  return out;
}

Offset somewhere(math.Random r, List<Offset> pts) {
  if (pts.isNotEmpty && r.nextBool()) {
    final p = pts[r.nextInt(pts.length)];
    return p + Offset(r.nextDouble() * 30 - 15, r.nextDouble() * 30 - 15);
  }
  return Offset(
    plot.left - 40 + r.nextDouble() * (plot.width + 80),
    plot.top - 40 + r.nextDouble() * (plot.height + 80),
  );
}

void main() {
  test('label crowding grid == linear any()', () {
    final r = math.Random(5001);
    var crowdedSeen = 0;
    for (var k = 0; k < cases; k++) {
      final gap = r.nextBool() ? 10.0 : 30.0;
      final h = 20 + r.nextDouble() * 20;
      final grid = LabelCrowding(gapX: gap, gapY: h + 18);
      final linear = <Offset>[];
      for (final p in sortedPoints(r, 60 + r.nextInt(200))..shuffle(r)) {
        final a = oldCrowded(linear, p, gap, h);
        expect(grid.crowded(p), a, reason: 'case $k at $p');
        if (a) {
          crowdedSeen++;
        } else {
          grid.add(p);
          linear.add(p);
        }
      }
    }
    expect(crowdedSeen, greaterThan(1000));
  });

  test('vertexLabelTextBudget / vertexLabelFits with the x index', () {
    final r = math.Random(5002);
    var fitsTrue = 0, budgets = 0;
    for (var k = 0; k < cases; k++) {
      final anchors = sortedPoints(r, 20 + r.nextInt(300), grid: r.nextBool());
      final occupied = [
        for (var i = 0; i < r.nextInt(30); i++)
          Rect.fromLTWH(
            plot.left + r.nextDouble() * plot.width,
            plot.top + r.nextDouble() * plot.height,
            10 + r.nextDouble() * 120,
            10 + r.nextDouble() * 30,
          ),
      ];
      for (var j = 0; j < 8; j++) {
        final center = r.nextInt(3) == 0
            ? somewhere(r, anchors)
            : anchors[r.nextInt(anchors.length)];
        final radius = 2 + r.nextDouble() * 3;
        final side = r.nextBool()
            ? VertexLabelSide.above
            : VertexLabelSide.below;
        final labelHeight = 14 + r.nextDouble() * 20;
        final maxText = 20 + r.nextDouble() * 160;
        final minText = r.nextDouble() * 30;
        final pad = r.nextDouble() * 10;
        final offset = r.nextInt(3) == 0 ? r.nextDouble() * 60 : 0.0;
        final index = RectIndex(occupied);
        final grid = PointGrid(anchors);
        double budget(bool indexed, {bool gridded = false}) =>
            vertexLabelTextBudget(
              plot: plot,
              center: center,
              radius: radius,
              side: side,
              labelHeight: labelHeight,
              maxText: maxText,
              minText: minText,
              pad: pad,
              occupied: occupied,
              anchors: anchors,
              offset: offset,
              anchorsSortedByX: indexed,
              occupiedIndex: indexed ? index : null,
              anchorGrid: gridded ? grid : null,
            );
        final b = budget(false);
        expect(budget(true), b, reason: 'budget case $k/$j');
        expect(budget(true, gridded: true), b, reason: 'grid budget $k/$j');
        if (b > 0) budgets++;
        // The slack bound at a shorter height never under-estimates a
        // taller label's budget (the hopeless-spot skip relies on it).
        final shorter = labelHeight - r.nextDouble() * 12;
        final bound = vertexLabelTextBudget(
          plot: plot,
          center: center,
          radius: radius,
          side: side,
          labelHeight: shorter,
          maxText: maxText,
          minText: minText,
          pad: pad,
          occupied: occupied,
          anchors: anchors,
          offset: offset,
          anchorsSortedByX: true,
          occupiedIndex: index,
          slack: 1e-6,
          anchorGrid: r.nextBool() ? grid : null,
        );
        expect(bound, greaterThanOrEqualTo(b), reason: 'bound case $k/$j');

        final rect = Rect.fromLTWH(
          center.dx - r.nextDouble() * 40,
          center.dy + (r.nextBool() ? -1 : 1) * (4 + r.nextDouble() * 60),
          10 + r.nextDouble() * 150,
          10 + r.nextDouble() * 30,
        );
        final reach = r.nextBool() ? 10.0 : 10 + r.nextDouble() * 100;
        bool fits(bool indexed, {bool gridded = false}) => vertexLabelFits(
          rect: rect,
          plot: plot,
          anchor: center,
          radius: radius,
          occupied: occupied,
          anchors: anchors,
          attachReach: reach,
          anchorsSortedByX: indexed,
          occupiedIndex: indexed ? index : null,
          anchorGrid: gridded ? grid : null,
        );
        final f = fits(false);
        expect(fits(true), f, reason: 'fits case $k/$j');
        expect(fits(true, gridded: true), f, reason: 'grid fits $k/$j');
        if (f) fitsTrue++;
      }
    }
    expect(fitsTrue, greaterThan(100));
    expect(budgets, greaterThan(100));
  });

  test('nearestPointIndex (x index) == linear, ties keep the earlier', () {
    final r = math.Random(5003);
    var hits = 0;
    for (var k = 0; k < cases * 4; k++) {
      final pts = sortedPoints(r, r.nextInt(400), grid: k.isEven);
      final pos = somewhere(r, pts);
      final pos2 = k % 3 == 0
          ? Offset(pos.dx.roundToDouble(), pos.dy.roundToDouble())
          : pos;
      final max = switch (r.nextInt(4)) {
        0 => double.infinity,
        1 => 8.0,
        2 => 22.0,
        _ => 96.0,
      };
      final a = oldNearestPointIndex(pts, pos2, maxDistance: max);
      final b = nearestPointIndex(
        pts,
        pos2,
        maxDistance: max,
        pointsSortedByX: true,
      );
      expect(b, a, reason: 'case $k');
      expect(nearestPointIndex(pts, pos2, maxDistance: max), a);
      if (a != null) hits++;
    }
    expect(hits, greaterThan(1000));
  });

  test('label dot lookup by x range == linear first match', () {
    final r = math.Random(5004);
    for (var k = 0; k < cases * 4; k++) {
      final pts = sortedPoints(r, r.nextInt(300), grid: k.isEven);
      final at = pts.isNotEmpty && r.nextBool()
          ? pts[r.nextInt(pts.length)] + Offset(r.nextDouble() - 0.5, 0)
          : somewhere(r, pts);
      expect(newLabelDot(pts, at), oldLabelDot(pts, at), reason: 'case $k');
    }
  });

  test('visibleStepDots / stepDotAt / stepDotOnDay == linear', () {
    final r = math.Random(5005);
    var atHits = 0, onHits = 0;
    for (var k = 0; k < cases; k++) {
      final start = DateTime(1995 + r.nextInt(30), 1 + r.nextInt(12), 1);
      final steps = <BalanceStep>[];
      var day = start;
      var bal = 0.0;
      for (var i = 0; i < 50 + r.nextInt(600); i++) {
        day = addCalendarDays(day, 1 + r.nextInt(r.nextBool() ? 3 : 40));
        final before = bal;
        bal += (r.nextDouble() - 0.5) * 4000;
        steps.add(
          BalanceStep(day: day, before: before, balance: bal, events: 1),
        );
      }
      final visibleDays = 20 + r.nextDouble() * 12000;
      final viewStart = addDays(
        start,
        r.nextDouble() * steps.length * 10 - visibleDays / 2,
      );
      final dayPx = plot.width / visibleDays;
      double xOf(DateTime d) =>
          plot.left + (dayCoord(d) - dayCoord(viewStart)) * dayPx;
      final lo = -20000.0 + r.nextDouble() * 10000, hi = lo + 40000;
      double yOf(double v) => plot.bottom - (v - lo) / (hi - lo) * plot.height;
      final a = oldVisibleStepDots(
        steps: steps,
        xOf: xOf,
        yOf: yOf,
        plot: plot,
        dayPx: dayPx,
      );
      final b = visibleStepDots(
        steps: steps,
        xOf: xOf,
        yOf: yOf,
        plot: plot,
        dayPx: dayPx,
      );
      expect(b.length, a.length, reason: 'case $k');
      for (var i = 0; i < a.length; i++) {
        expect(identical(b[i].step, a[i].step), isTrue);
        expect(b[i].center, a[i].center);
        expect(b[i].radius, a[i].radius);
      }
      final centers = [for (final d in a) d.center];
      for (var j = 0; j < 10; j++) {
        final pos = somewhere(r, centers);
        final touch = r.nextBool();
        final x = oldStepDotAt(a, pos, touch: touch);
        expect(stepDotAt(b, pos, touch: touch)?.step, x?.step);
        if (x != null) atHits++;
        final d = r.nextBool() && a.isNotEmpty
            ? a[r.nextInt(a.length)].step.day
            : steps[r.nextInt(steps.length)].day;
        final on = oldStepDotOn(a, d);
        expect(stepDotOnDay(b, d)?.step, on?.step);
        if (on != null) onHits++;
      }
    }
    expect(atHits, greaterThan(1000));
    expect(onHits, greaterThan(1000));
  });

  test('dayGroupRange == the linear day filter', () {
    final r = math.Random(5006);
    for (var k = 0; k < cases; k++) {
      final start = DateTime(1990 + r.nextInt(40), 1 + r.nextInt(12), 1);
      final occ = <Occurrence>[];
      var day = start;
      for (var i = 0; i < r.nextInt(400); i++) {
        day = addCalendarDays(day, r.nextInt(r.nextBool() ? 2 : 30));
        occ.add(
          Occurrence(
            eventId: 'e${r.nextInt(5)}',
            date: day.add(Duration(hours: r.nextInt(20))),
            signedDelta: Decimal.fromInt(r.nextInt(2000) - 1000),
          ),
        );
      }
      final groups = groupByDay(occ);
      DateTime at(double spread) =>
          addDays(start, r.nextDouble() * spread - spread * 0.1);
      final seed = at(3000);
      final from = at(8000);
      final to = addDays(from, r.nextDouble() * 6000);
      final want = oldDayFilter(groups, seed, from, to);
      final (s, e) = dayGroupRange(groups, seed: seed, from: from, to: to);
      final got = s < e ? groups.sublist(s, e) : <DayGroup>[];
      // The painters keep the filter inside the range, so it must hold
      // for every group in it, and none outside.
      expect(
        [for (final g in got) g.day],
        [for (final g in want) g.day],
        reason: 'case $k',
      );
    }
  });

  test('DayGroup cached values == recomputed', () {
    final r = math.Random(5007);
    for (var k = 0; k < cases; k++) {
      final all = [
        for (var i = 0; i < 1 + r.nextInt(6); i++)
          Occurrence(
            eventId: 'e$i',
            date: DateTime(2026, 1, 1),
            signedDelta: Decimal.fromInt(r.nextInt(2000) - 1000),
            skipped: r.nextInt(3) == 0,
            netted: r.nextInt(5) == 0,
          ),
      ];
      final g = DayGroup(DateTime(2026, 1, 1), all);
      final active = [
        for (final o in all)
          if (!o.skipped) o,
      ];
      final allSkipped = active.isEmpty;
      expect(g.active, active);
      expect(g.allSkipped, allSkipped);
      expect(g.count, allSkipped ? all.length : active.length);
      expect(
        g.net,
        (allSkipped ? all : active).fold(
          0.0,
          (sum, o) => o.netted ? sum : sum + o.signedDelta.toDouble(),
        ),
      );
      expect(
        g.hasCredit,
        active.any((o) => !o.netted && o.signedDelta.toDouble() > 0),
      );
      expect(
        g.hasDebit,
        active.any((o) => !o.netted && o.signedDelta.toDouble() < 0),
      );
    }
  });
}
