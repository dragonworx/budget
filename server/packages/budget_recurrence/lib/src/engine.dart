import 'frequency.dart';

/// Calendar dates as UTC midnights (date-only, DST free). Inputs may be
/// local or UTC: only their year / month / day are read.
DateTime civil(DateTime d) => DateTime.utc(d.year, d.month, d.day);

int daysInMonth(int year, int month) => DateTime.utc(year, month + 1, 0).day;

/// [start] moved by [months] months, its day-of-month rolled to the target
/// month's last day when short (measured from [start]'s own day).
DateTime addMonthsRolled(DateTime start, int months) {
  final total = start.year * 12 + (start.month - 1) + months;
  final y = total ~/ 12, m = total % 12 + 1;
  final dim = daysInMonth(y, m);
  return DateTime.utc(y, m, start.day > dim ? dim : start.day);
}

DateTime _addDays(DateTime d, int n) =>
    DateTime.utc(d.year, d.month, d.day + n);

/// Every firing of [f] from [start] on, ascending and unique (unbounded for
/// a repeating rule: bound it with [fireDates] or `take`). Count-based ends
/// count these firings (a skipped date still counts as one).
Iterable<DateTime> fireSequence(Frequency f, DateTime start) sync* {
  final s = civil(start);
  final n = f.interval;
  switch (f.rule) {
    case FreqRule.once:
      yield s;
    case FreqRule.daily:
      for (var k = 0;; k++) {
        yield _addDays(s, k * n);
      }
    case FreqRule.weekly:
    case FreqRule.everyNWeeks:
      if (f.days.isEmpty) {
        for (var k = 0;; k++) {
          yield _addDays(s, 7 * k * n);
        }
      }
      // Monday of the start's week; live weeks are it + k·N weeks.
      final monday = _addDays(s, 1 - s.weekday);
      for (var k = 0;; k++) {
        final ws = _addDays(monday, 7 * k * n);
        for (final wd in f.days) {
          final d = _addDays(ws, wd - 1);
          if (!d.isBefore(s)) yield d;
        }
      }
    case FreqRule.monthly:
    case FreqRule.everyNMonths:
      if (f.days.isEmpty) {
        for (var k = 0;; k++) {
          yield addMonthsRolled(s, k * n);
        }
      }
      for (var k = 0;; k++) {
        final total = s.year * 12 + (s.month - 1) + k * n;
        final y = total ~/ 12, m = total % 12 + 1;
        final dim = daysInMonth(y, m);
        var last = 0;
        for (final md in f.days) {
          final day = md > dim ? dim : md;
          if (day == last) continue; // two days rolled onto the last day
          last = day;
          final d = DateTime.utc(y, m, day);
          if (!d.isBefore(s)) yield d;
        }
      }
  }
}

/// The dates [f] fires on in `[from, to]` (inclusive), for a series that
/// starts on [start] and ends on [until] (inclusive) or after [count]
/// firings (counted from the start, before the window). [cap] bounds the
/// walk for safety.
List<DateTime> fireDates(
  Frequency f,
  DateTime start, {
  required DateTime from,
  required DateTime to,
  DateTime? until,
  int? count,
  int cap = 200000,
}) {
  final lo = civil(from), hi = civil(to);
  final end = until == null ? null : civil(until);
  final out = <DateTime>[];
  if (hi.isBefore(lo)) return out;
  if (count != null && count < 1) return out;
  var i = 0;
  for (final d in fireSequence(f, start)) {
    if (count != null && i >= count) break;
    if (i++ >= cap) break;
    if (end != null && d.isAfter(end)) break;
    if (d.isAfter(hi)) break;
    if (!d.isBefore(lo)) out.add(d);
  }
  return out;
}

/// The [n]th firing (1-based), honouring [until]; null past the end.
DateTime? nthFireDate(Frequency f, DateTime start, int n, {DateTime? until}) {
  if (n < 1) return null;
  if (!f.repeats) return n == 1 ? civil(start) : null;
  final d = fireSequence(f, start).elementAt(n - 1);
  if (until != null && d.isAfter(civil(until))) return null;
  return d;
}

/// Whether [f] (from [start]) fires on [date], ignoring any end.
bool firesOn(Frequency f, DateTime start, DateTime date) =>
    fireDates(f, start, from: date, to: date).isNotEmpty;
