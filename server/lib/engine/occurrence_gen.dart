import '../domain/enums.dart';
import '../domain/models.dart';
import 'calendar_math.dart';

/// Expands events into occurrences inside a closed date window (§3.4).
class OccurrenceGenerator {
  /// Returns occurrences for [events] with dates in `[from, to]` inclusive.
  ///
  /// Skipped dates still appear with [Occurrence.skipped] = true when present
  /// in [skipped] (map of eventId → set of dates).
  /// Disabled events contribute nothing.
  static List<Occurrence> generate({
    required List<BudgetEvent> events,
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
    for (final event in events) {
      if (!event.enabled) continue;
      for (final date in datesForEvent(event, windowStart, windowEnd)) {
        final skipSet = skipped[event.id] ?? const <DateTime>{};
        final isSkipped =
            skipSet.any((d) => CalendarMath.compare(d, date) == 0);
        out.add(
          Occurrence(
            eventId: event.id,
            date: date,
            // A once-off override replaces this occurrence's amount.
            signedDelta: event.signedAmountOn(date),
            skipped: isSkipped,
          ),
        );
      }
    }
    return out;
  }

  /// Occurrence calendar dates for [event] in `[from, to]` inclusive.
  static List<DateTime> datesForEvent(
    BudgetEvent event,
    DateTime from,
    DateTime to,
  ) {
    final start = CalendarMath.dateOnly(event.startDate);
    final windowStart = CalendarMath.dateOnly(from);
    final windowEnd = CalendarMath.dateOnly(to);

    if (event.recurrenceMode == RecurrenceMode.once) {
      if (CalendarMath.compare(start, windowStart) >= 0 &&
          CalendarMath.compare(start, windowEnd) <= 0) {
        return [start];
      }
      return const [];
    }

    final interval = event.interval;
    final unit = event.unit;
    if (interval == null || unit == null) {
      throw ArgumentError('every-event requires interval and unit');
    }
    if (interval < 1) {
      throw ArgumentError('interval must be >= 1');
    }

    DateTime? hardEnd;
    int? maxCount;
    switch (event.endMode) {
      case EndMode.never:
        break;
      case EndMode.untilDate:
        hardEnd = CalendarMath.dateOnly(event.endDate!);
        break;
      case EndMode.count:
        maxCount = event.occurrenceCount;
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
  static int countThrough(BudgetEvent event, DateTime endInclusive) {
    final end = CalendarMath.dateOnly(endInclusive);
    return datesForEvent(
      event.copyWith(
        endMode:
            event.endMode == EndMode.never ? EndMode.untilDate : event.endMode,
        endDate: event.endMode == EndMode.never ? end : event.endDate,
        clearOccurrenceCount: event.endMode == EndMode.never,
      ),
      event.startDate,
      end,
    ).length;
  }

  /// Date of the Nth occurrence (1-based), or null if it cannot be produced.
  static DateTime? nthDate(BudgetEvent event, int n) {
    if (n < 1) return null;
    if (event.recurrenceMode == RecurrenceMode.once) {
      return n == 1 ? CalendarMath.dateOnly(event.startDate) : null;
    }
    final interval = event.interval!;
    final unit = event.unit!;
    final cursor = _occurrenceAt(
      CalendarMath.dateOnly(event.startDate),
      n - 1,
      interval,
      unit,
    );
    if (event.endMode == EndMode.untilDate &&
        CalendarMath.compare(cursor, event.endDate!) > 0) {
      return null;
    }
    return cursor;
  }
}
