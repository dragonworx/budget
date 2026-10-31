import 'package:budget_loan/budget_loan.dart';
import 'package:decimal/decimal.dart';

import '../domain/models.dart';
import 'balance_engine.dart';
import 'calendar_math.dart';
import 'occurrence_gen.dart';

/// One derived interest charge of a loan walk.
class LoanCharge {
  LoanCharge({
    required this.date,
    required this.amount,
    required this.closingBalance,
    this.payout = false,
    this.flat = false,
  });

  final DateTime date;

  /// The interest charged (positive; it is debited from the balance).
  final Decimal amount;

  /// The stream balance right after this charge.
  final Decimal closingBalance;
  final bool payout;
  final bool flat;
}

/// A loan walk's series plus the loan's charges and payoff (spec 002).
class LoanWalkResult {
  LoanWalkResult({
    required this.series,
    required this.loan,
    required this.charges,
    required this.payoffDate,
    required this.owedAtBoundary,
    required this.accrual,
  });

  /// Points and occurrences in the requested window (derived interest
  /// occurrences included), as [BalanceEngine.compute] returns them.
  final BalanceSeries series;

  /// The loan event walked.
  final BudgetEvent loan;

  /// Every interest charge from the loan start to the walk end.
  final List<LoanCharge> charges;

  /// First date after the start from which the closing balance stays ≥ 0
  /// to the end of the walk; null when negative at the end.
  final DateTime? payoffDate;

  /// Owed at the end of the day before each rate-period boundary, plus the
  /// accrued (uncharged) interest in cents: the minimum calculator's B.
  final Map<DateTime, Decimal> owedAtBoundary;

  /// The accrual state at the end of the walk.
  final LoanAccrual accrual;
}

/// The daily walk for a stream holding an active loan event (spec 002
/// "Daily walk"). Generation and ordering of the fixed occurrences are the
/// same as [BalanceEngine.compute]; around them each day: (1) start-of-day
/// charge, (2) fixed occurrences, (3) accrue on what is owed, (4) month-end
/// charge, (5) payout interest when nothing is owed, (6) record.
class LoanWalk {
  /// The first enabled, visible loan event in [events], if any.
  static BudgetEvent? activeLoan(Iterable<BudgetEvent> events) {
    for (final e in events) {
      if (e.isLoan && e.active && e.loan != null) return e;
    }
    return null;
  }

  static LoanWalkResult compute({
    required Decimal seedBalance,
    required DateTime seedDate,
    required List<BudgetEvent> events,
    required List<String> eventOrder,
    required DateTime from,
    required DateTime to,
    required BudgetEvent loan,
    Map<String, Set<DateTime>> skipped = const {},
  }) {
    final seed = CalendarMath.dateOnly(seedDate);
    var rangeStart = CalendarMath.dateOnly(from);
    final rangeEnd = CalendarMath.dateOnly(to);
    if (CalendarMath.compare(rangeEnd, rangeStart) < 0) {
      throw ArgumentError('to must be >= from');
    }
    final start = CalendarMath.dateOnly(loan.startDate);
    final accrual = LoanAccrual(loan.loan!, start, loan.amount);
    final empty = LoanWalkResult(
      series: BalanceSeries(points: const [], occurrences: const []),
      loan: loan,
      charges: const [],
      payoffDate: null,
      owedAtBoundary: const {},
      accrual: accrual,
    );
    if (CalendarMath.compare(rangeEnd, seed) < 0) return empty;
    if (CalendarMath.compare(rangeStart, seed) < 0) rangeStart = seed;

    final fixed = OccurrenceGenerator.generate(
      events: events,
      from: seed,
      to: rangeEnd,
      skipped: skipped,
    );
    BalanceEngine.sortOccurrences(fixed, events, eventOrder);
    final byDate = <DateTime, List<Occurrence>>{};
    for (final o in fixed) {
      byDate.putIfAbsent(o.date, () => []).add(o);
    }

    final boundaries = {
      for (final p in loan.loan!.ratePeriods.skip(1))
        CalendarMath.dateOnly(p.from),
    };
    final isFlat = loan.loan!.isFlat;
    final points = <BalancePoint>[];
    final out = <Occurrence>[];
    final charges = <LoanCharge>[];
    final owedAt = <DateTime, Decimal>{};
    DateTime? payoff;
    var balance = seedBalance;
    var cursor = seed;

    Occurrence interest(DateTime d, Decimal amt, {bool payout = false}) =>
        Occurrence(
          eventId: loan.id,
          date: d,
          signedDelta: -amt,
          skipped: false,
          component: 'interest',
          derived: true,
          payout: payout,
          flat: isFlat,
        );

    while (CalendarMath.compare(cursor, rangeEnd) <= 0) {
      final inWindow = CalendarMath.compare(cursor, rangeStart) >= 0;
      void charge(Decimal amt, {bool payout = false}) {
        balance -= amt;
        charges.add(LoanCharge(
          date: cursor,
          amount: amt,
          closingBalance: balance,
          payout: payout,
          flat: isFlat,
        ));
        if (inWindow) out.add(interest(cursor, amt, payout: payout));
      }

      // 1. Start-of-day charge (accrual through yesterday, or the flat
      // instalment due today).
      final c1 = accrual.chargeAtStartOfDay(cursor);
      if (c1 != null) charge(c1);
      // 2. The day's fixed occurrences, in the engine's order.
      for (final o in byDate[cursor] ?? const <Occurrence>[]) {
        if (!o.skipped) balance += o.signedDelta;
        if (inWindow) out.add(o);
      }
      // 3. Accrue on what is owed after them.
      final owed = balance < Decimal.zero ? -balance : Decimal.zero;
      accrual.accrue(cursor, owed);
      // 4. Month-end charge (accrual through today).
      final c2 = accrual.chargeAtEndOfDay(cursor);
      if (c2 != null) charge(c2);
      // 5. Payout interest when the fixed occurrences cleared the loan.
      final c3 = accrual.payout(cursor, owed);
      if (c3 != null) charge(c3, payout: true);
      // 6. Record.
      if (cursor.isAfter(start)) {
        if (balance >= Decimal.zero) {
          payoff ??= cursor;
        } else {
          payoff = null;
        }
      }
      if (inWindow) {
        points.add(BalancePoint(date: cursor, closingBalance: balance));
      }
      final next = cursor.add(const Duration(days: 1));
      if (boundaries.contains(next)) {
        owedAt[next] = (balance < Decimal.zero ? -balance : Decimal.zero) +
            accrual.accruedCents;
      }
      cursor = next;
    }

    return LoanWalkResult(
      series: BalanceSeries(points: points, occurrences: out),
      loan: loan,
      charges: charges,
      payoffDate: payoff,
      owedAtBoundary: owedAt,
      accrual: accrual,
    );
  }
}
