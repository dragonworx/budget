import 'dart:math' as math;

import '../../data/models.dart';
import 'occurrence_dates.dart';
import 'zoom_level.dart';

/// What releasing a date-axis drag does, by where the pointer is. Only
/// add or discard: a drag never trims (that is the dot popup's ⋮ menu).
enum PickZone {
  /// On (or up to the cancel margin above) the date footer: pin the day,
  /// whose "+" adds a transaction on it.
  create,

  /// Higher up: release cancels.
  discard,
}

/// Pixels above the footer that count as the footer (finger slop).
const double pickFooterSlop = 16;

/// Zone for a pick at screen [y]: up to [cancelMargin] above the footer
/// still adds, higher cancels.
PickZone pickZone({
  required double y,
  required double axisTop,
  double cancelMargin = 56,
}) {
  if (y >= axisTop - math.max(pickFooterSlop, cancelMargin)) {
    return PickZone.create;
  }
  return PickZone.discard;
}

/// Whether [t] can be trimmed to end on [day]: a repeating, enabled series
/// that started on or before [day] and still runs after it.
bool canTrimOn(Transaction t, DateTime day) {
  if (t.recurrenceMode != RecurrenceMode.every || !t.enabled) return false;
  final d = dateOnly(day);
  if (dateOnly(t.startDate).isAfter(d)) return false;
  final end = t.endMode == EndMode.untilDate ? t.endDate : null;
  return end == null || dateOnly(end).isAfter(d);
}

/// Whether the dot popup offers "Trim" on [t]'s occurrence on [day]: a
/// trimmable series ([canTrimOn]) with [day] one of its dates and at least
/// one occurrence after it (hidden on what is already the last one).
bool canTrimAtOccurrence(Transaction t, DateTime day) {
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
Transaction trimmedTransaction(Transaction t, DateTime day) => t.copyWith(
  endMode: EndMode.untilDate,
  endDate: dateOnly(day),
  clearOccurrenceCount: true,
);
