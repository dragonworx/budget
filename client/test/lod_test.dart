import 'dart:math' as math;

import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/lod.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

List<BalancePoint> _points(math.Random rnd, int n, {bool gaps = true}) => [
  for (var i = 0, d = 0; i < n; i++, d += gaps ? 1 + rnd.nextInt(3) : 1)
    BalancePoint(
      date: DateTime(1965, 3, 1 + d),
      closingBalance: Decimal.fromInt(rnd.nextInt(2000000) - 500000).shift(-2),
    ),
];

void main() {
  test('tiers by px per day, with 10% hysteresis', () {
    expect(lodTierOf(1.5), LodTier.l0);
    expect(lodTierOf(1.49), LodTier.l1);
    expect(lodTierOf(0.25), LodTier.l1);
    expect(lodTierOf(0.249), LodTier.l2);
    // From L0, L1 starts below 1.35; from L1, L0 needs 1.65.
    expect(lodTierOf(1.4, LodTier.l0), LodTier.l0);
    expect(lodTierOf(1.34, LodTier.l0), LodTier.l1);
    expect(lodTierOf(1.6, LodTier.l1), LodTier.l1);
    expect(lodTierOf(1.66, LodTier.l1), LodTier.l0);
    expect(lodTierOf(0.23, LodTier.l1), LodTier.l1);
    expect(lodTierOf(0.22, LodTier.l1), LodTier.l2);
    expect(lodTierOf(0.27, LodTier.l2), LodTier.l2);
    expect(lodTierOf(0.28, LodTier.l2), LodTier.l1);
  });

  test('a slow zoom across both boundaries switches each tier once', () {
    // 2 s at 60 fps from 3 px/day down to 0.1 with a 2% wobble per frame.
    final mem = LodMemory();
    final seen = <LodTier>[];
    for (var f = 0; f < 120; f++) {
      final t = f / 119;
      final base = 3 * math.pow(0.1 / 3, t).toDouble();
      final wobble = 1 + 0.02 * math.sin(f * 1.7);
      final tier = mem.update(base * wobble);
      if (seen.isEmpty || seen.last != tier) seen.add(tier);
    }
    expect(seen, [LodTier.l0, LodTier.l1, LodTier.l2]);
  });

  test('bucket days: the largest ladder bucket at most 1 px wide', () {
    expect(lodBucketDaysFor(1.2), 1);
    expect(lodBucketDaysFor(0.5), 2);
    expect(lodBucketDaysFor(1600 / 12785), 7);
    expect(lodBucketDaysFor(374 / 12785), 30);
    expect(lodBucketDaysFor(0.001), 91);
    for (final px in [0.01, 0.03, 0.1, 0.2, 0.4, 0.9]) {
      final d = lodBucketDaysFor(px);
      expect(d * px, lessThanOrEqualTo(1));
    }
  });

  test('floorDiv is a floor on both sides of 1970', () {
    for (var a = -50; a <= 50; a++) {
      for (final b in [1, 2, 7, 91]) {
        expect(floorDiv(a, b), (a / b).floor());
      }
    }
  });

  test('every ladder level equals a brute-force grouping', () {
    final rnd = math.Random(11);
    for (var k = 0; k < 20; k++) {
      final pts = _points(rnd, 200 + rnd.nextInt(800), gaps: k.isOdd);
      final lod = SeriesLod(pts);
      for (final days in lodBucketDays) {
        final level = lod.level(days);
        final byKey = <int, List<double>>{};
        for (final p in pts) {
          byKey
              .putIfAbsent(floorDiv(dayIndexOf(p.date), days), () => [])
              .add(p.closingBalance.toDouble());
        }
        final keys = byKey.keys.toList()..sort();
        expect(level.key.toList(), keys);
        for (final (b, key) in keys.indexed) {
          final v = byKey[key]!;
          expect(level.first[b], v.first);
          expect(level.last[b], v.last);
          expect(level.min[b], v.reduce(math.min));
          expect(level.max[b], v.reduce(math.max));
        }
        expect(level.firstPoint.last, pts.length);
      }
    }
  });

  test('envelopeOf is exact at cut buckets and covers every point', () {
    final rnd = math.Random(5);
    final pts = _points(rnd, 3000);
    final lod = SeriesLod(pts);
    for (var k = 0; k < 300; k++) {
      final from = rnd.nextInt(pts.length - 1);
      final to = from + 1 + rnd.nextInt(pts.length - from - 1);
      final level = lod.level(lodBucketDays[rnd.nextInt(lodBucketDays.length)]);
      final env = envelopeOf(lod, level, from, to);
      final vals = [
        for (var i = from; i < to; i++) pts[i].closingBalance.toDouble(),
      ];
      expect(env.map((c) => c.min).reduce(math.min), vals.reduce(math.min));
      expect(env.map((c) => c.max).reduce(math.max), vals.reduce(math.max));
      expect(env.first.first, vals.first);
      expect(env.last.last, vals.last);
      expect(env.first.dayIndex, dayIndexOf(pts[from].date));
      for (var i = 1; i < env.length; i++) {
        expect(env[i].dayIndex, greaterThan(env[i - 1].dayIndex));
        expect(
          floorDiv(env[i].dayIndex, level.days),
          greaterThan(floorDiv(env[i - 1].dayIndex, level.days)),
        );
      }
    }
  });

  test('rangeExtents equals a scan for long and short ranges', () {
    final rnd = math.Random(3);
    final pts = _points(rnd, 5000);
    final ix = pointIndexOf(pts);
    for (var k = 0; k < 500; k++) {
      final lo = rnd.nextInt(pts.length);
      final hi = lo + 1 + rnd.nextInt(pts.length - lo);
      final v = ix.values.sublist(lo, hi);
      final e = ix.rangeExtents(lo, hi);
      expect(e.min, v.reduce(math.min));
      expect(e.max, v.reduce(math.max));
    }
  });

  test('the ladder is built once per points list', () {
    final pts = _points(math.Random(1), 100);
    final before = debugLodBuilds;
    expect(seriesLodReady(pts), isFalse);
    seriesLodOf(pts);
    seriesLodOf(pts);
    expect(seriesLodReady(pts), isTrue);
    expect(debugLodBuilds - before, 1);
  });

  test('closes in cents are exact', () {
    final pts = _points(math.Random(9), 500);
    final lod = seriesLodOf(pts);
    for (final (i, p) in pts.indexed) {
      expect(Decimal.fromInt(lod.cents[i]).shift(-2), p.closingBalance);
    }
  });

  test('envelopeFill: deficit columns are exactly those below the alert', () {
    const plot = Rect.fromLTRB(0, 0, 100, 100);
    double yOf(double v) => 100 - v;
    bool low(double v) => v < 40;
    final cols = <FillColumn>[
      (x0: 0, x1: 10, min: 50, max: 60), // safe
      (x0: 10, x1: 20, min: 30, max: 60), // mixed: safe + deficit
      (x0: 20, x1: 30, min: 10, max: 20), // all low: deficit + under
      (x0: 30, x1: 40, min: 40, max: 40), // touching: not an alert
    ];
    final f = envelopeFill(
      cols,
      alertY: yOf(40),
      plot: plot,
      yOf: yOf,
      low: low,
    );
    expect(f.safe, [
      const Rect.fromLTRB(0, 40, 10, 100),
      const Rect.fromLTRB(10, 40, 20, 100),
      const Rect.fromLTRB(30, 60, 40, 100),
    ]);
    expect(f.deficit, [
      const Rect.fromLTRB(10, 60, 20, 70),
      const Rect.fromLTRB(20, 60, 30, 90),
    ]);
    expect(f.under, [const Rect.fromLTRB(20, 80, 30, 100)]);
  });
}
