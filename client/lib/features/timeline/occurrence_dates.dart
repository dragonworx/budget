import '../../data/models.dart';
import 'zoom_level.dart';

/// Client-side occurrence date estimate for editor / solve preview (§3.3).
List<DateTime> estimateOccurrenceDates(
  Transaction transaction, {
  int maxCount = 8,
  DateTime? through,
}) {
  if (!transaction.enabled && maxCount > 0) {
    // Still preview schedule for editing; enabled only affects balance.
  }

  final start = dateOnly(transaction.startDate);
  if (transaction.recurrenceMode == RecurrenceMode.once) {
    if (through != null && start.isAfter(dateOnly(through))) return const [];
    return [start];
  }

  final interval = transaction.interval ?? 1;
  final unit = transaction.unit ?? RecurrenceUnit.days;
  final limit = transaction.endMode == EndMode.count
      ? (transaction.occurrenceCount ?? maxCount).clamp(1, maxCount)
      : maxCount;
  final endCap = transaction.endMode == EndMode.untilDate && transaction.endDate != null
      ? dateOnly(transaction.endDate!)
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
    if (transaction.endMode == EndMode.count &&
        transaction.occurrenceCount != null &&
        i >= transaction.occurrenceCount!) {
      break;
    }
    cursor = _addInterval(cursor, interval, unit);
    // Safety for runaway loops.
    if (i > 5000) break;
  }
  return out;
}

DateTime _addInterval(DateTime date, int interval, RecurrenceUnit unit) {
  switch (unit) {
    case RecurrenceUnit.days:
      return date.add(Duration(days: interval));
    case RecurrenceUnit.weeks:
      return date.add(Duration(days: 7 * interval));
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
