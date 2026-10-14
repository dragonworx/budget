import '../domain/enums.dart';

/// Calendar-aware date arithmetic (§3.3).
class CalendarMath {
  CalendarMath._();

  /// Adds [interval] [unit]s to [date], clamping day-of-month for months/years.
  static DateTime add(DateTime date, int interval, RecurrenceUnit unit) {
    if (interval < 1) {
      throw ArgumentError.value(interval, 'interval', 'must be >= 1');
    }
    return switch (unit) {
      RecurrenceUnit.days => date.add(Duration(days: interval)),
      RecurrenceUnit.weeks => date.add(Duration(days: 7 * interval)),
      RecurrenceUnit.months => addMonths(date, interval),
      RecurrenceUnit.years => addMonths(date, interval * 12),
    };
  }

  /// Same day-of-month when possible; otherwise last day of target month.
  static DateTime addMonths(DateTime date, int months) {
    final targetMonthZero = (date.month - 1) + months;
    final year = date.year + targetMonthZero ~/ 12;
    var month = targetMonthZero % 12;
    if (month < 0) {
      // Should not happen for positive months, but keep safe.
      month += 12;
    }
    final monthOneBased = month + 1;
    final day = date.day.clamp(1, daysInMonth(year, monthOneBased));
    return DateTime.utc(year, monthOneBased, day);
  }

  /// Steps [date] back by [interval] [unit]s, clamping day-of-month.
  static DateTime subtract(DateTime date, int interval, RecurrenceUnit unit) {
    if (interval < 0) {
      throw ArgumentError.value(interval, 'interval', 'must be >= 0');
    }
    final d = dateOnly(date);
    return switch (unit) {
      RecurrenceUnit.days => d.subtract(Duration(days: interval)),
      RecurrenceUnit.weeks => d.subtract(Duration(days: 7 * interval)),
      RecurrenceUnit.months => _shiftMonths(d, -interval),
      RecurrenceUnit.years => _shiftMonths(d, -interval * 12),
    };
  }

  static DateTime _shiftMonths(DateTime date, int months) {
    final total = date.year * 12 + (date.month - 1) + months;
    final year = total ~/ 12;
    final month = total % 12 + 1;
    final day = date.day.clamp(1, daysInMonth(year, month));
    return DateTime.utc(year, month, day);
  }

  static int daysInMonth(int year, int month) {
    return DateTime.utc(year, month + 1, 0).day;
  }

  /// Inclusive day difference: days from [a] to [b] as (b - a) in days.
  static int daysBetween(DateTime a, DateTime b) {
    final aa = DateTime.utc(a.year, a.month, a.day);
    final bb = DateTime.utc(b.year, b.month, b.day);
    return bb.difference(aa).inDays;
  }

  static DateTime dateOnly(DateTime d) => DateTime.utc(d.year, d.month, d.day);

  static int compare(DateTime a, DateTime b) =>
      dateOnly(a).compareTo(dateOnly(b));
}
