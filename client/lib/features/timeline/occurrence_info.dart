import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:intl/intl.dart';

import '../../data/models.dart';
import 'occurrence_dates.dart';
import 'zoom_level.dart';

/// "Mon 12 Jan 2026".
String formatOccurrenceDate(DateTime date) =>
    DateFormat('EEE d MMM y').format(date);

/// English ordinal suffix for a day of the month: 1st, 2nd, 3rd, 4th …
/// 11th, 12th, 13th … 21st, 22nd, 23rd … 31st.
String ordinalSuffix(int n) {
  final h = n % 100;
  if (h >= 11 && h <= 13) return 'th';
  return switch (n % 10) {
    1 => 'st',
    2 => 'nd',
    3 => 'rd',
    _ => 'th',
  };
}

/// [n] with its ordinal suffix ("14th").
String ordinal(int n) => '$n${ordinalSuffix(n)}';

/// The selected dot's date: long weekday, ordinal day, long month, and the
/// year only outside the current year ([now], default today):
/// "Wednesday 14th October", "Friday 1st January 2027".
String formatSelectedDate(DateTime date, {DateTime? now}) {
  final year = (now ?? DateTime.now()).year;
  final base =
      '${DateFormat('EEEE').format(date)} ${ordinal(date.day)} '
      '${DateFormat('MMMM').format(date)}';
  return date.year == year ? base : '$base ${date.year}';
}

/// Human recurrence summary from the structured rule: "One-off", "Every
/// 2 weeks on Mon, Wed, ends 30 Jun 2027", "Monthly on the 1st and 15th,
/// 12 times".
String describeRecurrence(BudgetEvent t) {
  if (t.recurrenceMode == RecurrenceMode.once) return 'One-off';
  final every = describeFrequency(
    t.frequency,
    toRuleDate(t.startDate),
    compact: true,
  );
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
String? occurrenceOrdinal(BudgetEvent t, DateTime date) {
  if (t.recurrenceMode != RecurrenceMode.every ||
      t.endMode != EndMode.count ||
      t.occurrenceCount == null) {
    return null;
  }
  final dates = estimateOccurrenceDates(t, maxCount: t.occurrenceCount!);
  final i = dates.indexOf(dateOnly(date));
  return i < 0 ? null : 'Occurrence ${i + 1} of ${t.occurrenceCount}';
}
