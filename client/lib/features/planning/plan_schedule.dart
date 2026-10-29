import '../../data/models.dart';

/// The schedule both Plan modes share (start, end, amount each time,
/// frequency, count): what the user typed, carried across when switching
/// between "Reach a balance" and "Spread a total". Null: blank (solved or
/// defaulted by the mode).
class PlanSchedule {
  const PlanSchedule({
    this.startDate,
    this.endDate,
    this.amount,
    this.interval,
    this.unit = RecurrenceUnit.weeks,
    this.count,
  });

  final DateTime? startDate;
  final DateTime? endDate;

  /// Signed in "Reach a balance" (+ in, − out); "Spread a total" plans
  /// income and only takes a positive amount.
  final double? amount;
  final int? interval;
  final RecurrenceUnit unit;
  final int? count;

  @override
  String toString() =>
      'PlanSchedule($startDate, $endDate, $amount, every $interval '
      '${unit.name}, x$count)';
}

/// Plain text for a typed amount: no trailing ".0".
String planAmountText(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
