import '../../data/models.dart';
import 'chart_geometry.dart';
import 'zoom_level.dart';

/// Summary of a day-snapped selection [start]..[end] (both inclusive).
///
/// Definitions (same data the chart draws):
/// - [startBalance]: opening balance of the start day = closing balance of
///   the day before (the seed balance when the start is on/before the seed).
/// - [endBalance]: closing balance of the end day.
/// - [gains] / [losses]: sums of the counted (not skipped) credits / debits
///   dated within the range; [losses] is negative. Transfers count on the
///   side they hit this account.
/// - [occurrences]: counted occurrences in the range, in date order.
class PeriodSummary {
  const PeriodSummary({
    required this.start,
    required this.end,
    required this.startBalance,
    required this.endBalance,
    required this.gains,
    required this.losses,
    required this.occurrences,
  });

  final DateTime start;
  final DateTime end;
  final double startBalance;
  final double endBalance;
  final double gains;
  final double losses;
  final List<Occurrence> occurrences;

  double get net => endBalance - startBalance;
  int get days =>
      DateTime.utc(
        end.year,
        end.month,
        end.day,
      ).difference(DateTime.utc(start.year, start.month, start.day)).inDays +
      1;

  /// Net change as a percentage of the start balance; null when the start
  /// is zero or negative (a percentage would mislead).
  double? get percent => startBalance > 0 ? net / startBalance * 100 : null;
}

/// Orders [a]/[b] into an inclusive (start, end) day range.
(DateTime, DateTime) orderedDays(DateTime a, DateTime b) {
  final x = dateOnly(a), y = dateOnly(b);
  return x.isAfter(y) ? (y, x) : (x, y);
}

PeriodSummary summarizePeriod({
  required BalanceSeries series,
  required DateTime start,
  required DateTime end,
  required DateTime seedDate,
  double? seedBalance,
}) {
  final (s, e) = orderedDays(start, end);
  final seed = dateOnly(seedDate);
  final points = [...series.points]..sort((a, b) => a.date.compareTo(b.date));
  final counted = [
    for (final o in series.occurrences)
      if (!o.skipped && !dateOnly(o.date).isBefore(seed)) o,
  ]..sort((a, b) => a.date.compareTo(b.date));

  double closeOf(DateTime day) {
    if (day.isBefore(seed)) return seedBalance ?? 0;
    BalancePoint? last;
    for (final p in points) {
      if (dateOnly(p.date).isAfter(day)) break;
      last = p;
    }
    if (last != null) return last.closingBalance.toDouble();
    if (points.isEmpty) return seedBalance ?? 0;
    // Before the first loaded point: walk back from it.
    final first = points.first;
    var v = first.closingBalance.toDouble();
    for (final o in counted) {
      final d = dateOnly(o.date);
      if (d.isAfter(day) && !d.isAfter(dateOnly(first.date))) {
        v -= o.signedDelta.toDouble();
      }
    }
    return v;
  }

  final opening = !s.isAfter(seed)
      ? (seedBalance ?? closeOf(addCalendarDays(s, -1)))
      : closeOf(addCalendarDays(s, -1));
  final inRange = [
    for (final o in counted)
      if (!dateOnly(o.date).isBefore(s) && !dateOnly(o.date).isAfter(e)) o,
  ];
  var gains = 0.0, losses = 0.0;
  for (final o in inRange) {
    final v = o.signedDelta.toDouble();
    if (v >= 0) {
      gains += v;
    } else {
      losses += v;
    }
  }
  return PeriodSummary(
    start: s,
    end: e,
    startBalance: opening,
    endBalance: closeOf(e),
    gains: gains,
    losses: losses,
    occurrences: inRange,
  );
}
