import 'dart:math' as math;
import 'dart:ui';

import '../../data/models.dart';
import 'zoom_level.dart';

/// Closest zoom the wheel can reach, in days across the viewport.
const double minVisibleDays = 1;

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

/// Continuous day coordinate of [date]'s wall-clock time: whole days since
/// 1970-01-01 plus the fraction of the day elapsed.
///
/// Every calendar day is exactly 1.0 wide, even across daylight-saving
/// changes where a local day lasts 23 or 25 hours. All chart X math goes
/// through this, so day cells, occurrence dots and axis labels agree.
double dayCoord(DateTime date) {
  final midnightUtc = DateTime.utc(date.year, date.month, date.day);
  final whole =
      midnightUtc.millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
  final micros =
      date.hour * Duration.microsecondsPerHour +
      date.minute * Duration.microsecondsPerMinute +
      date.second * Duration.microsecondsPerSecond +
      date.millisecond * Duration.microsecondsPerMillisecond +
      date.microsecond;
  return whole + micros / Duration.microsecondsPerDay;
}

/// Local wall-clock time at day coordinate [coord] (inverse of [dayCoord]).
DateTime dateFromDayCoord(double coord) {
  final whole = coord.floor();
  final micros = ((coord - whole) * Duration.microsecondsPerDay).round();
  final day = DateTime.utc(1970).add(Duration(days: whole));
  return DateTime(
    day.year,
    day.month,
    day.day,
    micros ~/ Duration.microsecondsPerHour,
    micros % Duration.microsecondsPerHour ~/ Duration.microsecondsPerMinute,
    micros % Duration.microsecondsPerMinute ~/ Duration.microsecondsPerSecond,
    micros %
        Duration.microsecondsPerSecond ~/
        Duration.microsecondsPerMillisecond,
    micros % Duration.microsecondsPerMillisecond,
  );
}

/// Adds a fractional number of calendar days without snapping to midnight.
///
/// Uses calendar days, not 24-hour durations, so a DST change inside the
/// span does not shift the result by an hour (and onto the wrong date).
DateTime addDays(DateTime date, double days) =>
    dateFromDayCoord(dayCoord(date) + days);

/// [date] moved by whole calendar days, at local midnight.
DateTime addCalendarDays(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);

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
/// Balance range that fits [min]..[max] with breathing room. Values in
/// [include] (e.g. zero or the loss threshold) are pulled in only when the
/// caller asks, so fits follow the data instead of being squashed.
BalanceExtents paddedRange(
  double min,
  double max, {
  Iterable<double> include = const [],
}) {
  var low = min;
  var high = max;
  for (final v in include) {
    low = math.min(low, v);
    high = math.max(high, v);
  }
  final span = high - low;
  if (span.abs() < 1e-9) {
    final pad = math.max(1.0, high.abs() * 0.1);
    return BalanceExtents(low - pad, high + pad);
  }
  final pad = span * 0.12;
  return BalanceExtents(low - pad, high + pad);
}

/// Smallest and largest balance span the vertical zoom allows.
const double minBalanceSpan = 0.05;
const double maxBalanceSpan = 1e13;

/// Vertical view [range] after dragging the content down by [dyPx] pixels
/// (negative drags up) on a plot [plotHeight] tall. The span is unchanged.
BalanceExtents panBalanceRange(
  BalanceExtents range,
  double dyPx,
  double plotHeight,
) {
  if (plotHeight <= 0 || dyPx == 0) return range;
  final shift = dyPx / plotHeight * (range.max - range.min);
  return BalanceExtents(range.min + shift, range.max + shift);
}

/// Vertical view [range] scaled by [factor] (>1 zooms out) around the balance
/// at [anchorFraction] of the range (0 = bottom, 1 = top), which stays put.
BalanceExtents zoomBalanceRange(
  BalanceExtents range,
  double factor,
  double anchorFraction,
) {
  if (factor <= 0 || !factor.isFinite) return range;
  final span = range.max - range.min;
  final next = (span * factor).clamp(minBalanceSpan, maxBalanceSpan).toDouble();
  final t = anchorFraction.clamp(0.0, 1.0);
  final anchor = range.min + t * span;
  return BalanceExtents(anchor - t * next, anchor + (1 - t) * next);
}

