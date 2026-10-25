import 'package:decimal/decimal.dart';

import '../domain/models.dart';
import 'balance_engine.dart';
import 'calendar_math.dart';

/// Balance-target planning (§4.4): what the stream is already projected to
/// hold on a date, and the gap a new plan has to cover to reach a target.
class BalanceProjection {
  /// Closing balance on [date] from the existing events (the seed
  /// balance before the seed date).
  static Decimal closeOn({
    required BudgetStream stream,
    required List<BudgetEvent> events,
    required DateTime date,
    Map<String, Set<DateTime>> skipped = const {},
  }) {
    final day = CalendarMath.dateOnly(date);
    if (CalendarMath.compare(day, CalendarMath.dateOnly(stream.seedDate)) < 0) {
      return stream.seedBalance;
    }
    final series = BalanceEngine.compute(
      seedBalance: stream.seedBalance,
      seedDate: stream.seedDate,
      events: events,
      eventOrder: stream.eventOrder,
      from: day,
      to: day,
      skipped: skipped,
    );
    return series.points.isEmpty
        ? stream.seedBalance
        : series.points.last.closingBalance;
  }

  /// `target − projected`: positive means money must come in, negative
  /// means that much can go out.
  static Decimal gap({required Decimal target, required Decimal projected}) =>
      target - projected;
}
