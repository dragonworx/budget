// Level of detail for the timeline chart (spec 006 R1–R3).
//
// Below 1.5 px per day the chart stops drawing per-day geometry: the
// balance line becomes an M4 step envelope (first / min / max / last per
// bucket of days on a global day grid), so a pan or pinch at 35 years
// costs O(pixel columns), not O(days). Every ladder level is built once
// per series (cached by the points list's identity, like [PointIndex]),
// never inside a gesture frame.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:decimal/decimal.dart';

import '../../data/models.dart';
import 'alert_fill.dart';
import 'chart_geometry.dart';

/// Detail tier by px per day (plot width / visible days).
enum LodTier {
  /// ≥ 1.5 px/day: today's per-day drawing, unchanged.
  l0,

  /// 0.25–1.5 px/day: envelope line, group markers.
  l1,

  /// < 0.25 px/day.
  l2;

  bool get coarse => this != l0;
}

/// L0 at and above this many px per day.
const double lodL0MinDayPx = 1.5;

/// L2 below this many px per day.
const double lodL2BelowDayPx = 0.25;

/// Tier boundaries move this far (±10%) away from the tier already shown,
/// so a slow zoom or pinch near a boundary does not flicker.
const double lodHysteresis = 0.10;

/// The tier for [dayPx]; [previous] (the tier shown last frame) applies
/// the hysteresis.
LodTier lodTierOf(double dayPx, [LodTier? previous]) {
  var b0 = lodL0MinDayPx, b2 = lodL2BelowDayPx;
  switch (previous) {
    case null:
      break;
    case LodTier.l0:
      b0 *= 1 - lodHysteresis;
    case LodTier.l1:
      b0 *= 1 + lodHysteresis;
      b2 *= 1 - lodHysteresis;
    case LodTier.l2:
      b2 *= 1 + lodHysteresis;
  }
  if (dayPx >= b0) return LodTier.l0;
  if (dayPx >= b2) return LodTier.l1;
  return LodTier.l2;
}

/// Bucket sizes (days) of the ladder, finest first.
const List<int> lodBucketDays = [1, 2, 4, 7, 14, 30, 61, 91];

/// The ladder bucket for [dayPx]: the largest one at most one logical px
/// wide, so every bucket falls inside one pixel column (or straddles two)
/// and each column's min and max stay where the per-day drawing puts them.
/// That is at most two buckets per px (the ladder roughly doubles), still
/// O(plot width). (Spec 006 R2 asked for the smallest bucket with at most
/// one bucket per px; a bucket wider than a column moves the column's
/// extremes by up to its width, beyond the parity test's 1 px.)
int lodBucketDaysFor(double dayPx) {
  var best = lodBucketDays.first;
  for (final d in lodBucketDays) {
    if (d * dayPx <= 1) best = d;
  }
  return best;
}

