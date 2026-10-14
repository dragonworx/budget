import 'dart:math' as math;
import 'dart:ui';

import '../../data/models.dart';
import 'zoom_level.dart';

/// Closest zoom the wheel can reach, in days across the viewport.
const double minVisibleDays = 3;

/// Farthest zoom the wheel can reach, in days across the viewport.
const double maxVisibleDays = 7300;

/// Day of month with an English ordinal suffix: 1st, 2nd, 3rd, 4th, 11th, 22nd.
String ordinalDay(int day) {
  final teen = day % 100 >= 11 && day % 100 <= 13;
  final suffix = teen
      ? 'th'
      : switch (day % 10) {
          1 => 'st',
          2 => 'nd',
          3 => 'rd',
          _ => 'th',
        };
  return '$day$suffix';
}

/// Adds a fractional number of days without snapping to midnight.
DateTime addDays(DateTime date, double days) {
  final micros = (days * Duration.microsecondsPerDay).round();
  return date.add(Duration(microseconds: micros));
}

/// Min and max closing balances that are actually on screen.
class BalanceExtents {
  const BalanceExtents(this.min, this.max);

  final double min;
  final double max;

  bool get isFlat => (max - min).abs() < 0.005;
}

/// Samples that intersect `[viewStart, viewEnd]`, including the balance
/// carried in from the latest close at or before [viewStart].
class VisibleBalance {
  const VisibleBalance({required this.samples, required this.extents});

  /// Ordered closes. The first sample may fall before [viewStart].
  final List<BalancePoint> samples;
  final BalanceExtents extents;
}

VisibleBalance? visibleBalance({
  required List<BalancePoint> points,
  required DateTime viewStart,
  required DateTime viewEnd,
  required DateTime seedDate,
}) {
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

  var minV = samples.first.closingBalance.toDouble();
  var maxV = minV;
  for (final sample in samples.skip(1)) {
    final value = sample.closingBalance.toDouble();
    if (value < minV) minV = value;
    if (value > maxV) maxV = value;
  }
  return VisibleBalance(samples: samples, extents: BalanceExtents(minV, maxV));
}

/// Headroom around a scale that always includes zero.
///
/// The top fits the data max (or zero, when every balance is negative).
/// The bottom fits whichever of the data min and zero is lower. Padding
/// keeps those edges off the plot border, so zero stays on screen.
BalanceExtents paddedRange(double min, double max) {
  final low = math.min(min, 0);
  final high = math.max(max, 0);
  final span = high - low;
  if (span.abs() < 1e-9) {
    return const BalanceExtents(-1, 1);
  }
  final pad = span * 0.12;
  return BalanceExtents(low - pad, high + pad);
}

/// How many fraction digits keep the visible span readable.
int moneyDigitsForSpan(double min, double max) {
  final span = (max - min).abs();
  if (span < 100 || (min.abs() < 100 && max.abs() < 100)) return 2;
  return 0;
}

enum AxisLane { month, week, day }

class AxisSegment {
  const AxisSegment({
    required this.start,
    required this.end,
    required this.lane,
    required this.colorIndex,
  });

  /// Inclusive.
  final DateTime start;

  /// Exclusive.
  final DateTime end;
  final AxisLane lane;

  /// Month 1–12, week palette index, or weekday 1–7.
  final int colorIndex;
}

List<AxisSegment> monthSegments(DateTime viewStart, DateTime viewEnd) {
  if (!viewStart.isBefore(viewEnd)) return const [];
  var cursor = DateTime(viewStart.year, viewStart.month);
  final out = <AxisSegment>[];
  while (cursor.isBefore(viewEnd) && out.length < 600) {
    final next = DateTime(cursor.year, cursor.month + 1);
    out.add(
      AxisSegment(
        start: cursor,
        end: next,
        lane: AxisLane.month,
        colorIndex: cursor.month,
      ),
    );
    cursor = next;
  }
  return out;
}

List<AxisSegment> weekSegments(DateTime viewStart, DateTime viewEnd) {
  if (!viewStart.isBefore(viewEnd)) return const [];
  final startDay = dateOnly(viewStart);
  var cursor = startDay.subtract(
    Duration(days: startDay.weekday - DateTime.monday),
  );
  final out = <AxisSegment>[];
  while (cursor.isBefore(viewEnd) && out.length < 2000) {
    final next = cursor.add(const Duration(days: 7));
    final weeks = cursor.difference(DateTime(1970, 1, 5)).inDays ~/ 7;
    final index = ((weeks % 4) + 4) % 4;
    out.add(
      AxisSegment(
        start: cursor,
        end: next,
        lane: AxisLane.week,
        colorIndex: index,
      ),
    );
    cursor = next;
  }
  return out;
}

