import 'dart:math' as math;

import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/zoom_level.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pre-cache implementation, kept as the oracle.
VisibleBalance? _naiveVisible(
  List<BalancePoint> points,
  DateTime viewStart,
  DateTime viewEnd,
  DateTime seedDate,
) {
  if (!viewStart.isBefore(viewEnd) || points.isEmpty) return null;
  final seed = dateOnly(seedDate);
  final sorted = [...points]..sort((a, b) => a.date.compareTo(b.date));
  BalancePoint? carry;
  final inWindow = <BalancePoint>[];
  for (final point in sorted) {
    final day = dateOnly(point.date);
    if (day.isBefore(seed)) continue;
    if (!day.isAfter(viewStart)) {
      carry = point;
    } else if (!day.isAfter(viewEnd)) {
      inWindow.add(point);
    } else {
      break;
    }
  }
  final samples = <BalancePoint>[?carry, ...inWindow];
  if (samples.isEmpty) return null;
  final vs = samples.map((s) => s.closingBalance.toDouble());
  return VisibleBalance(
    samples: samples,
    extents: BalanceExtents(vs.reduce(math.min), vs.reduce(math.max)),
  );
}

void main() {
  // Sydney-style local days across DST changes, unsorted, with gaps.
  final rnd = math.Random(7);
  final points = <BalancePoint>[
    for (var i = 0; i < 400; i++)
      if (i % 7 != 3)
        BalancePoint(
          date: DateTime(2026, 1, 1 + i),
          closingBalance: Decimal.fromInt(rnd.nextInt(5000) - 1000),
        ),
  ]..shuffle(rnd);

  test('visibleBalance matches the naive scan (carry, window, seed)', () {
    for (var k = 0; k < 300; k++) {
      final start = DateTime(2025, 12, 1 + rnd.nextInt(460), rnd.nextInt(24));
      final end = addDays(start, 1 + rnd.nextDouble() * 120);
      final seed = DateTime(2026, 1, 1 + rnd.nextInt(200));
      final a = visibleBalance(
        points: points,
        viewStart: start,
        viewEnd: end,
        seedDate: seed,
      );
      final b = _naiveVisible(points, start, end, seed);
      expect(a == null, b == null, reason: '$start..$end seed $seed');
      if (a == null) continue;
      expect(a.samples.map((p) => p.date), b!.samples.map((p) => p.date));
      expect((a.extents.min, a.extents.max), (b.extents.min, b.extents.max));
    }
  });

  test('balanceExtentsFrom and closes come from one cached index', () {
    final seed = DateTime(2026, 3, 1);
    final naive = points
        .where((p) => !dateOnly(p.date).isBefore(seed))
        .map((p) => p.closingBalance.toDouble());
    final e = balanceExtentsFrom(points, seed)!;
    expect(e.min, naive.reduce(math.min));
    expect(e.max, naive.reduce(math.max));
    expect(identical(pointIndexOf(points), pointIndexOf(points)), isTrue);
    final ix = pointIndexOf(points);
    for (final p in points) {
      expect(
        ix.closeByDayMs[dateOnly(p.date).millisecondsSinceEpoch],
        p.closingBalance.toDouble(),
      );
    }
    expect(balanceExtentsFrom(const [], seed), isNull);
    expect(balanceExtentsFrom(points, DateTime(2030)), isNull);
  });

  test('groupByDay is cached per list and still groups', () {
    final occ = [
      Occurrence(
        eventId: 'a',
        date: DateTime(2026, 4, 5),
        signedDelta: Decimal.one,
      ),
      Occurrence(
        eventId: 'b',
        date: DateTime(2026, 4, 4),
        signedDelta: Decimal.one,
      ),
      Occurrence(
        eventId: 'c',
        date: DateTime(2026, 4, 5, 12),
        signedDelta: Decimal.one,
      ),
    ];
    final g = groupByDay(occ);
    expect(identical(g, groupByDay(occ)), isTrue);
    expect(g.map((d) => d.day), [DateTime(2026, 4, 4), DateTime(2026, 4, 5)]);
    expect(g.last.all.map((o) => o.eventId), ['a', 'c']);
    // Non-list iterables are grouped fresh.
    expect(groupByDay(occ.where((o) => true)).length, 2);
  });
}
