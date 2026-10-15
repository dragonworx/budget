import 'package:intl/intl.dart';

import '../../data/models.dart';
import 'occurrence_dates.dart';
import 'zoom_level.dart';

/// "Mon 12 Jan 2026".
String formatOccurrenceDate(DateTime date) =>
    DateFormat('EEE d MMM y').format(date);

/// Human recurrence summary: "One-off", "Every 2 weeks, ends 30 Jun 2027",
/// "Every month, 12 times".
String describeRecurrence(Transaction t) {
  if (t.recurrenceMode == RecurrenceMode.once) return 'One-off';
  final n = t.interval ?? 1;
  final unit = (t.unit ?? RecurrenceUnit.months).name;
  final every = n == 1
      ? 'Every ${unit.substring(0, unit.length - 1)}'
      : 'Every $n $unit';
  return switch (t.endMode) {
    EndMode.untilDate when t.endDate != null =>
      '$every, ends ${DateFormat('d MMM y').format(t.endDate!)}',
    EndMode.count when t.occurrenceCount != null =>
      '$every, ${t.occurrenceCount} times',
    _ => every,
  };
}

/// "Occurrence 3 of 12" for counted schedules (null otherwise or when
/// [date] is not one of its dates).
String? occurrenceOrdinal(Transaction t, DateTime date) {
  if (t.recurrenceMode != RecurrenceMode.every ||
      t.endMode != EndMode.count ||
      t.occurrenceCount == null) {
    return null;
  }
  final dates = estimateOccurrenceDates(t, maxCount: t.occurrenceCount!);
  final i = dates.indexOf(dateOnly(date));
  return i < 0 ? null : 'Occurrence ${i + 1} of ${t.occurrenceCount}';
}