List<AxisSegment> daySegments(DateTime viewStart, DateTime viewEnd) {
  if (!viewStart.isBefore(viewEnd)) return const [];
  var cursor = dateOnly(viewStart);
  final out = <AxisSegment>[];
  while (cursor.isBefore(viewEnd) && out.length < 800) {
    final next = cursor.add(const Duration(days: 1));
    out.add(
      AxisSegment(
        start: cursor,
        end: next,
        lane: AxisLane.day,
        colorIndex: cursor.weekday,
      ),
    );
    cursor = next;
  }
  return out;
}

/// Nice grid values between [min] and [max], inclusive when they land on a step.
List<double> niceGridlines(double min, double max, {int target = 4}) {
  final span = max - min;
  if (span <= 0 || !span.isFinite) return const [];
  final rough = span / target;
  final mag = math.pow(10, (math.log(rough) / math.ln10).floor()).toDouble();
  if (mag == 0 || !mag.isFinite) return const [];
  final residual = rough / mag;
  final nice = residual <= 1.5
      ? 1
      : residual <= 3
      ? 2
      : residual <= 7
      ? 5
      : 10;
  final step = nice * mag;
  if (step <= 0 || !step.isFinite) return const [];
  final startIndex = (min / step).ceil();
  final endIndex = (max / step).floor();
  final out = <double>[];
  for (var i = startIndex; i <= endIndex; i++) {
    final value = i * step;
    if (value >= min && value <= max) out.add(value);
    if (out.length > 8) break;
  }
  return out;
}

/// Where a transaction name sits relative to its occurrence dot.
///
/// Tried in this order. Above the dot keeps the balance line visible;
/// the other sides are used when that spot is off the plot or taken.
enum VertexLabelSide {
  aboveRight,
  besideRight,
  belowRight,
  aboveLeft,
  besideLeft,
}

/// Horizontal room, in pixels, for the text of a vertex label.
///
/// [anchors] must be sorted by x. The budget stops before the next anchor
/// that shares this label's vertical band and still has [minText] pixels
/// free, so neighboring names stay apart. Anchors closer than that are one
/// cluster: a single name may span them instead of every name being dropped.
/// [pad] is the background inset around the text. Returns 0 when nothing
/// readable fits.
double vertexLabelTextBudget({
  required Rect plot,
  required Offset center,
  required double radius,
  required VertexLabelSide side,
  required double labelHeight,
  required double maxText,
  required double minText,
  required double pad,
  required List<Rect> occupied,
  required List<Offset> anchors,
}) {
  if (maxText < minText || labelHeight <= 0 || pad < 0) return 0;
  final toRight = side == VertexLabelSide.aboveRight ||
      side == VertexLabelSide.besideRight ||
      side == VertexLabelSide.belowRight;
  final gap = radius + 3;
  final band = _vertexLabelBand(side, center, radius, labelHeight, plot);
  final bandProbe = band.inflate(2);

  if (toRight) {
    final left = center.dx + gap;
    var limit = plot.right - 1;
    for (final other in occupied) {
      if (other.left <= left + 1 || !other.overlaps(bandProbe)) continue;
      if (other.left - 3 < limit) limit = other.left - 3;
    }
    final reach = left + maxText + pad;
    final start = _firstAnchorAtOrAfter(anchors, center.dx + radius + 0.01);
    for (var i = start; i < anchors.length; i++) {
      final point = anchors[i];
      if (point.dx > reach + radius + 8 && point.dx >= limit) break;
      if (!bandProbe.overlaps(
        _vertexLabelBand(side, point, radius, labelHeight, plot),
      )) {
        continue;
      }
      final room = point.dx - radius - 4 - left - pad;
      if (room >= minText) {
        final stop = point.dx - radius - 4;
        if (stop < limit) limit = stop;
        break;
      }
    }
    final budget = limit - left - pad;
    if (budget < minText) return 0;
    return math.min(maxText, budget);
  }

  final right = center.dx - gap;
  var limit = plot.left + 1;
  for (final other in occupied) {
    if (other.right >= right - 1 || !other.overlaps(bandProbe)) continue;
    if (other.right + 3 > limit) limit = other.right + 3;
  }
  final end = _firstAnchorAtOrAfter(anchors, center.dx - radius);
  final reach = right - maxText - pad;
  for (var i = end - 1; i >= 0; i--) {
    final point = anchors[i];
    if (point.dx < reach - radius - 8 && point.dx <= limit) break;
    if (!bandProbe.overlaps(
      _vertexLabelBand(side, point, radius, labelHeight, plot),
    )) {
      continue;
    }
    final room = right - (point.dx + radius + 4) - pad;
    if (room >= minText) {
      final stop = point.dx + radius + 4;
      if (stop > limit) limit = stop;
      break;
    }
  }
  final budget = right - limit - pad;
  if (budget < minText) return 0;
  return math.min(maxText, budget);
}

