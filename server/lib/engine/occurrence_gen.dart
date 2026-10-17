import '../domain/enums.dart';
import '../domain/models.dart';
import 'calendar_math.dart';

/// Expands transactions into occurrences inside a closed date window (§3.4).
class OccurrenceGenerator {
  /// Returns occurrences for [transactions] with dates in `[from, to]` inclusive.
  ///
  /// Skipped dates still appear with [Occurrence.skipped] = true when present
  /// in [skipped] (map of transactionId → set of dates).
  /// Disabled transactions contribute nothing.
  static List<Occurrence> generate({
    required List<Transaction> transactions,
    required DateTime from,
    required DateTime to,
    Map<String, Set<DateTime>> skipped = const {},
  }) {
    final windowStart = CalendarMath.dateOnly(from);
    final windowEnd = CalendarMath.dateOnly(to);
    if (CalendarMath.compare(windowEnd, windowStart) < 0) {
      throw ArgumentError('to must be >= from');
    }

    final out = <Occurrence>[];
    for (final transaction in transactions) {
      if (!transaction.enabled) continue;
      for (final date
          in datesForTransaction(transaction, windowStart, windowEnd)) {
        final skipSet = skipped[transaction.id] ?? const <DateTime>{};
        final isSkipped =
            skipSet.any((d) => CalendarMath.compare(d, date) == 0);
        out.add(
          Occurrence(
            transactionId: transaction.id,
            date: date,
            signedDelta: transaction.signedAmount,
            skipped: isSkipped,
          ),
        );
      }
    }
    return out;
  }

  /// Occurrence calendar dates for [transaction] in `[from, to]` inclusive.
  static List<DateTime> datesForTransaction(
    Transaction transaction,
    DateTime from,
    DateTime to,
  ) {
    final start = CalendarMath.dateOnly(transaction.startDate);
    final windowStart = CalendarMath.dateOnly(from);
    final windowEnd = CalendarMath.dateOnly(to);

    if (transaction.recurrenceMode == RecurrenceMode.once) {
      if (CalendarMath.compare(start, windowStart) >= 0 &&
          CalendarMath.compare(start, windowEnd) <= 0) {
        return [start];
      }
      return const [];
    }

    final interval = transaction.interval;
    final unit = transaction.unit;
    if (interval == null || unit == null) {
      throw ArgumentError('every-transaction requires interval and unit');
    }
    if (interval < 1) {
      throw ArgumentError('interval must be >= 1');
    }

    DateTime? hardEnd;
    int? maxCount;
    switch (transaction.endMode) {
      case EndMode.never:
        break;
      case EndMode.untilDate:
        hardEnd = CalendarMath.dateOnly(transaction.endDate!);
        break;
      case EndMode.count:
        maxCount = transaction.occurrenceCount;
        if (maxCount == null || maxCount < 1) {
          throw ArgumentError('occurrenceCount must be >= 1');
        }
    }

    final dates = <DateTime>[];
    // Safety cap: never walk more than a huge finite set in one call.
    const safetyCap = 100000;

    // Months/years advance from the original start so day-of-month is preserved
    // (Jan 31 → Feb 29 → Mar 31), not chained from a clamped previous date.
    for (var index = 0; index < safetyCap; index++) {
      if (maxCount != null && index >= maxCount) break;

      final cursor = _occurrenceAt(start, index, interval, unit);
      if (hardEnd != null && CalendarMath.compare(cursor, hardEnd) > 0) break;
      if (CalendarMath.compare(cursor, windowEnd) > 0) break;

      if (CalendarMath.compare(cursor, windowStart) >= 0) {
        dates.add(cursor);
      }
    }

    return dates;
  }

  /// 0-based occurrence index from [start].
  static DateTime _occurrenceAt(
    DateTime start,
    int index,
    int interval,
    RecurrenceUnit unit,
  ) {
    if (index == 0) return start;
    final steps = interval * index;
    return switch (unit) {
      RecurrenceUnit.days => start.add(Duration(days: steps)),
      RecurrenceUnit.weeks => start.add(Duration(days: 7 * steps)),
      RecurrenceUnit.months => CalendarMath.addMonths(start, steps),
      RecurrenceUnit.years => CalendarMath.addMonths(start, steps * 12),
    };
  }

  /// Counts occurrences from start through [endInclusive] (inclusive),
  /// respecting end rules. For `never`, counts until [endInclusive].
  static int countThrough(Transaction transaction, DateTime endInclusive) {
    final end = CalendarMath.dateOnly(endInclusive);
    return datesForTransaction(
      transaction.copyWith(
        endMode: transaction.endMode == EndMode.never
            ? EndMode.untilDate
            : transaction.endMode,
        endDate:
            transaction.endMode == EndMode.never ? end : transaction.endDate,
        clearOccurrenceCount: transaction.endMode == EndMode.never,
      ),
      transaction.startDate,
      end,
    ).length;
  }

  /// Date of the Nth occurrence (1-based), or null if it cannot be produced.
  static DateTime? nthDate(Transaction transaction, int n) {
    if (n < 1) return null;
    if (transaction.recurrenceMode == RecurrenceMode.once) {
      return n == 1 ? CalendarMath.dateOnly(transaction.startDate) : null;
    }
    final interval = transaction.interval!;
    final unit = transaction.unit!;
    final cursor = _occurrenceAt(
      CalendarMath.dateOnly(transaction.startDate),
      n - 1,
      interval,
      unit,
    );
    if (transaction.endMode == EndMode.untilDate &&
        CalendarMath.compare(cursor, transaction.endDate!) > 0) {
      return null;
    }
    return cursor;
  }
}