/// How many fraction digits keep the visible span readable.
int moneyDigitsForSpan(double min, double max) {
  final span = (max - min).abs();
  if (span < 100 || (min.abs() < 100 && max.abs() < 100)) return 2;
  return 0;
}

enum AxisLane { year, month, week, day }

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

/// Whole calendar years overlapping the view. [AxisSegment.colorIndex]
/// alternates 0/1 so neighbouring years are distinguishable.
List<AxisSegment> yearSegments(DateTime viewStart, DateTime viewEnd) {
  if (!viewStart.isBefore(viewEnd)) return const [];
  var cursor = DateTime(viewStart.year);
  final out = <AxisSegment>[];
  while (cursor.isBefore(viewEnd) && out.length < 400) {
    final next = DateTime(cursor.year + 1);
    out.add(
      AxisSegment(
        start: cursor,
        end: next,
        lane: AxisLane.year,
        colorIndex: cursor.year.isEven ? 0 : 1,
      ),
    );
    cursor = next;
  }
  return out;
}

/// Whether months are too narrow to label, so the top lane shows years.
bool useYearLane(double plotWidth, double visibleDays) =>
    plotWidth / math.max(visibleDays, 0.001) * 30.44 < 34;

List<AxisSegment> weekSegments(DateTime viewStart, DateTime viewEnd) {
  if (!viewStart.isBefore(viewEnd)) return const [];
  final startDay = dateOnly(viewStart);
  var cursor = addCalendarDays(startDay, DateTime.monday - startDay.weekday);
  final out = <AxisSegment>[];
  while (cursor.isBefore(viewEnd) && out.length < 2000) {
    final next = addCalendarDays(cursor, 7);
    final weeks =
        (dayCoord(cursor) - dayCoord(DateTime(1970, 1, 5))).round() ~/ 7;
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
    final next = addCalendarDays(cursor, 1);
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
  final toRight =
      side == VertexLabelSide.aboveRight ||
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
    VertexLabelSide.aboveRight ||
    VertexLabelSide.aboveLeft => center.dy - gap - labelHeight,
    VertexLabelSide.belowRight => center.dy + radius + 2,
    VertexLabelSide.besideRight ||
    VertexLabelSide.besideLeft => center.dy - labelHeight / 2,
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

/// Zoom factor per In/Out button press or +/− key (smooth, small steps).
const double zoomStep = 1.25;

/// View after zooming [visibleDays] by [factor] (>1 zooms out) about the
/// centre of the view starting at [viewStart]. The span is clamped to the
/// zoom limits first, so the centre date stays fixed even at a limit.
({DateTime start, double days}) zoomAboutCenter(
  DateTime viewStart,
  double visibleDays,
  double factor,
) {
  final center = dayCoord(viewStart) + visibleDays / 2;
  final days = (visibleDays * factor)
      .clamp(minVisibleDays, maxVisibleDays)
      .toDouble();
  return (start: dateFromDayCoord(center - days / 2), days: days);
}

/// Whether another zoom step in that direction would change the span.
bool canZoomIn(double visibleDays) => visibleDays > minVisibleDays + 1e-6;
bool canZoomOut(double visibleDays) => visibleDays < maxVisibleDays - 1e-6;

/// Human description of a visible span of [days], e.g. "10 weeks".
String describeSpan(double days) {
  String n(num v, String unit) {
    final r = v.round();
    return '$r $unit${r == 1 ? '' : 's'}';
  }

  if (days < 13.5) return n(days, 'day');
  if (days < 88) return n(days / 7, 'week');
  if (days < 700) return n(days / 30.44, 'month');
  final years = days / 365.25;
  final rounded = (years * 2).round() / 2;
  return rounded == rounded.roundToDouble()
      ? n(rounded, 'year')
      : '${rounded.toStringAsFixed(1)} years';
}

/// Touch scrub: how close (logical px) a drag must start to a dot to scrub
/// its tooltip instead of panning the view.
const double scrubStartRadius = touchVertexHitRadius;

/// Hit radius around a vertex for a finger tap / scrub start (a fingertip
/// target, ~44 logical px) and for a precise mouse click.
const double touchVertexHitRadius = 44;
const double mouseVertexHitRadius = 18;

/// Vertex hit radius for a pointer of [kind]: generous for touch / stylus,
/// precise for a mouse or trackpad.
double vertexHitRadius(PointerDeviceKind kind) => switch (kind) {
  PointerDeviceKind.mouse || PointerDeviceKind.trackpad => mouseVertexHitRadius,
  _ => touchVertexHitRadius,
};

/// While scrubbing, a finger farther than this from every dot keeps the
/// last tooltip rather than jumping to a distant one.
const double scrubMaxDistance = 96;

/// Index of the point nearest [pos] by 2D distance, or null when there are
/// none or the nearest is farther than [maxDistance]. Ties keep the earlier.
int? nearestPointIndex(
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

/// Top-left of a [size] tooltip for a finger at [finger]: centred above it
/// with [lift] clearance so the finger never covers it; flips below when
/// there is no room above; clamped inside [bounds] with [margin].
Offset touchTooltipOrigin({
  required Offset finger,
  required Size size,
  required Size bounds,
  double lift = 56,
  double margin = 4,
}) {
  var left = finger.dx - size.width / 2;
  var top = finger.dy - lift - size.height;
  if (top < margin) top = finger.dy + lift;
  final maxLeft = math.max(margin, bounds.width - size.width - margin);
  final maxTop = math.max(margin, bounds.height - size.height - margin);
  left = left.clamp(margin, maxLeft).toDouble();
  top = top.clamp(margin, maxTop).toDouble();
  return Offset(left, top);
}

/// Min and max closing balance of [points] on or after [seedDate] (the
/// whole loaded series), or null when there are none.
BalanceExtents? balanceExtentsFrom(
  List<BalancePoint> points,
  DateTime seedDate,
) {
  final seed = dateOnly(seedDate);
  double? minV, maxV;
  for (final p in points) {
    if (dateOnly(p.date).isBefore(seed)) continue;
    final v = p.closingBalance.toDouble();
    if (minV == null || v < minV) minV = v;
    if (maxV == null || v > maxV) maxV = v;
  }
  return minV == null ? null : BalanceExtents(minV, maxV!);
}

/// Height of the day lane when day labels show: two horizontal lines
/// (weekday over numeral).
const double dayLaneLabelHeight = 30;

/// How day cells are labelled on the date axis.
enum DayLabelForm {
  /// "Wed" over "23rd".
  full,

  /// "W" over "23".
  compact,

  /// Numeral only ("23") on every [DayLabelPlan.every]th day; no weekday.
  sparse,
}

class DayLabelPlan {
  const DayLabelPlan(this.form, [this.every = 1]);
  final DayLabelForm form;

  /// Label every Nth day (1 = every day).
  final int every;

  @override
  bool operator ==(Object other) =>
      other is DayLabelPlan && other.form == form && other.every == every;
  @override
  int get hashCode => Object.hash(form, every);
  @override
  String toString() => 'DayLabelPlan($form, every $every)';
}

/// Picks the day label form for [cellWidth] px day cells from measured text
/// widths: [fullWidth] = widest of "Wed" / "28th", [compactWidth] = widest of
/// "W" / "28", [numeralWidth] = widest bare numeral. [pad] is the clearance
/// kept between neighbouring labels. Too narrow even for numerals: label
/// every 2nd, 3rd or 7th day (Mondays) so they never overlap.
DayLabelPlan dayLabelPlan({
  required double cellWidth,
  required double fullWidth,
  required double compactWidth,
  double? numeralWidth,
  double pad = 4,
}) {
  if (cellWidth >= fullWidth + pad) {
    return const DayLabelPlan(DayLabelForm.full);
  }
  if (cellWidth >= compactWidth + pad) {
    return const DayLabelPlan(DayLabelForm.compact);
  }
  final need = (numeralWidth ?? compactWidth) + pad;
  for (final n in const [2, 3, 7]) {
    if (cellWidth * n >= need) return DayLabelPlan(DayLabelForm.sparse, n);
  }
  return const DayLabelPlan(DayLabelForm.sparse, 14);
}

/// Whether [day] carries a label when labelling every [every]th day:
/// Mondays for weekly thinning; otherwise a pan-stable day-number rhythm.
bool dayLabelled(DateTime day, int every) {
  if (every <= 1) return true;
  if (every % 7 == 0) {
    final weeks =
        (dayCoord(day).round() - dayCoord(DateTime(2024, 1, 1)).round()) ~/ 7;
    return day.weekday == DateTime.monday && weeks % (every ~/ 7) == 0;
  }
  return dayCoord(day).round() % every == 0;
}

/// Opacity of the faint day separator lines for [dayPx] pixels per day:
/// none below 10px, fading in linearly to full strength at 16px.
double dayLineOpacity(double dayPx) {
  if (!dayPx.isFinite || dayPx < 10) return 0;
  return ((dayPx - 10) / 6).clamp(0.0, 1.0) * 0.85 + 0.15;
}

/// Which axis a two-finger pinch scales, from the fingers' separation at the
/// start of the pinch.
enum PinchAxis { time, balance, both }

/// Fingers within 30° of vertical scale the balance axis only; within 30° of
/// horizontal, time only; in between (diagonal), both.
PinchAxis pinchAxisFor(Offset separation) {
  final dx = separation.dx.abs(), dy = separation.dy.abs();
  if (dx < 1e-6 && dy < 1e-6) return PinchAxis.time;
  final angle = math.atan2(dy, dx) * 180 / math.pi; // 0 = horizontal
  if (angle >= 60) return PinchAxis.balance;
  if (angle <= 30) return PinchAxis.time;
  return PinchAxis.both;
}

/// [range] widened (if needed) so balance 0 is inside it, with a little
/// headroom past zero so the zero line is not on the plot edge.
BalanceExtents includeZero(BalanceExtents range) {
  if (range.min <= 0 && range.max >= 0) return range;
  final span = math.max(range.max, 0.0) - math.min(range.min, 0.0);
  final pad = span * 0.04;
  return range.min > 0
      ? BalanceExtents(-pad, range.max)
      : BalanceExtents(range.min, pad);
}

/// Default balance view for an account's currency scale [unit] (dollars per
/// grid step): about 10 units tall, always including the origin. When the
/// data in view ([dataMin]..[dataMax]) fits with zero inside 9 units it is
/// centred; otherwise the window sits on the side of zero the data is on.
BalanceExtents currencyScaleRange(double unit, double dataMin, double dataMax) {
  final lo = math.min(dataMin, 0.0), hi = math.max(dataMax, 0.0);
  final span = 10 * unit;
  // One-sided data keeps zero just inside the near edge (more room for it).
  if (lo >= 0 && hi <= 9.5 * unit) {
    return BalanceExtents(-0.5 * unit, 9.5 * unit);
  }
  if (hi <= 0 && lo >= -9.5 * unit) {
    return BalanceExtents(-9.5 * unit, 0.5 * unit);
  }
  if (hi - lo <= 9 * unit) {
    final pad = (span - (hi - lo)) / 2;
    return BalanceExtents(lo - pad, hi + pad);
  }
  return hi.abs() >= lo.abs()
      ? BalanceExtents(-0.5 * unit, 9.5 * unit)
      : BalanceExtents(-9.5 * unit, 0.5 * unit);
}

/// Factor for one press of the y-scale buttons.
const double yScaleStep = 1.25;

/// Half-size of the opening-balance diamond for a transaction dot [radius]:
/// a touch larger so it reads as the start of the line.
double seedVertexRadius(double radius) => math.max(4.0, radius + 1.8);

/// Leader line from a vertex label box [rect] to its dot at [center] with
/// [radius]: from the nearest point on the box to the dot's edge. Null when
/// the label sits right against the dot (gap under [minGap]) or covers it.
(Offset, Offset)? labelLeader(
  Rect rect,
  Offset center,
  double radius, {
  double minGap = 4,
}) {
  final from = Offset(
    center.dx.clamp(rect.left, rect.right).toDouble(),
    center.dy.clamp(rect.top, rect.bottom).toDouble(),
  );
  final d = center - from;
  final dist = d.distance;
  if (dist <= radius + minGap) return null;
  final to = center - d / dist * (radius + 1);
  return (from, to);
}

/// All occurrences on one calendar day, drawn as a single vertex.
class DayGroup {
  DayGroup(this.day, this.all);
  final DateTime day;

  /// Every occurrence that day, in series order (skipped ones included).
  final List<Occurrence> all;

  /// Occurrences that count (not skipped).
  List<Occurrence> get active => [
    for (final o in all)
      if (!o.skipped) o,
  ];

  /// Every occurrence that day is skipped: drawn hollow / faint.
  bool get allSkipped => active.isEmpty;

  /// Badge number: active occurrences, or all of them when all are skipped.
  int get count => allSkipped ? all.length : active.length;

  /// Net of the counted occurrences (skipped ones when all are skipped).
  double get net => (allSkipped ? all : active).fold(
    0.0,
    (sum, o) => sum + o.signedDelta.toDouble(),
  );

  bool get hasCredit => active.any((o) => o.signedDelta.toDouble() > 0);
  bool get hasDebit => active.any((o) => o.signedDelta.toDouble() < 0);

  /// Both money in and out that day.
  bool get mixed => hasCredit && hasDebit;
}

/// Groups occurrences by calendar day (DST-safe), keeping first-seen order
/// within a day; days ascending.
List<DayGroup> groupByDay(Iterable<Occurrence> occurrences) {
  final byDay = <DateTime, List<Occurrence>>{};
  for (final o in occurrences) {
    byDay.putIfAbsent(dateOnly(o.date), () => []).add(o);
  }
  final days = byDay.keys.toList()..sort();
  return [for (final d in days) DayGroup(d, byDay[d]!)];
}

/// Width of the label's count chip around a number [textWidth] wide:
/// at least round (min 18), with 5px side padding.
double countPillWidth(double textWidth) => math.max(18, textWidth + 10);

/// Px between the seed and Today lines when they fall on the same day.
const double markerGap = 3;

/// Duration of the eased zoom-button transitions (time and balance axes).
const Duration zoomEaseDuration = Duration(milliseconds: 280);

/// [a] → [b] at [t]: centre linearly, span geometrically, so a zoom about a
/// fixed centre keeps that centre fixed for every frame.
BalanceExtents lerpBalanceRange(BalanceExtents a, BalanceExtents b, double t) {
  final ca = (a.min + a.max) / 2, cb = (b.min + b.max) / 2;
  final sa = (a.max - a.min).abs(), sb = (b.max - b.min).abs();
  final span = sa > 0 && sb > 0
      ? math.exp(math.log(sa) + (math.log(sb) - math.log(sa)) * t)
      : sa + (sb - sa) * t;
  final c = ca + (cb - ca) * t;
  return BalanceExtents(c - span / 2, c + span / 2);
}

/// Visible span at [t] between [fromDays] and [toDays], geometric.
double lerpVisibleDays(double fromDays, double toDays, double t) =>
    math.exp(math.log(fromDays) + (math.log(toDays) - math.log(fromDays)) * t);

/// Year row label: "2026", or "’26" when narrow; blank when even that won't fit.
String yearLabel(int year, double width) {
  if (width >= 34) return '$year';
  if (width >= 22) return '\u2019${'${year % 100}'.padLeft(2, '0')}';
  return '';
}

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// Month row label: full name, 3-letter, or single letter by width.
String monthLabel(DateTime month, double width) {
  final name = _monthNames[month.month - 1];
  if (width >= name.length * 7.0 + 8) return name;
  if (width >= 30) return name.substring(0, 3);
  if (width >= 12) return name.substring(0, 1);
  return '';
}

/// Week row label (the week's Monday): "Oct 12", "12", or blank.
String weekLabel(DateTime monday, double width) {
  if (width >= 52) {
    return '${_monthNames[monday.month - 1].substring(0, 3)} ${monday.day}';
  }
  if (width >= 18) return '${monday.day}';
  return '';
}
