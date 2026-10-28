import 'package:budget_recurrence/budget_recurrence.dart';

import '../../data/models.dart';
import 'zoom_level.dart';

/// [d]'s calendar day as the shared engine's UTC date.
DateTime toRuleDate(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// The engine's UTC date as the client's local date-only DateTime.
DateTime fromRuleDate(DateTime d) => DateTime(d.year, d.month, d.day);

/// The first occurrence dates of [event] (at most [maxCount], through
/// [through] when given), from its structured rule: the same shared
/// engine (package:budget_recurrence) the server's balance uses, so the
/// graph, calendar, dots and totals match it day for day.
List<DateTime> estimateOccurrenceDates(
  BudgetEvent event, {
  int maxCount = 8,
  DateTime? through,
}) {
  final f = event.frequency;
  final start = dateOnly(event.startDate);
  if (!f.repeats) {
    if (through != null && start.isAfter(dateOnly(through))) return const [];
    return [start];
  }
  final limit = event.endMode == EndMode.count
      ? (event.occurrenceCount ?? maxCount).clamp(1, maxCount)
      : maxCount;
  final endCap = event.endMode == EndMode.untilDate && event.endDate != null
      ? toRuleDate(event.endDate!)
      : through != null
      ? toRuleDate(through)
      : null;
  final out = <DateTime>[];
  for (final d in fireSequence(f, toRuleDate(start))) {
    if (out.length >= limit || out.length > 5000) break;
    if (endCap != null && d.isAfter(endCap)) break;
    out.add(fromRuleDate(d));
  }
  return out;
}

/// Occurrence dates of [t] in [lo]..[hi] (inclusive), honouring its end
/// (a count counts from the start).
List<DateTime> occurrenceDatesIn(BudgetEvent t, DateTime lo, DateTime hi) {
  final f = t.frequency;
  return [
    for (final d in fireDates(
      f,
      toRuleDate(t.startDate),
      from: toRuleDate(lo),
      to: toRuleDate(hi),
      until: f.repeats && t.endMode == EndMode.untilDate && t.endDate != null
          ? toRuleDate(t.endDate!)
          : null,
      count: f.repeats && t.endMode == EndMode.count ? t.occurrenceCount : null,
    ))
      fromRuleDate(d),
  ];
}
