import 'package:budget_recurrence/budget_recurrence.dart';

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
      if (!event.active) continue;
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

  /// Occurrence calendar dates for [event] in `[from, to]` inclusive: the
  /// days its structured rule fires (shared engine, budget_recurrence).
  static List<DateTime> datesForEvent(
    BudgetEvent event,
    DateTime from,
    DateTime to,
  ) {
    final windowStart = CalendarMath.dateOnly(from);
    final windowEnd = CalendarMath.dateOnly(to);
    if (event.recurrenceMode == RecurrenceMode.every &&
        (event.interval == null || event.unit == null)) {
      throw ArgumentError('every-event requires interval and unit');
    }
    int? maxCount;
    DateTime? hardEnd;
    switch (event.endMode) {
      case EndMode.never:
        break;
      case EndMode.untilDate:
        hardEnd = CalendarMath.dateOnly(event.endDate!);
      case EndMode.count:
        maxCount = event.occurrenceCount;
        if (maxCount == null || maxCount < 1) {
          throw ArgumentError('occurrenceCount must be >= 1');
        }
    }
    if (event.recurrenceMode == RecurrenceMode.once) {
      // A one-off ignores its end (as before).
      hardEnd = null;
      maxCount = null;
    }
    return fireDates(
      event.frequency,
      event.startDate,
      from: windowStart,
      to: windowEnd,
      until: hardEnd,
      count: maxCount,
      cap: 100000,
    );
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
    return nthFireDate(
      event.frequency,
      event.startDate,
      n,
      until: event.endMode == EndMode.untilDate ? event.endDate : null,
    );
  }
}
