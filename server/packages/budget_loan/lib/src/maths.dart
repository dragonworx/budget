import 'dart:math' as math;

import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:decimal/decimal.dart';
import 'package:rational/rational.dart';

import 'terms.dart';

final _hundred = BigInt.from(100);

/// [q] rounded half-up (away from zero) to the cent.
Decimal roundCents(Rational q) =>
    (Decimal.fromBigInt((q * Rational(_hundred)).round()) /
            Decimal.fromInt(100))
        .toDecimal();

/// [q] rounded up (towards +∞) to the cent.
Decimal ceilCents(Rational q) =>
    (Decimal.fromBigInt((q * Rational(_hundred)).ceil()) / Decimal.fromInt(100))
        .toDecimal();

/// [q] rounded down (towards −∞) to the cent.
Decimal floorCents(Rational q) =>
    (Decimal.fromBigInt((q * Rational(_hundred)).floor()) /
            Decimal.fromInt(100))
        .toDecimal();

/// Monthly annuity `M = ceil_cents(B·r / (1 − (1+r)^−n))`, `r = ratePct/1200`
/// (the power in double, the rest exact); `r = 0` gives `ceil_cents(B/n)`.
Decimal amortisedMonthly(Decimal balance, Decimal ratePct, int months) {
  if (months < 1) months = 1;
  if (balance <= Decimal.zero) return Decimal.zero;
  if (ratePct == Decimal.zero) {
    return ceilCents(balance.toRational() / Rational.fromInt(months));
  }
  final r = ratePct.toDouble() / 1200;
  final factor = 1 - math.pow(1 + r, -months).toDouble();
  // B·pct / (1200 · factor), with factor as an exact decimal of the double.
  final f = Decimal.parse(factor.toString()).toRational();
  return ceilCents(
      (balance * ratePct).toRational() / (Rational.fromInt(1200) * f));
}

/// Interest-only monthly figure `ceil_cents(B·ratePct/1200)`.
Decimal interestOnlyMonthly(Decimal balance, Decimal ratePct) {
  if (balance <= Decimal.zero) return Decimal.zero;
  return ceilCents((balance * ratePct).toRational() / Rational.fromInt(1200));
}

/// A monthly figure as a [f] repayment by the annual split: monthly
/// unchanged, fortnightly `ceil_cents(M×12/26)`, weekly `ceil_cents(M×12/52)`.
Decimal perFrequency(Decimal monthly, RepaymentFrequency f) =>
    f == RepaymentFrequency.monthly
        ? monthly
        : ceilCents((monthly * Decimal.fromInt(12)).toRational() /
            Rational.fromInt(f.perYear));

/// Whole months from [from] to [termEnd], a part month counting as one
/// (the smallest m with `addMonthsRolled(from, m) ≥ termEnd`); at least 1.
int monthsRemaining(DateTime from, DateTime termEnd) {
  final f = civil(from), e = civil(termEnd);
  var m = (e.year - f.year) * 12 + (e.month - f.month);
  if (m < 0) m = 0;
  while (m > 0 && !addMonthsRolled(f, m - 1).isBefore(e)) {
    m--;
  }
  while (addMonthsRolled(f, m).isBefore(e)) {
    m++;
  }
  return m < 1 ? 1 : m;
}

/// One suggested minimum repayment: from [from], for [frequency].
class MinimumRepayment {
  const MinimumRepayment({
    required this.from,
    required this.frequency,
    required this.amount,
    required this.reason,
    this.monthly,
    this.finalRepayment,
  });

  final DateTime from;
  final RepaymentFrequency frequency;
  final Decimal amount;

  /// `start`, `rateChange`, or `interestOnlyEnd` (a rate period after an
  /// interest-only one).
  final String reason;

  /// The monthly figure the [amount] was split from (reducing loans).
  final Decimal? monthly;

  /// Flat loans: the last repayment (`P + I − (N−1)·R`).
  final Decimal? finalRepayment;

  Map<String, Object?> toJson() => {
        'from': formatLoanDate(from),
        'frequency': frequency.name,
        'amount': amount.toStringAsFixed(2),
        'reason': reason,
        if (finalRepayment != null)
          'finalRepayment': finalRepayment!.toStringAsFixed(2),
      };
}

