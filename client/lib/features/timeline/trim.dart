import '../../data/models.dart';
import 'occurrence_dates.dart';
import 'zoom_level.dart';

/// Whether [t] can be trimmed to end on [day]: a repeating, enabled series
/// that started on or before [day] and still runs after it.
bool canTrimOn(BudgetEvent t, DateTime day) {
  if (t.recurrenceMode != RecurrenceMode.every || !t.active) return false;
  final d = dateOnly(day);
  if (dateOnly(t.startDate).isAfter(d)) return false;
  final end = t.endMode == EndMode.untilDate ? t.endDate : null;
  return end == null || dateOnly(end).isAfter(d);
}

/// Whether the dot popup offers "Trim" on [t]'s occurrence on [day]: a
/// trimmable series ([canTrimOn]) with [day] one of its dates and at least
/// one occurrence after it (hidden on what is already the last one).
bool canTrimAtOccurrence(BudgetEvent t, DateTime day) {
  final d = dateOnly(day);
  if (!canTrimOn(t, d)) return false;
  if (t.endMode == EndMode.never) return true;
  final dates = estimateOccurrenceDates(
    t,
    maxCount: t.endMode == EndMode.count ? (t.occurrenceCount ?? 1) : 1 << 30,
  );
  return dates.any((x) => x.isAfter(d));
}

/// [t] ending on [day] (inclusive, as the editor's "On date" end).
BudgetEvent trimmedEvent(BudgetEvent t, DateTime day) => t.copyWith(
  endMode: EndMode.untilDate,
  endDate: dateOnly(day),
  clearOccurrenceCount: true,
);

/// What "Trim From Here" on a dot's day does to its event.
///
/// End dates are inclusive (the editor's "On date" end and the server's
/// `until_date`: a series occurs on or before its endDate), so trimming
/// from [day] ends the series on the day before: [day]'s occurrence and
/// every later one go, earlier ones stay. On a ring dot (the series runs
/// through [day] but does not occur on it) the same rule keeps everything
/// before [day]. A transfer's peer row mirrors the new end (the server
/// mirrors schedule edits and deletes onto both sides).
class TrimPlan {
  const TrimPlan.end(BudgetEvent this.trimmed, DateTime this.end)
    : deletes = false;
  const TrimPlan.delete() : trimmed = null, end = null, deletes = true;

  /// The event with its new (inclusive) end; null when [deletes].
  final BudgetEvent? trimmed;

  /// The new last day of the series; null when [deletes].
  final DateTime? end;

  /// Nothing before the trim day would remain (a once-off, or trimming
  /// from the first occurrence): trimming deletes the event.
  final bool deletes;
}

/// [t] trimmed from [day] (see [TrimPlan]); null when nothing of [t]
/// occurs on or after [day], so there is nothing to trim.
TrimPlan? trimFromHere(BudgetEvent t, DateTime day) {
  final d = dateOnly(day);
  final start = dateOnly(t.startDate);
  if (t.recurrenceMode != RecurrenceMode.every) {
    return start.isBefore(d) ? null : const TrimPlan.delete();
  }
  if (t.endMode == EndMode.untilDate &&
      t.endDate != null &&
      dateOnly(t.endDate!).isBefore(d)) {
    return null;
  }
  if (t.endMode == EndMode.count) {
    final dates = estimateOccurrenceDates(t, maxCount: t.occurrenceCount ?? 1);
    if (!dates.any((x) => !dateOnly(x).isBefore(d))) return null;
  }
  final end = DateTime(d.year, d.month, d.day - 1);
  // Nothing fires before [day] (the rule's first firing can be after the
  // start date, e.g. a Wednesday start on a Mon-only rule): delete.
  final first = estimateOccurrenceDates(t, maxCount: 1);
  if (end.isBefore(start) || first.isEmpty || !first.first.isBefore(d)) {
    return const TrimPlan.delete();
  }
  return TrimPlan.end(trimmedEvent(t, end), end);
}

/// What the day pick's ✂ ("End all events on this day") does to one
/// event (the server applies the same rule, `endOnDayPlan`).
enum DayTrim {
  /// The series ends on the day (inclusive): the day's own occurrence
  /// stays, every later one goes.
  end,

  /// It starts after the day, so nothing of it would remain: deleted.
  delete,
}

/// [t] under "end all events on [day]": null when nothing of it falls
/// after [day] (once-offs on or before it, series already ending by then)
/// or it is excluded from the balance.
DayTrim? endOnDay(BudgetEvent t, DateTime day) {
  if (!t.active) return null;
  final d = dateOnly(day);
  if (dateOnly(t.startDate).isAfter(d)) return DayTrim.delete;
  // A rule whose first firing is after [day] keeps nothing (the server's
  // endOnDayPlan does the same).
  if (t.recurrenceMode == RecurrenceMode.every) {
    final first = estimateOccurrenceDates(t, maxCount: 1);
    if (first.isNotEmpty && first.first.isAfter(d)) return DayTrim.delete;
  }
  return canTrimAtOccurrence(t, d) ? DayTrim.end : null;
}

/// [events] under [endOnDay]: the ones that end on [day], the ones
/// deleted. Empty: the ✂ has nothing to do.
DayTrimPlan planEndAllOn(Iterable<BudgetEvent> events, DateTime day) {
  final ended = <BudgetEvent>[], deleted = <BudgetEvent>[];
  for (final t in events) {
    switch (endOnDay(t, day)) {
      case DayTrim.end:
        ended.add(t);
      case DayTrim.delete:
        deleted.add(t);
      case null:
    }
  }
  return DayTrimPlan(ended, deleted);
}

class DayTrimPlan {
  const DayTrimPlan(this.ended, this.deleted);
  final List<BudgetEvent> ended;
  final List<BudgetEvent> deleted;
  bool get isEmpty => ended.isEmpty && deleted.isEmpty;
}
