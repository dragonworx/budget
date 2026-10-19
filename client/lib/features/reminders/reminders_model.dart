import 'package:decimal/decimal.dart';

import '../../data/models.dart';
import '../timeline/zoom_level.dart';

/// One dated occurrence of a transaction series.
class ReminderItem {
  const ReminderItem({required this.transaction, required this.date});

  final Transaction transaction;
  final DateTime date;

  /// A once-off override of this date, if any.
  OccurrenceOverride? get override => transaction.overrideOn(date);

  bool get isGain =>
      (override?.direction ?? transaction.direction) ==
      TransactionDirection.credit;

  /// This occurrence's amount (its override, else the series amount).
  Decimal get amount => override?.amount ?? transaction.amount;
  Decimal get signed => isGain ? amount : -amount;
}

/// Gains / losses for one day (or any group of items).
class DayTotals {
  const DayTotals({
    required this.gains,
    required this.losses,
    required this.count,
  });

  static final empty = DayTotals(
    gains: Decimal.zero,
    losses: Decimal.zero,
    count: 0,
  );

  /// Sum of credits (positive).
  final Decimal gains;

  /// Sum of debits (positive magnitude).
  final Decimal losses;
  final int count;

  Decimal get net => gains - losses;

  DayTone get tone {
    if (count == 0) return DayTone.none;
    final hasGain = gains > Decimal.zero;
    final hasLoss = losses > Decimal.zero;
    if (hasGain && hasLoss) return DayTone.mixed;
    return hasGain ? DayTone.gain : DayTone.loss;
  }

  factory DayTotals.of(Iterable<ReminderItem> items) {
    var g = Decimal.zero, l = Decimal.zero;
    var n = 0;
    for (final i in items) {
      n++;
      if (i.isGain) {
        g += i.amount;
      } else {
        l += i.amount;
      }
    }
    return DayTotals(gains: g, losses: l, count: n);
  }
}

enum DayTone { none, gain, loss, mixed }

/// List range choices for the dropdown.
enum ReminderRange {
  today('Today'),
  week('1 Week'),
  month('1 Month');

  const ReminderRange(this.label);
  final String label;

  /// Last day (inclusive) of the range starting on [today].
  DateTime endFrom(DateTime today) {
    final t = dateOnly(today);
    return switch (this) {
      ReminderRange.today => t,
      ReminderRange.week => DateTime(t.year, t.month, t.day + 6),
      ReminderRange.month => _addMonths(t, 1).subtract(const Duration(days: 1)),
    };
  }
}

/// Expands enabled transactions into occurrences within [from]..[to]
/// (inclusive, date-only), using the same start-anchored schedule as the
/// server and the timeline. [skipped] holds "transactionId|yyyy-mm-dd" keys
/// for occurrences the server reports as skipped.
List<ReminderItem> expandOccurrences(
  Iterable<Transaction> transactions, {
  required DateTime from,
  required DateTime to,
  Set<String> skipped = const {},
}) {
  final lo = dateOnly(from), hi = dateOnly(to);
  final out = <ReminderItem>[];
  for (final t in transactions) {
    if (!t.enabled) continue;
    for (final d in occurrenceDatesBetween(t, lo, hi)) {
      if (skipped.contains(skipKey(t.id, d))) continue;
      out.add(ReminderItem(transaction: t, date: d));
    }
  }
  out.sort((a, b) {
    final c = a.date.compareTo(b.date);
    if (c != 0) return c;
    // Gains first, then larger amounts, then name.
    if (a.isGain != b.isGain) return a.isGain ? -1 : 1;
    final m = b.amount.compareTo(a.amount);
    return m != 0 ? m : a.transaction.name.compareTo(b.transaction.name);
  });
  return out;
}

String skipKey(String transactionId, DateTime date) {
  final d = dateOnly(date);
  return '$transactionId|${d.year}-${d.month}-${d.day}';
}

/// Occurrence dates of [t] that fall in [lo]..[hi] (date-only, inclusive).
Iterable<DateTime> occurrenceDatesBetween(
  Transaction t,
  DateTime lo,
  DateTime hi,
) sync* {
  final start = dateOnly(t.startDate);
  if (t.recurrenceMode == RecurrenceMode.once) {
    if (!start.isBefore(lo) && !start.isAfter(hi)) yield start;
    return;
  }
  final interval = (t.interval ?? 1).clamp(1, 100000);
  final unit = t.unit ?? RecurrenceUnit.days;
  final endCap = t.endMode == EndMode.untilDate && t.endDate != null
      ? dateOnly(t.endDate!)
      : null;
  final maxCount = t.endMode == EndMode.count ? t.occurrenceCount : null;

  // Jump close to [lo] rather than walking from the start.
  var i = 0;
  if (start.isBefore(lo)) {
    final days = lo.difference(start).inDays;
    i = switch (unit) {
      RecurrenceUnit.days => days ~/ interval,
      RecurrenceUnit.weeks => days ~/ (7 * interval),
      RecurrenceUnit.months =>
        ((lo.year - start.year) * 12 + lo.month - start.month) ~/ interval,
      RecurrenceUnit.years => (lo.year - start.year) ~/ interval,
    };
    i = (i - 1).clamp(0, 1 << 30);
  }
  var guard = 0;
  while (guard++ < 2000) {
    if (maxCount != null && i >= maxCount) return;
    final d = _step(start, interval * i, unit);
    if (d.isAfter(hi)) return;
    if (endCap != null && d.isAfter(endCap)) return;
    if (!d.isBefore(lo)) yield d;
    i++;
  }
}

DateTime _step(DateTime start, int n, RecurrenceUnit unit) => switch (unit) {
  RecurrenceUnit.days => DateTime(start.year, start.month, start.day + n),
  RecurrenceUnit.weeks => DateTime(start.year, start.month, start.day + 7 * n),
  RecurrenceUnit.months => _addMonths(start, n),
  RecurrenceUnit.years => _addMonths(start, 12 * n),
};

DateTime _addMonths(DateTime date, int months) {
  final zero = (date.month - 1) + months;
  final year = date.year + zero ~/ 12;
  final month = zero % 12 + 1;
  final last = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, date.day.clamp(1, last));
}

/// Items grouped by date (ascending), preserving item order within a day.
Map<DateTime, List<ReminderItem>> groupByDay(Iterable<ReminderItem> items) {
  final out = <DateTime, List<ReminderItem>>{};
  for (final i in items) {
    out.putIfAbsent(dateOnly(i.date), () => []).add(i);
  }
  final keys = out.keys.toList()..sort();
  return {for (final k in keys) k: out[k]!};
}

/// The 6x7 (or 5x7) Monday-first grid of dates covering [month].
List<DateTime> monthGrid(DateTime month) {
  final first = DateTime(month.year, month.month, 1);
  final lead = (first.weekday - DateTime.monday) % 7;
  final start = DateTime(first.year, first.month, 1 - lead);
  final days = DateTime(month.year, month.month + 1, 0).day;
  final cells = ((lead + days + 6) ~/ 7) * 7;
  return [
    for (var i = 0; i < cells; i++)
      DateTime(start.year, start.month, start.day + i),
  ];
}

/// Calendar on the first half of the longest side: side-by-side when the
/// area is wider than tall, stacked otherwise.
bool remindersSideBySide(double width, double height) => width > height;