/// The minimum for rate period [index] of [terms] given the balance
/// [owed] it starts from: `B = principal` at the start, else owed at the
/// end of the day before plus the accrued interest rounded to the cent
/// (the walk supplies it).
MinimumRepayment minimumForPeriod(
  LoanTerms terms,
  DateTime start,
  int index,
  Decimal owed,
) {
  final p = terms.ratePeriods[index];
  final end = terms.termEnd(start);
  final n = index == 0 ? terms.termMonths : monthsRemaining(p.from, end);
  final monthly = p.interestOnly
      ? interestOnlyMonthly(owed, p.ratePct)
      : amortisedMonthly(owed, p.ratePct, n);
  final reason = index == 0
      ? 'start'
      : terms.ratePeriods[index - 1].interestOnly && !p.interestOnly
          ? 'interestOnlyEnd'
          : 'rateChange';
  return MinimumRepayment(
    from: p.from,
    frequency: terms.repaymentFrequency,
    amount: perFrequency(monthly, terms.repaymentFrequency),
    monthly: monthly,
    reason: reason,
  );
}

/// The suggested minimums of a reducing loan: [owedAtBoundary] maps each
/// rate period's `from` (index ≥ 1) to its starting balance `B`; periods
/// the walk did not reach are left out.
List<MinimumRepayment> minimums(
  LoanTerms terms,
  DateTime start,
  Decimal principal,
  Map<DateTime, Decimal> owedAtBoundary,
) {
  if (terms.isFlat) {
    final plan = flatPlan(terms, principal, start);
    return [
      MinimumRepayment(
        from: civil(start),
        frequency: terms.repaymentFrequency,
        amount: plan.repayment,
        reason: 'start',
        finalRepayment: plan.finalRepayment,
      ),
    ];
  }
  return [
    minimumForPeriod(terms, start, 0, principal),
    for (var i = 1; i < terms.ratePeriods.length; i++)
      if (owedAtBoundary[terms.ratePeriods[i].from] case final b?)
        minimumForPeriod(terms, start, i, b),
  ];
}

/// A flat-rate loan's fixed plan.
class FlatPlan {
  const FlatPlan({
    required this.totalInterest,
    required this.dates,
    required this.instalments,
    required this.repayment,
    required this.finalRepayment,
  });

  /// `I = round_half_up(P × rate/100 × termMonths/12, 2)`.
  final Decimal totalInterest;

  /// The N repayment-schedule dates through the term end.
  final List<DateTime> dates;

  /// Interest per date: `floor_cents(I/N)`, the last taking the remainder.
  final List<Decimal> instalments;

  /// `ceil_cents((P + I)/N)`.
  final Decimal repayment;

  /// `P + I − (N−1)·R`.
  final Decimal finalRepayment;

  int get n => dates.length;
}

FlatPlan flatPlan(LoanTerms terms, Decimal principal, DateTime start) {
  final s = civil(start);
  final rate = terms.ratePeriods.first.ratePct;
  final total = roundCents(
      (principal * rate * Decimal.fromInt(terms.termMonths)).toRational() /
          Rational.fromInt(1200));
  final dates = terms.repaymentDates(s, terms.termEnd(s));
  final n = dates.length;
  if (n == 0) {
    throw const LoanFormatException(
        'loan.firstRepaymentDate must be on or before the term end');
  }
  final each = floorCents(total.toRational() / Rational.fromInt(n));
  final last = total - each * Decimal.fromInt(n - 1);
  final repayment =
      ceilCents((principal + total).toRational() / Rational.fromInt(n));
  return FlatPlan(
    totalInterest: total,
    dates: dates,
    instalments: [for (var i = 0; i < n - 1; i++) each, last],
    repayment: repayment,
    finalRepayment: principal + total - repayment * Decimal.fromInt(n - 1),
  );
}

/// Annual % (2 dp, approx.) at which an annuity of [n] payments of
/// [repayment] at [f] repays [principal] (bisection in double).
Decimal equivalentReducingRate(
  Decimal principal,
  Decimal repayment,
  int n,
  RepaymentFrequency f,
) {
  final p = principal.toDouble(), pay = repayment.toDouble();
  var lo = 0.0, hi = 1.0;
  for (var i = 0; i < 200; i++) {
    final m = (lo + hi) / 2, r = m / f.perYear;
    final got = p * r / (1 - math.pow(1 + r, -n));
    if (got < pay) {
      lo = m;
    } else {
      hi = m;
    }
  }
  return Decimal.parse((lo * 100).toString()).round(scale: 2);
}
