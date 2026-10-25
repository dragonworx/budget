import '../../data/models.dart';
import 'zoom_level.dart';

/// Client-side occurrence date estimate for editor / solve preview (§3.3).
List<DateTime> estimateOccurrenceDates(
  BudgetEvent event, {
  int maxCount = 8,
  DateTime? through,
}) {
  if (!event.enabled && maxCount > 0) {
    // Still preview schedule for editing; enabled only affects balance.
  }

  final start = dateOnly(event.startDate);
  if (event.recurrenceMode == RecurrenceMode.once) {
    if (through != null && start.isAfter(dateOnly(through))) return const [];
    return [start];
  }

  final interval = event.interval ?? 1;
  final unit = event.unit ?? RecurrenceUnit.days;
  final limit = event.endMode == EndMode.count
      ? (event.occurrenceCount ?? maxCount).clamp(1, maxCount)
      : maxCount;
  final endCap = event.endMode == EndMode.untilDate && event.endDate != null
      ? dateOnly(event.endDate!)
      : through != null
      ? dateOnly(through)
      : null;

  final out = <DateTime>[];
  var cursor = start;
  var i = 0;
  while (out.length < limit) {
    if (endCap != null && cursor.isAfter(endCap)) break;
    out.add(cursor);
    i++;
    if (event.endMode == EndMode.count &&
        event.occurrenceCount != null &&
        i >= event.occurrenceCount!) {
      break;
    }
    // Anchored on the start (as the server does), so Jan 31 monthly gives
    // Feb 28, Mar 31, Apr 30 rather than drifting to the 28th.
    cursor = _addInterval(start, interval * i, unit);
    // Safety for runaway loops.
    if (i > 5000) break;
  }
  return out;
}

DateTime _addInterval(DateTime date, int interval, RecurrenceUnit unit) {
  switch (unit) {
    case RecurrenceUnit.days:
      return DateTime(date.year, date.month, date.day + interval);
    case RecurrenceUnit.weeks:
      return DateTime(date.year, date.month, date.day + 7 * interval);
    case RecurrenceUnit.months:
      return _addMonths(date, interval);
    case RecurrenceUnit.years:
      return _addMonths(date, interval * 12);
  }
}

DateTime _addMonths(DateTime date, int months) {
  final targetMonthZero = (date.month - 1) + months;
  final year = date.year + targetMonthZero ~/ 12;
  var month = targetMonthZero % 12;
  if (month < 0) month += 12;
  final monthOneBased = month + 1;
  final day = date.day.clamp(1, _daysInMonth(year, monthOneBased));
  return DateTime(year, monthOneBased, day);
}

int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;
