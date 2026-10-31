// Goldens G1–G7 and F1–F3 from spec 002; expected values from
// /workspace/specs/loan-ref/loan_ref.py (the oracle asserts the same).
import 'package:budget_loan/budget_loan.dart';
import 'package:test/test.dart';

import 'sim.dart';

List<String> amounts(SimResult r, [int? take]) => [
      for (final c in take == null ? r.charges : r.charges.take(take))
        c.amount.toStringAsFixed(2)
    ];

void main() {
  test('G1 monthEnd, 365, hand-checkable', () {
    final s = d(2027, 1, 1);
    final r = simulate(
        terms(s, '3.65', chargeDay: 'monthEnd'), s, dec('1000'), {},
        until: d(2027, 3, 31));
    expect(r.charges.map((c) => c.toString()),
        ['2027-01-31 3.1', '2027-02-28 2.81', '2027-03-31 3.12']);
    expect(r.balance, dec('-1009.03'));
  });

  test('G1b actual day count, leap year', () {
    final s = d(2028, 1, 1);
    final r = simulate(
        terms(s, '3.66', chargeDay: 'monthEnd', dayCount: 'actual'),
        s,
        dec('1000'),
        {},
        until: d(2028, 3, 31));
    expect(amounts(r), ['3.10', '2.91', '3.12']);
    expect(r.charges.map((c) => formatLoanDate(c.date)),
        ['2028-01-31', '2028-02-29', '2028-03-31']);
    expect(r.balance, dec('-1009.13'));
  });

  test('G2 personal loan, simple, anniversary', () {
    final s = d(2027, 1, 15);
    final t = terms(s, '12', termMonths: 12, mode: 'simple');
    final m = minimums(t, s, dec('10000'), const {});
    expect(m.single.amount, dec('888.49'));
    expect(m.single.reason, 'start');
    final r = simulate(
        t, s, dec('10000'), sched(s, 'monthly', dec('888.49'), n: 12),
        until: d(2028, 3, 1));
    expect(amounts(r, 3), ['101.92', '84.81', '85.71']);
    expect(r.closes[d(2027, 2, 15)], dec('-9213.43'));
    expect(r.charges.last.toString(), '2028-01-15 8.93');
    expect(r.balance, dec('2.97'));
    expect(r.total, dec('658.91'));
    expect(r.payoff, d(2028, 1, 15));
  });

  group('G3 mortgage', () {
    final s = d(2027, 1, 15);
    final te = d(2057, 1, 15);
    test('minimums per frequency', () {
      final m = amortisedMonthly(dec('500000'), dec('6.00'), 360);
      expect(m, dec('2997.76'));
      expect(perFrequency(m, RepaymentFrequency.fortnightly), dec('1383.59'));
      expect(perFrequency(m, RepaymentFrequency.weekly), dec('691.80'));
      expect(terms(s, '6.00').termEnd(s), te);
    });
    test('monthly 365: residual and total', () {
      final r = simulate(terms(s, '6.00'), s, dec('500000'),
          sched(s, 'monthly', dec('2997.76'), n: 360),
          until: te);
      expect(amounts(r, 1), ['2547.95']);
      expect(r.balance, dec('-1030.45'));
      expect(r.total, dec('580224.05'));
      expect(r.balance.abs() < dec('2997.76'), isTrue);
    });
    test('monthly actual: overpaid', () {
      final r = simulate(terms(s, '6.00', dayCount: 'actual'), s, dec('500000'),
          sched(s, 'monthly', dec('2997.76'), n: 360),
          until: te);
      expect(r.balance, dec('358.83'));
      expect(r.total, dec('578834.77'));
    });
    test('fortnightly repayments, monthly anniversary charges', () {
      final r = simulate(terms(s, '6.00'), s, dec('500000'),
          sched(s, 'fortnightly', dec('1383.59'), until: te),
          until: te);
      expect(r.payoff, d(2056, 9, 15));
      expect(r.payoff!.isBefore(te), isTrue);
      expect(r.total, dec('569896.50'));
      expect(amounts(r, 2), ['2543.40', '2295.79']);
    });
  });

  test('G4 rate change recompute', () {
    final s = d(2027, 3, 1);
    final t = terms(s, '5.50', more: [(d(2029, 3, 1), '6.50')]);
    expect(
        minimums(t, s, dec('300000'), const {}).single.amount, dec('1703.37'));
    final r = simulate(t, s, dec('300000'),
        sched(s, 'monthly', dec('1703.37'), until: d(2029, 2, 1)),
        until: d(2029, 3, 1));
    expect(r.closes[d(2029, 2, 28)], dec('-292213.69'));
    expect(r.charges.last.toString(), '2029-03-01 1232.9');
    expect(r.owedAtBoundary[d(2029, 3, 1)], dec('293446.59'));
    expect(monthsRemaining(d(2029, 3, 1), t.termEnd(s)), 336);
    final m = minimums(t, s, dec('300000'), r.owedAtBoundary);
    expect(m.map((e) => e.toJson()), [
      {
        'from': '2027-03-01',
        'frequency': 'monthly',
        'amount': '1703.37',
        'reason': 'start'
      },
      {
        'from': '2029-03-01',
        'frequency': 'monthly',
        'amount': '1898.65',
        'reason': 'rateChange'
      },
    ]);
  });

  test('G5 on repayment dates, fortnightly', () {
    final s = d(2027, 1, 1);
    final t =
        terms(s, '3.65', freq: 'fortnightly', schedule: 'onRepaymentDates');
    expect(t.chargeDay, isNull);
    final r = simulate(t, s, dec('1000'), {}, until: d(2027, 2, 12));
    expect(r.charges.map((c) => c.toString()),
        ['2027-01-15 1.4', '2027-01-29 1.4', '2027-02-12 1.4']);
    expect(r.balance, dec('-1004.20'));
  });

  group('G6 fortnightly, charged on repayment dates', () {
    final s = d(2027, 1, 15);
    final te = d(2057, 1, 15);
    test('782 payments, totals, payoff', () {
      final pf = sched(s, 'fortnightly', dec('1383.59'), until: te);
      expect(pf.length, 782);
      expect(pf.keys.first, d(2027, 1, 29));
      expect(pf.keys.last, d(2057, 1, 5));
      final t =
          terms(s, '6.00', freq: 'fortnightly', schedule: 'onRepaymentDates');
      expect(t.firstRepayment(s), d(2027, 1, 29));
      final r = simulate(t, s, dec('500000'), pf, until: te);
      expect(amounts(r, 3), ['1150.68', '1150.15', '1149.61']);
      expect(r.total, dec('572459.28'));
      expect(r.payoff, d(2056, 10, 13));
    });
    test('monthly frequency + onRepaymentDates == anniversary (G3)', () {
      final r = simulate(terms(s, '6.00', schedule: 'onRepaymentDates'), s,
          dec('500000'), sched(s, 'monthly', dec('2997.76'), n: 360),
          until: te);
      expect(r.total, dec('580224.05'));
    });
  });

  test('G7 charge day 1', () {
    final s = d(2027, 1, 15);
    final r = simulate(terms(s, '3.65', chargeDay: 1), s, dec('1000'), {},
        until: d(2027, 3, 1));
    expect(r.charges.map((c) => c.toString()),
        ['2027-02-01 1.7', '2027-03-01 2.8']);
    expect(r.balance, dec('-1004.50'));
  });

  test('G7 unit: chargeDay 31 charges on 30 Apr, 28 Feb, 29 Feb 2028', () {
    final s = d(2027, 1, 10);
    final r = simulate(terms(s, '3.65', chargeDay: 31), s, dec('1000'), {},
        until: d(2028, 4, 30));
    final dates = r.charges.map((c) => formatLoanDate(c.date)).toList();
    expect(dates, containsAll(['2027-02-28', '2027-04-30', '2028-02-29']));
    expect(dates.first, '2027-01-31');
    expect(dates, hasLength(16));
  });

  group('flat', () {
    final s = d(2027, 1, 15);
    test('F1 monthly plan, run and equivalent rate', () {
      final t =
          terms(s, '10', termMonths: 24, mode: 'simple', interest: 'flat');
      final p = flatPlan(t, dec('10000'), s);
      expect(p.totalInterest, dec('2000.00'));
      expect(p.n, 24);
      expect(p.dates.first, d(2027, 2, 15));
      expect(p.instalments.take(23).toSet(), {dec('83.33')});
      expect(p.instalments.last, dec('83.41'));
      expect(p.repayment, dec('500.00'));
      expect(p.finalRepayment, dec('500.00'));
      final r = simulate(
          t, s, dec('10000'), sched(s, 'monthly', dec('500'), n: 24),
          until: d(2029, 6, 1));
      expect(r.total, dec('2000.00'));
      expect(r.balance, dec('0'));
      expect(r.payoff, d(2029, 1, 15));
      expect(
          equivalentReducingRate(
              dec('10000'), dec('500'), 24, RepaymentFrequency.monthly),
          dec('18.16'));
      final m = minimums(t, s, dec('10000'), const {}).single.toJson();
      expect(m, {
        'from': '2027-01-15',
        'frequency': 'monthly',
        'amount': '500.00',
        'reason': 'start',
        'finalRepayment': '500.00',
      });
    });
    test('F2 fortnightly', () {
      final t = terms(s, '10',
          termMonths: 24,
          mode: 'simple',
          interest: 'flat',
          freq: 'fortnightly');
      final p = flatPlan(t, dec('10000'), s);
      expect(p.n, 52);
      expect(p.dates.last, d(2029, 1, 12));
      expect(p.instalments.first, dec('38.46'));
      expect(p.instalments.last, dec('38.54'));
      expect(p.repayment, dec('230.77'));
      expect(p.finalRepayment, dec('230.73'));
      final pay = sched(s, 'fortnightly', p.repayment, n: 52);
      pay[pay.keys.last] = p.finalRepayment;
      final r = simulate(t, s, dec('10000'), pay, until: d(2029, 6, 1));
      expect(r.total, dec('2000.00'));
      expect(r.balance, dec('0'));
      expect(r.payoff, d(2029, 1, 12));
    });
    test('F3 early payoff, no rebate', () {
      final t =
          terms(s, '10', termMonths: 24, mode: 'simple', interest: 'flat');
      final pay = sched(s, 'monthly', dec('500'), n: 12);
      pay[d(2028, 2, 1)] = dec('4999.96');
      pay[d(2028, 2, 2)] = dec('1000.04');
      final r = simulate(t, s, dec('10000'), pay, until: d(2029, 6, 1));
      expect(r.closes[d(2028, 1, 31)], dec('-4999.96'));
      final payout = r.charges.firstWhere((c) => c.payout);
      expect(payout.toString(), '2028-02-01 1000.04 payout');
      expect(r.closes[d(2028, 2, 1)], dec('-1000.04'));
      expect(r.payoff, d(2028, 2, 2));
      expect(r.total, dec('2000.00'));
    });
    test('missed and extra repayments do not change flat interest', () {
      final t =
          terms(s, '10', termMonths: 24, mode: 'simple', interest: 'flat');
      final pay = sched(s, 'monthly', dec('500'), n: 24)
        ..remove(d(2027, 3, 15))
        ..[d(2027, 4, 1)] = dec('300');
      final r = simulate(t, s, dec('10000'), pay, until: d(2027, 6, 1));
      expect(amounts(r), ['83.33', '83.33', '83.33', '83.33']);
    });
  });
}
