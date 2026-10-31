import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:decimal/decimal.dart';

import 'maths.dart';
import 'terms.dart';

/// Accrued interest is kept in 10^-10 currency units (each day's accrual is
/// rounded half-up to 10 dp, spec 002).
final _unitsPerCent = BigInt.from(100000000); // 10^8
final _halfCent = BigInt.from(50000000);
final _scale10 = BigInt.from(10).pow(10);

/// One loan's interest state for a day-by-day walk (spec 002 "Daily walk").
/// Call, for each day d in ascending order from the walk start:
/// [chargeAtStartOfDay], (apply the day's fixed occurrences), [accrue],
/// [chargeAtEndOfDay], [payout]. Each charge is a positive amount the walk
/// subtracts from the balance (null = none).
class LoanAccrual {
  LoanAccrual(this.terms, DateTime start, this.principal)
      : start = civil(start),
        _flat = terms.isFlat ? flatPlan(terms, principal, start) : null {
    final plan = _flat;
    if (plan != null) {
      for (var i = 0; i < plan.n; i++) {
        _pending[plan.dates[i]] = plan.instalments[i];
      }
    }
    final cd = terms.chargeDay;
    _chargeDayN = switch (cd) {
      DayOfMonthChargeDay(:final day) => day,
      AnniversaryChargeDay() => this.start.day,
      _ => null,
    };
    _monthEnd = terms.chargeSchedule == ChargeSchedule.monthly &&
        cd is MonthEndChargeDay;
  }

  final LoanTerms terms;
  final DateTime start;
  final Decimal principal;
  final FlatPlan? _flat;
  final _pending = <DateTime, Decimal>{};
  int? _chargeDayN;
  bool _monthEnd = false;
  BigInt _accrued = BigInt.zero;

  /// The flat-rate plan (null for a reducing loan).
  FlatPlan? get flat => _flat;

  /// Interest accrued and not yet charged (10 dp).
  Decimal get accrued =>
      (Decimal.fromBigInt(_accrued) / Decimal.fromBigInt(_scale10)).toDecimal();

  /// [accrued] rounded half-up to the cent.
  Decimal get accruedCents => _cents(_accrued);

  /// Remaining flat instalments not yet charged.
  int get pendingInstalments => _pending.length;

  static Decimal _cents(BigInt units) {
    final c = (units + _halfCent) ~/ _unitsPerCent; // units ≥ 0
    return (Decimal.fromBigInt(c) / Decimal.fromInt(100)).toDecimal();
  }

  bool _isStartOfDayChargeDate(DateTime d) {
    if (!d.isAfter(start)) return false;
    if (terms.chargeSchedule == ChargeSchedule.onRepaymentDates) {
      return terms.isRepaymentDate(start, d);
    }
    final n = _chargeDayN;
    if (n == null) return false;
    final dim = daysInMonth(d.year, d.month);
    return d.day == (n > dim ? dim : n);
  }

  Decimal? _chargeAccrued() {
    final amt = _cents(_accrued);
    _accrued = BigInt.zero;
    return amt > Decimal.zero ? amt : null;
  }

  /// Step 1: the charge dated [d] covering accrual through d−1 (reducing),
  /// or the flat instalment due on [d].
  Decimal? chargeAtStartOfDay(DateTime d) {
    final day = civil(d);
    if (_flat != null) return _pending.remove(day);
    if (!_isStartOfDayChargeDate(day)) return null;
    return _chargeAccrued();
  }

  /// Step 3: one day's interest on [owed] (≥ 0, after the day's fixed
  /// occurrences) less [offsetUsable] (spec 004) when the period's
  /// `offsetApplies`. No-op for flat loans and before the start.
  void accrue(DateTime d, Decimal owed, {Decimal? offsetUsable}) {
    if (_flat != null) return;
    final day = civil(d);
    if (day.isBefore(start)) return;
    final p = terms.periodOn(day);
    var base = owed;
    if (offsetUsable != null && p.offsetApplies) {
      base = owed - offsetUsable;
    }
    if (base <= Decimal.zero || p.ratePct == Decimal.zero) return;
    final yearDays =
        terms.dayCount == DayCount.actual && _isLeap(day.year) ? 366 : 365;
    // round_half_up(base × pct / 100 / yearDays, 10) in 10^-10 units.
    final q = (base * p.ratePct).toRational() *
        Decimal.fromBigInt(_scale10).toRational() /
        Decimal.fromInt(100 * yearDays).toRational();
    _accrued += q.round();
  }

  /// Step 4: the month-end charge (accrual through [d]) for `monthEnd`.
  Decimal? chargeAtEndOfDay(DateTime d) {
    if (_flat != null || !_monthEnd) return null;
    final day = civil(d);
    if (day.day != daysInMonth(day.year, day.month)) return null;
    return _chargeAccrued();
  }

  /// Step 5: payout interest when nothing is owed after the day's fixed
  /// occurrences ([owed] from step 2): reducing, the accrued interest;
  /// flat, every remaining instalment (no rebate).
  Decimal? payout(DateTime d, Decimal owed) {
    final day = civil(d);
    if (!day.isAfter(start) || owed > Decimal.zero) return null;
    if (_flat != null) {
      if (_pending.isEmpty) return null;
      final sum = _pending.values.fold(Decimal.zero, (a, b) => a + b);
      _pending.clear();
      return sum;
    }
    if (_accrued <= BigInt.zero) return null;
    return _chargeAccrued();
  }

  static bool _isLeap(int y) => (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
}
