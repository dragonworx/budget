// A minimal single-loan walk over LoanAccrual (the oracle's sim2), used by
// the package goldens. The server's LoanWalk does the same inside the
// balance engine.
import 'package:budget_loan/budget_loan.dart';
import 'package:decimal/decimal.dart';

DateTime d(int y, int m, int day) => DateTime.utc(y, m, day);
Decimal dec(String v) => Decimal.parse(v);

class Charge {
  Charge(this.date, this.amount, this.payout);
  final DateTime date;
  final Decimal amount;
  final bool payout;
  @override
  String toString() =>
      '${formatLoanDate(date)} $amount${payout ? ' payout' : ''}';
}

class SimResult {
  SimResult(this.balance, this.charges, this.payoff, this.owedAtBoundary,
      this.closes);
  final Decimal balance;
  final List<Charge> charges;
  final DateTime? payoff;
  final Map<DateTime, Decimal> owedAtBoundary;
  final Map<DateTime, Decimal> closes;
  Decimal get total => charges.fold(Decimal.zero, (a, c) => a + c.amount);
}

SimResult simulate(
  LoanTerms terms,
  DateTime start,
  Decimal principal,
  Map<DateTime, Decimal> payments, {
  required DateTime until,
  Decimal? Function(DateTime day)? offsetUsable,
}) {
  final acc = LoanAccrual(terms, start, principal);
  var bal = Decimal.zero;
  final charges = <Charge>[];
  final boundaries = {for (final p in terms.ratePeriods.skip(1)) p.from};
  final owedAt = <DateTime, Decimal>{};
  final closes = <DateTime, Decimal>{};
  DateTime? payoff;
  for (var day = start;
      !day.isAfter(until);
      day = DateTime.utc(day.year, day.month, day.day + 1)) {
    final c1 = acc.chargeAtStartOfDay(day);
    if (c1 != null) {
      bal -= c1;
      charges.add(Charge(day, c1, false));
    }
    if (day == start) bal -= principal;
    if (payments[day] case final p?) bal += p;
    final owed = bal < Decimal.zero ? -bal : Decimal.zero;
    acc.accrue(day, owed, offsetUsable: offsetUsable?.call(day));
    final c2 = acc.chargeAtEndOfDay(day);
    if (c2 != null) {
      bal -= c2;
      charges.add(Charge(day, c2, false));
    }
    final c3 = acc.payout(day, owed);
    if (c3 != null) {
      bal -= c3;
      charges.add(Charge(day, c3, true));
    }
    if (day.isAfter(start)) {
      if (bal >= Decimal.zero) {
        payoff ??= day;
      } else {
        payoff = null;
      }
    }
    closes[day] = bal;
    final next = DateTime.utc(day.year, day.month, day.day + 1);
    if (boundaries.contains(next)) {
      owedAt[next] =
          (bal < Decimal.zero ? -bal : Decimal.zero) + acc.accruedCents;
    }
  }
  return SimResult(bal, charges, payoff, owedAt, closes);
}

/// Repayments every period from start (exclusive), like the oracle's sched.
Map<DateTime, Decimal> sched(DateTime start, String freq, Decimal amount,
    {int? n, DateTime? until}) {
  final out = <DateTime, Decimal>{};
  for (var i = 1;; i++) {
    final day = switch (freq) {
      'monthly' => _addMonths(start, i),
      'fortnightly' =>
        DateTime.utc(start.year, start.month, start.day + 14 * i),
      _ => DateTime.utc(start.year, start.month, start.day + 7 * i),
    };
    if (n != null && i > n) break;
    if (until != null && day.isAfter(until)) break;
    out[day] = amount;
  }
  return out;
}

DateTime _addMonths(DateTime s, int k) {
  final t = s.year * 12 + s.month - 1 + k;
  final y = t ~/ 12, m = t % 12 + 1;
  final dim = DateTime.utc(y, m + 1, 0).day;
  return DateTime.utc(y, m, s.day > dim ? dim : s.day);
}

LoanTerms terms(
  DateTime start,
  String rate, {
  int termMonths = 360,
  String mode = 'advanced',
  String interest = 'reducing',
  String freq = 'monthly',
  String? schedule,
  Object? chargeDay,
  String dayCount = '365',
  List<(DateTime, String)> more = const [],
  DateTime? first,
}) =>
    LoanTerms.fromJson({
      'v': 1,
      'mode': mode,
      'interestType': interest,
      'termMonths': termMonths,
      'repaymentFrequency': freq,
      if (first != null) 'firstRepaymentDate': formatLoanDate(first),
      if (schedule != null) 'chargeSchedule': schedule,
      if (chargeDay != null) 'chargeDay': chargeDay,
      if (interest != 'flat') 'dayCount': dayCount,
      'ratePeriods': [
        {
          'from': formatLoanDate(start),
          'ratePct': rate,
          if (interest == 'flat') 'offsetApplies': false,
        },
        for (final (f, r) in more)
          {'from': formatLoanDate(f), 'ratePct': r, 'type': 'variable'},
      ],
    })
      ..validate(start);