/// Box for a label of [width] by [height] on [side] of [center].
Rect vertexLabelRect({
  required Offset center,
  required double radius,
  required VertexLabelSide side,
  required double width,
  required double height,
}) {
  final gap = radius + 3;
  switch (side) {
    case VertexLabelSide.aboveRight:
      return Rect.fromLTWH(
        center.dx + gap,
        center.dy - gap - height,
        width,
        height,
      );
    case VertexLabelSide.besideRight:
      return Rect.fromLTWH(
        center.dx + gap,
        center.dy - height / 2,
        width,
        height,
      );
    case VertexLabelSide.belowRight:
      return Rect.fromLTWH(
        center.dx + gap,
        center.dy + radius + 2,
        width,
        height,
      );
    case VertexLabelSide.aboveLeft:
      return Rect.fromLTWH(
        center.dx - gap - width,
        center.dy - gap - height,
        width,
        height,
      );
    case VertexLabelSide.besideLeft:
      return Rect.fromLTWH(
        center.dx - gap - width,
        center.dy - height / 2,
        width,
        height,
      );
  }
}

/// Whether [rect] can be drawn: inside [plot], clear of [occupied] labels
/// and [anchors], and still touching the vertex it names.
bool vertexLabelFits({
  required Rect rect,
  required Rect plot,
  required Offset anchor,
  required double radius,
  required List<Rect> occupied,
  required List<Offset> anchors,
  double attachReach = 10,
}) {
  const inset = 1.0;
  if (rect.left < plot.left + inset ||
      rect.top < plot.top + inset ||
      rect.right > plot.right - inset ||
      rect.bottom > plot.bottom - inset) {
    return false;
  }
  final padded = rect.inflate(2);
  for (final other in occupied) {
    if (padded.overlaps(other)) return false;
  }
  for (final point in anchors) {
    if (padded.contains(point)) return false;
  }
  final near = Rect.fromCircle(center: anchor, radius: radius + attachReach);
  if (!rect.inflate(2).overlaps(near)) return false;
  return true;
}

/// Slides [rect] just past an occupied box that covers its start, keeping it
/// on the same row as the vertex. Returns null when the slide would leave
/// the vertex or shrink the name below [minWidth].
Rect? nudgeVertexLabel({
  required Rect rect,
  required Rect plot,
  required Offset anchor,
  required double radius,
  required List<Rect> occupied,
  required List<Offset> anchors,
  double maxSlide = 96,
  double minWidth = 28,
}) {
  var left = rect.left;
  var width = rect.width;
  final top = rect.top;
  final height = rect.height;
  for (var pass = 0; pass < occupied.length + 1; pass++) {
    final current = Rect.fromLTWH(left, top, width, height);
    Rect? blocker;
    for (final other in occupied) {
      if (current.inflate(2).overlaps(other)) {
        blocker = other;
        break;
      }
    }
    if (blocker == null) {
      if (left - anchor.dx > maxSlide) return null;
      if (anchor.dx - (left + width) > maxSlide) return null;
      return current;
    }
    final nextLeft = blocker.right + 3;
    if (nextLeft - anchor.dx > maxSlide) return null;
    var nextWidth = width;
    final plotRight = plot.right - 1;
    if (nextLeft + nextWidth > plotRight) {
      nextWidth = plotRight - nextLeft;
    }
    for (final point in anchors) {
      if (point.dx <= anchor.dx + radius) continue;
      if ((point.dy - (top + height / 2)).abs() > height + 4) continue;
      final stop = point.dx - radius - 4;
      if (nextLeft + nextWidth > stop) nextWidth = stop - nextLeft;
    }
    if (nextWidth < minWidth || nextLeft < plot.left + 1) return null;
    if (top < plot.top + 1 || top + height > plot.bottom - 1) return null;
    left = nextLeft;
    width = nextWidth;
  }
  return null;
}

Rect _vertexLabelBand(
  VertexLabelSide side,
  Offset center,
  double radius,
  double labelHeight,
  Rect plot,
) {
  final gap = radius + 3;
  final top = switch (side) {
    VertexLabelSide.aboveRight || VertexLabelSide.aboveLeft =>
      center.dy - gap - labelHeight,
    VertexLabelSide.belowRight => center.dy + radius + 2,
    VertexLabelSide.besideRight || VertexLabelSide.besideLeft =>
      center.dy - labelHeight / 2,
  };
  return Rect.fromLTWH(plot.left, top, plot.width, labelHeight);
}

int _firstAnchorAtOrAfter(List<Offset> anchors, double x) {
  var lo = 0;
  var hi = anchors.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (anchors[mid].dx < x) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}
