import 'package:decimal/decimal.dart';

import '../domain/models.dart';
import 'balance_engine.dart';
import 'calendar_math.dart';

/// Balance-target planning (§4.4): what the pool is already projected to
/// hold on a date, and the gap a new plan has to cover to reach a target.
class BalanceProjection {
  /// Closing balance on [date] from the existing transactions (the seed
  /// balance before the seed date).
  static Decimal closeOn({
    required Pool pool,
    required List<Transaction> transactions,
    required DateTime date,
    Map<String, Set<DateTime>> skipped = const {},
  }) {
    final day = CalendarMath.dateOnly(date);
    if (CalendarMath.compare(day, CalendarMath.dateOnly(pool.seedDate)) <
        0) {
      return pool.seedBalance;
    }
    final series = BalanceEngine.compute(
      seedBalance: pool.seedBalance,
      seedDate: pool.seedDate,
      transactions: transactions,
      transactionOrder: pool.transactionOrder,
      from: day,
      to: day,
      skipped: skipped,
    );
    return series.points.isEmpty
        ? pool.seedBalance
        : series.points.last.closingBalance;
  }

  /// `target − projected`: positive means money must come in, negative
  /// means that much can go out.
  static Decimal gap({required Decimal target, required Decimal projected}) =>
      target - projected;
}