/// Days since 1970-01-01 of [date]'s calendar day (DST-safe).
int dayIndexOf(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

/// Floor division (the global grid is the same left and right of 1970).
int floorDiv(int a, int b) {
  final q = a ~/ b;
  return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q;
}

/// One ladder level: the series' points grouped into buckets of [days]
/// days (bucket `k` covers days `k * days` .. `k * days + days - 1`).
/// Only buckets holding a point exist; between them the balance carries.
class LodLevel {
  LodLevel._(
    this.days,
    this.key,
    this.firstPoint,
    this.first,
    this.min,
    this.max,
    this.last,
  );

  factory LodLevel.build(int days, Int32List dayIndex, Float64List values) {
    final n = dayIndex.length;
    final key = Int32List(n), fp = Int32List(n + 1);
    final first = Float64List(n), mn = Float64List(n);
    final mx = Float64List(n), last = Float64List(n);
    var b = -1;
    var prevKey = 0;
    for (var i = 0; i < n; i++) {
      final k = floorDiv(dayIndex[i], days);
      final v = values[i];
      if (b < 0 || k != prevKey) {
        b++;
        key[b] = k;
        fp[b] = i;
        first[b] = v;
        mn[b] = v;
        mx[b] = v;
        prevKey = k;
      } else {
        if (v < mn[b]) mn[b] = v;
        if (v > mx[b]) mx[b] = v;
      }
      last[b] = v;
    }
    final count = b + 1;
    fp[count] = n;
    return LodLevel._(
      days,
      Int32List.sublistView(key, 0, count),
      Int32List.fromList(Int32List.sublistView(fp, 0, count + 1)),
      Float64List.fromList(Float64List.sublistView(first, 0, count)),
      Float64List.fromList(Float64List.sublistView(mn, 0, count)),
      Float64List.fromList(Float64List.sublistView(mx, 0, count)),
      Float64List.fromList(Float64List.sublistView(last, 0, count)),
    );
  }

  /// Bucket size in days.
  final int days;

  /// Bucket number on the global grid, ascending.
  final Int32List key;

  /// Index of each bucket's first point; `firstPoint[length]` = points.
  final Int32List firstPoint;
  final Float64List first, min, max, last;

  int get length => key.length;

  /// First bucket whose points end after point index [i] (the bucket
  /// holding point [i]).
  int bucketOfPoint(int i) {
    var lo = 0, hi = length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (firstPoint[mid + 1] <= i) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}

/// Every ladder level of one points list, plus its days and closes as
/// typed arrays.
class SeriesLod {
  SeriesLod(List<BalancePoint> points) : index = pointIndexOf(points) {
    final n = index.sorted.length;
    dayIndex = Int32List(n);
    values = Float64List(n);
    for (var i = 0; i < n; i++) {
      dayIndex[i] = dayIndexOf(index.sorted[i].date);
      values[i] = index.values[i];
    }
    levels = [
      for (final d in lodBucketDays) LodLevel.build(d, dayIndex, values),
    ];
    debugLodBuilds++;
  }

  final PointIndex index;
  late final Int32List dayIndex;
  late final Float64List values;
  late final List<LodLevel> levels;

  /// The ladder level of bucket size [days] (one of [lodBucketDays]).
  LodLevel level(int days) => levels[lodBucketDays.indexOf(days)];

  /// Closing balances in integer cents (the exact values; for sums and
  /// identities, never drawn).
  late final List<int> cents = [
    for (final p in index.sorted) decimalCents(p.closingBalance),
  ];
}

/// Exact integer cents of a 2-dp money value.
int decimalCents(Decimal d) => d.shift(2).toBigInt().toInt();

final _lods = Expando<SeriesLod>('SeriesLod');

/// Ladder builds since start (a test / HUD counter: none may happen inside
/// a gesture frame once a series is loaded).
int debugLodBuilds = 0;

/// The cached [SeriesLod] of [points].
SeriesLod seriesLodOf(List<BalancePoint> points) =>
    _lods[points] ??= SeriesLod(points);

/// Whether [points] already has its ladder (no build on the next draw).
bool seriesLodReady(List<BalancePoint> points) => _lods[points] != null;

/// One envelope column: at [dayIndex] the line rises / falls from the
/// previous level through [min]..[max] and leaves at [last]; [first] is
/// the bucket's first close.
typedef EnvelopeColumn = ({
  int dayIndex,
  double first,
  double min,
  double max,
  double last,
});

/// The M4 envelope of points `[from, to)` (indices into the sorted
/// points) at ladder [level]: one column per bucket, exact first / min /
/// max / last. Buckets cut by the range ends are recomputed from their
/// own points (at most `level.days` of them), so the edges are exact too.
List<EnvelopeColumn> envelopeOf(
  SeriesLod lod,
  LodLevel level,
  int from,
  int to,
) {
  final out = <EnvelopeColumn>[];
  if (from >= to) return out;
  final vals = lod.values;
  for (var b = level.bucketOfPoint(from); b < level.length; b++) {
    final s = level.firstPoint[b], e = level.firstPoint[b + 1];
    if (s >= to) break;
    if (s >= from && e <= to) {
      out.add((
        dayIndex: lod.dayIndex[s],
        first: level.first[b],
        min: level.min[b],
        max: level.max[b],
        last: level.last[b],
      ));
      continue;
    }
    final a = math.max(s, from), z = math.min(e, to);
    var mn = vals[a], mx = vals[a];
    for (var i = a + 1; i < z; i++) {
      final v = vals[i];
      if (v < mn) mn = v;
      if (v > mx) mx = v;
    }
    out.add((
      dayIndex: lod.dayIndex[a],
      first: vals[a],
      min: mn,
      max: mx,
      last: vals[z - 1],
    ));
  }
  return out;
}

/// Test-only: draw every tier at full per-day resolution (the envelope
/// parity tests render both paths).
bool debugLodDisabled = false;

/// Test-only: skip the area fill under the balance line (the parity tests
/// compare the line alone; the per-day path's overlapping sub-pixel fill
/// rects stack their alpha, so its fill is not a reference).
bool debugSeriesFillDisabled = false;

/// The tier shown last frame, kept by the chart across painters (for the
/// hysteresis and for hit-testing).
class LodMemory {
  LodTier? _tier;

  LodTier get tier => _tier ?? LodTier.l0;

  /// Picks this frame's tier for [dayPx].
  LodTier update(double dayPx) =>
      _tier = debugLodDisabled ? LodTier.l0 : lodTierOf(dayPx, _tier);
}

/// One fill column of the coarse balance line: from [x0] to [x1] (px) the
/// balance spans [min]..[max].
typedef FillColumn = ({double x0, double x1, double min, double max});

/// The coarse-tier version of `alertFillOf`: the fill under the envelope,
/// split at the alert line. A column fills green from its max down when
/// its max is not below the alert, and is in deficit (the band between
/// the alert line and its min) when its min is below it — so deficit
/// columns are exactly those holding a day below the threshold.
AlertFill envelopeFill(
  List<FillColumn> columns, {
  required double alertY,
  required Rect plot,
  required double Function(double) yOf,
  required bool Function(double) low,
}) {
  final safe = <Rect>[], deficit = <Rect>[], under = <Rect>[];
  double clampY(double y) => y.clamp(plot.top, plot.bottom).toDouble();
  final bandTop = clampY(alertY);
  for (final c in columns) {
    final x0 = c.x0.clamp(plot.left, plot.right).toDouble();
    final x1 = c.x1.clamp(plot.left, plot.right).toDouble();
    if (x1 <= x0) continue;
    final yTop = clampY(yOf(c.max)), yBottom = clampY(yOf(c.min));
    final lowMax = low(c.max), lowMin = low(c.min);
    if (!lowMax && yTop < plot.bottom) {
      safe.add(Rect.fromLTRB(x0, yTop, x1, plot.bottom));
    }
    if (lowMin && yBottom > bandTop) {
      deficit.add(Rect.fromLTRB(x0, bandTop, x1, yBottom));
    }
    if (lowMax && yTop < plot.bottom) {
      under.add(Rect.fromLTRB(x0, yTop, x1, plot.bottom));
    }
  }
  return AlertFill(
    safe: safe,
    deficit: deficit,
    under: under,
    crossings: const [],
  );
}
