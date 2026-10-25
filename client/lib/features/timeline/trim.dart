import '../../data/models.dart';
import 'occurrence_dates.dart';
import 'zoom_level.dart';

/// Whether [t] can be trimmed to end on [day]: a repeating, enabled series
/// that started on or before [day] and still runs after it.
bool canTrimOn(BudgetEvent t, DateTime day) {
  if (t.recurrenceMode != RecurrenceMode.every || !t.enabled) return false;
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
  if (end.isBefore(start)) return const TrimPlan.delete();
  return TrimPlan.end(trimmedEvent(t, end), end);
}
