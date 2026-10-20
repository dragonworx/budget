import 'dart:math' as math;

import '../../data/models.dart';
import 'chart_geometry.dart';
import 'occurrence_dates.dart';
import 'zoom_level.dart';

/// What the timeline's Fit menu fits.
enum FitMode {
  /// Time to all of the pool's data, balance to that data's min/max.
  all('Fit all', 'A'),

  /// Balance to the data in the visible time range.
  vertical('Fit vertical', 'F'),

  /// Time to all of the pool's data; balance untouched.
  horizontal('Fit horizontal', 'H');

  const FitMode(this.label, this.shortcut);
  final String label;
  final String shortcut;

  /// Whether this mode moves the time range.
  bool get fitsTime => this != FitMode.vertical;

  /// Whether this mode refits the balance range.
  bool get fitsBalance => this != FitMode.horizontal;
}

/// A time range: local-midnight [start] spanning [days] calendar days.
class TimeSpan {
  const TimeSpan(this.start, this.days);
  final DateTime start;
  final double days;

  DateTime get end => addDays(start, days);

  @override
  bool operator ==(Object other) =>
      other is TimeSpan && other.start == start && other.days == days;
  @override
  int get hashCode => Object.hash(start, days);
  @override
  String toString() => 'TimeSpan($start, $days d)';
}

/// Whole calendar days from [a] to [b] (DST-safe).
int calendarDaysBetween(DateTime a, DateTime b) =>
    (dayCoord(dateOnly(b)) - dayCoord(dateOnly(a))).round();

/// Monday-start week containing [moment] (7 calendar days).
TimeSpan weekContaining(DateTime moment) {
  final day = dateOnly(moment);
  return TimeSpan(addCalendarDays(day, -(day.weekday - DateTime.monday)), 7);
}

/// Calendar month containing [moment] (28-31 calendar days).
TimeSpan monthContaining(DateTime moment) {
  final start = DateTime(moment.year, moment.month);
  final next = DateTime(moment.year, moment.month + 1);
  return TimeSpan(start, calendarDaysBetween(start, next).toDouble());
}

/// Day range [first, last] (inclusive) covering a pool's data: the seed
/// date and every enabled transaction's occurrences. Open-ended schedules
/// have no last occurrence, so they extend the range to [openEndedHorizon]
/// days past the later of today and the last finite date.
({DateTime first, DateTime last}) poolDataRange({
  required DateTime seedDate,
  required Iterable<Transaction> transactions,
  required DateTime today,
  int openEndedHorizon = 365,
}) {
  var first = dateOnly(seedDate);
  var last = first;
  var openEnded = false;
  for (final t in transactions) {
    if (!t.enabled) continue;
    final start = dateOnly(t.startDate);
    if (start.isBefore(first)) first = start;
    DateTime? end;
    if (t.recurrenceMode == RecurrenceMode.once) {
      end = start;
    } else if (t.endMode == EndMode.untilDate && t.endDate != null) {
      end = dateOnly(t.endDate!);
    } else if (t.endMode == EndMode.count && t.occurrenceCount != null) {
      final dates = estimateOccurrenceDates(
        t,
        maxCount: math.max(1, t.occurrenceCount!),
      );
      end = dates.isEmpty ? start : dates.last;
    } else {
      openEnded = true;
      end = start;
    }
    if (end.isAfter(last)) last = end;
  }
  if (openEnded) {
    final base = dateOnly(today).isAfter(last) ? dateOnly(today) : last;
    last = addCalendarDays(base, openEndedHorizon);
  }
  return (first: first, last: last);
}

/// Time span for days [first]..[last] inclusive: [first] at the left edge
/// (no leading padding) and [last] fully visible at the right. Ranges
/// shorter than the minimum zoom extend to the right; longer than the
/// maximum are cut at the right.
TimeSpan dataTimeSpan(DateTime first, DateTime last) {
  final data = calendarDaysBetween(first, last) + 1.0;
  final days = data.clamp(minVisibleDays, maxVisibleDays).toDouble();
  return TimeSpan(dateOnly(first), days);
}

/// Last calendar day visible in a view starting at [start] spanning [days]
/// (the end is exclusive: a 7-day view from Monday ends on Sunday).
DateTime lastVisibleDay(DateTime start, double days) =>
    dateOnly(addDays(start, math.max(0, days - 1e-6)));

/// The view showing [first]..[last] (inclusive) with [first] as the first
/// day clear of the left strip (as the timeline's left-align rule) and [last] the last
/// visible day ([stripWidth]: the plot's left strip, in pixels). The span is clamped to the zoom limits; a clamp keeps
/// [first] (or, with [anchorEnd], [last]) where asked.
(DateTime, double) viewForRange(
  DateTime first,
  DateTime last,
  double chartWidth, {
  required double stripWidth,
  bool anchorEnd = false,
}) {
  final f = (stripWidth / chartWidth).clamp(0.0, 0.9).toDouble();
  final n = dayCoord(dateOnly(last)) - dayCoord(dateOnly(first)) + 1;
  final want = n / (1 - f);
  final days = want.clamp(minVisibleDays, maxVisibleDays).toDouble();
  if (anchorEnd && (days - want).abs() > 1e-9) {
    return (addDays(dateOnly(last), 1 - days), days);
  }
  return (addDays(dateOnly(first), -f * days), days);
}
