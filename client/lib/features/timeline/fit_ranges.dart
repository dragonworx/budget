import 'dart:math' as math;

import '../../data/models.dart';
import 'chart_geometry.dart';
import 'occurrence_dates.dart';
import 'zoom_level.dart';

/// What the timeline's Fit menu fits.
enum FitMode {
  /// Time to all of the account's data, balance to that data's min/max.
  all('Fit all', 'A'),

  /// Balance to the data in the visible time range.
  vertical('Fit vertical', 'F'),

  /// Time to all of the account's data; balance untouched.
  horizontal('Fit horizontal', 'H'),

  /// Time and balance to the Monday-start week containing the view centre.
  week('Fit week', 'W'),

  /// Time and balance to the calendar month containing the view centre.
  month('Fit month', 'M');

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

/// Day range [first, last] (inclusive) covering an account's data: the seed
/// date and every enabled transaction's occurrences. Open-ended schedules
/// have no last occurrence, so they extend the range to [openEndedHorizon]
/// days past the later of today and the last finite date.
({DateTime first, DateTime last}) accountDataRange({
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

/// Time span showing days [first]..[last] inclusive with ~3% padding each
/// side (at least half a day), clamped to the chart's zoom limits around
/// the range's centre.
TimeSpan paddedTimeSpan(DateTime first, DateTime last) {
  final data = calendarDaysBetween(first, last) + 1.0;
  final pad = math.max(0.5, data * 0.03);
  var days = data + pad * 2;
  var startCoord = dayCoord(dateOnly(first)) - pad;
  final clamped = days.clamp(minVisibleDays, maxVisibleDays).toDouble();
  startCoord += (days - clamped) / 2;
  days = clamped;
  return TimeSpan(dateFromDayCoord(startCoord), days);
}
