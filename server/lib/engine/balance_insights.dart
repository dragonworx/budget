import '../domain/models.dart';
import 'calendar_math.dart';

/// Lowest point and runway (§3.6) over a closing-balance series.
class BalanceInsights {
  BalanceInsights({
    this.lowestDate,
    this.lowestBalance,
    this.alertDate,
    this.zeroDate,
  });

  final DateTime? lowestDate;
  final double? lowestBalance;

  /// First day the closing balance is below the alert threshold (a
  /// balance equal to it is not an alert).
  final DateTime? alertDate;

  /// First day the closing balance is below zero.
  final DateTime? zeroDate;

  /// [lowestThrough] limits the lowest-point search (runway scans all).
  static BalanceInsights of(
    List<BalancePoint> points, {
    required double threshold,
    DateTime? lowestThrough,
  }) {
    DateTime? lowDate, alert, zero;
    double? low;
    for (final p in points) {
      final v = p.closingBalance.toDouble();
      final inLow = lowestThrough == null ||
          CalendarMath.compare(p.date, lowestThrough) <= 0;
      if (inLow && (low == null || v < low)) {
        low = v;
        lowDate = p.date;
      }
      if (alert == null && v < threshold) alert = p.date;
      if (zero == null && v < 0) zero = p.date;
    }
    return BalanceInsights(
      lowestDate: lowDate,
      lowestBalance: low,
      alertDate: alert,
      zeroDate: zero,
    );
  }

  Map<String, Object?> toJson() => {
        'lowest': lowestDate == null
            ? null
            : {
                'date': formatDate(lowestDate!),
                'balance': _money(lowestBalance!),
              },
        'alertDate': alertDate == null ? null : formatDate(alertDate!),
        'zeroDate': zeroDate == null ? null : formatDate(zeroDate!),
      };
}

String _money(double v) => v.toStringAsFixed(2);
