import 'dart:math' as math;

import 'zoom_level.dart';
import 'chart_geometry.dart';
import 'fit_ranges.dart';

/// The timeline's view unit: what the unit dropdown selects, what ◀ ▶ shift
/// by, and what − / + step between. One is always selected.
///
/// Units align to calendar boundaries so the unit start is leftmost:
/// days to midnight, week-based units to Monday, month-based units to the
/// first of the month (2 months to Jan/Mar/May…, quarters to Jan/Apr/Jul/Oct,
/// 6 months to Jan/Jul) and years to 1 January.
enum ViewUnit {
  day('Day', 1),
  week('Week', 7),
  weeks2('2 weeks', 14),
  weeks3('3 weeks', 21),
  month('Month', 30.44),
  months2('2 months', 60.88),
  quarter('Quarter', 91.31),
  months6('6 months', 182.62),
  year('Year', 365.25);

  const ViewUnit(this.label, this.nominalDays);
  final String label;

  /// Typical length, for matching a free (pinched) span to a unit.
  final double nominalDays;

  int get _days => switch (this) {
    day => 1,
    week => 7,
    weeks2 => 14,
    weeks3 => 21,
    _ => 0,
  };

  int get _months => switch (this) {
    month => 1,
    months2 => 2,
    quarter => 3,
    months6 => 6,
    year => 12,
    _ => 0,
  };

  /// Start of the unit containing [moment].
  DateTime startOf(DateTime moment) {
    final d = dateOnly(moment);
    if (this == day) return d;
    if (_days > 0) return addCalendarDays(d, -(d.weekday - DateTime.monday));
    final m0 = d.month - 1; // 0-based month
    return DateTime(d.year, m0 - m0 % _months + 1);
  }

  /// [start] moved by [n] units, calendar-aware (DST-safe whole days;
  /// months by calendar, clamped to the month's last day).
  DateTime shift(DateTime start, int n) => _days > 0
      ? addCalendarDays(dateOnly(start), _days * n)
      : addMonthsClamped(dateOnly(start), _months * n);

  /// Exactly one unit from [start], in whole calendar days.
  TimeSpan spanFrom(DateTime start) {
    final s = dateOnly(start);
    return TimeSpan(s, calendarDaysBetween(s, shift(s, 1)).toDouble());
  }

  /// The unit containing [moment], unit start leftmost.
  TimeSpan spanContaining(DateTime moment) => spanFrom(startOf(moment));

  /// The span ◀ (n = -1) or ▶ (n = 1) moves to from a view starting at
  /// [viewStart]: one unit along when the view is aligned; otherwise ◀ snaps
  /// back to the unit containing the left edge and ▶ to the next one.
  TimeSpan step(DateTime viewStart, int n) {
    final aligned = startOf(viewStart);
    final isAligned = (dayCoord(viewStart) - dayCoord(aligned)).abs() < 1e-6;
    if (isAligned) return spanFrom(shift(aligned, n));
    return spanFrom(n < 0 ? aligned : shift(aligned, 1));
  }

  /// The unit whose typical length is closest (by ratio) to [days].
  static ViewUnit nearest(double days) {
    var best = ViewUnit.month;
    var bestScore = double.infinity;
    for (final u in values) {
      final score = (math.log(days / u.nominalDays)).abs();
      if (score < bestScore) {
        bestScore = score;
        best = u;
      }
    }
    return best;
  }
}

/// [date] plus [months] calendar months, clamped to the target month's last
/// day (31 Jan + 1 month = 28 or 29 Feb).
DateTime addMonthsClamped(DateTime date, int months) {
  final total = date.year * 12 + (date.month - 1) + months;
  final y = total ~/ 12, m = total % 12 + 1;
  final last = DateTime(y, m + 1, 0).day;
  return DateTime(y, m, math.min(date.day, last));
}
