import 'package:budget_loan/budget_loan.dart';
import 'package:test/test.dart';

import 'sim.dart';

Map<String, Object?> base({
  Map<String, Object?> extra = const {},
  List<Map<String, Object?>>? periods,
}) =>
    {
      'v': 1,
      'mode': 'advanced',
      'termMonths': 360,
      'repaymentFrequency': 'monthly',
      'ratePeriods': periods ??
          [
            {'from': '2027-01-15', 'ratePct': '6.00'}
          ],
      ...extra,
    };

final start = d(2027, 1, 15);

Matcher rejects(String text) => throwsA(isA<LoanFormatException>()
    .having((e) => e.message, 'message', contains(text)));

void check(Map<String, Object?> json) =>
    LoanTerms.fromJson(json).validate(start);

void main() {
  group('defaults', () {
    test('reducing defaults are filled on write', () {
      final t = LoanTerms.fromJson(base()).withDefaults(start);
      expect(t.toJson(), {
        'v': 1,
        'mode': 'advanced',
        'interestType': 'reducing',
        'termMonths': 360,
        'repaymentFrequency': 'monthly',
        'firstRepaymentDate': '2027-02-15',
        'chargeSchedule': 'monthly',
        'chargeDay': 'anniversary',
        'dayCount': '365',
        'ratePeriods': [
          {
            'from': '2027-01-15',
            'ratePct': '6.00',
            'type': 'fixed',
            'interestOnly': false,
            'offsetApplies': true,
          }
        ],
      });
      // Round trip is stable.
      expect(LoanTerms.fromJson(t.toJson()).toJson(), t.toJson());
    });
    test('flat fills onRepaymentDates, null chargeDay, offset false', () {
      final t = LoanTerms.fromJson(base(extra: {
        'mode': 'simple',
        'interestType': 'flat',
        'termMonths': 24,
      })).withDefaults(start);
      final j = t.toJson();
      expect(j['chargeSchedule'], 'onRepaymentDates');
      expect(j['chargeDay'], isNull);
      expect((j['ratePeriods'] as List).single['offsetApplies'], false);
    });
    test('first repayment default per frequency', () {
      LoanTerms f(String freq) =>
          LoanTerms.fromJson(base(extra: {'repaymentFrequency': freq}));
      expect(f('weekly').firstRepayment(start), d(2027, 1, 22));
      expect(f('fortnightly').firstRepayment(start), d(2027, 1, 29));
      expect(f('monthly').firstRepayment(d(2027, 1, 31)), d(2027, 2, 28));
    });
  });

  group('rejects', () {
    final cases = <String, (Map<String, Object?>, String)>{
      'unknown key': (base(extra: {'foo': 1}), 'loan.foo is not a known field'),
      'unknown period key': (
        base(periods: [
          {'from': '2027-01-15', 'ratePct': '6', 'x': true}
        ]),
        'loan.ratePeriods[0].x is not a known field'
      ),
      'v': (base(extra: {'v': 2}), 'loan.v must be 1'),
      'mode': (base(extra: {'mode': 'pro'}), 'loan.mode must be one of'),
      'missing mode': ({...base()}..remove('mode'), 'loan.mode is required'),
      'interestType': (
        base(extra: {'interestType': 'compound'}),
        'loan.interestType must be one of'
      ),
      'termMonths 0': (base(extra: {'termMonths': 0}), 'loan.termMonths'),
      'termMonths 601': (base(extra: {'termMonths': 601}), 'loan.termMonths'),
      'termMonths string': (
        base(extra: {'termMonths': '360'}),
        'loan.termMonths'
      ),
      'repaymentFrequency': (
        base(extra: {'repaymentFrequency': 'daily'}),
        'loan.repaymentFrequency must be one of'
      ),
      'firstRepaymentDate format': (
        base(extra: {'firstRepaymentDate': '15/02/2027'}),
        'loan.firstRepaymentDate must be a YYYY-MM-DD date'
      ),
      'firstRepaymentDate on start': (
        base(extra: {'firstRepaymentDate': '2027-01-15'}),
        'loan.firstRepaymentDate must be after the start'
      ),
      'firstRepaymentDate after one period': (
        base(extra: {'firstRepaymentDate': '2027-02-16'}),
        'loan.firstRepaymentDate must be after the start and no later than 2027-02-15'
      ),
      'firstRepaymentDate after term end': (
        base(extra: {
          'termMonths': 1,
          'repaymentFrequency': 'monthly',
          'firstRepaymentDate': '2027-02-16'
        }),
        'loan.firstRepaymentDate'
      ),
      'chargeSchedule': (
        base(extra: {'chargeSchedule': 'daily'}),
        'loan.chargeSchedule must be one of'
      ),
      'chargeDay with onRepaymentDates': (
        base(extra: {'chargeSchedule': 'onRepaymentDates', 'chargeDay': 1}),
        'loan.chargeDay is only allowed with a monthly charge schedule'
      ),
      'chargeDay 0': (base(extra: {'chargeDay': 0}), 'loan.chargeDay must be'),
      'chargeDay 32': (
        base(extra: {'chargeDay': 32}),
        'loan.chargeDay must be'
      ),
      'chargeDay text': (
        base(extra: {'chargeDay': 'first'}),
        'loan.chargeDay must be'
      ),
      'dayCount': (base(extra: {'dayCount': 360}), 'loan.dayCount must be'),
      'no periods': (base(periods: []), 'loan.ratePeriods must be a non-empty'),
      'too many periods': (
        base(periods: [
          for (var i = 0; i < 121; i++)
            {'from': formatLoanDate(d(2027, 1, 15 + i)), 'ratePct': '6'}
        ]),
        'at most 120 items'
      ),
      'first from not start': (
        base(periods: [
          {'from': '2027-01-16', 'ratePct': '6'}
        ]),
        'loan.ratePeriods[0].from must be the loan start date 2027-01-15'
      ),
      'not ascending': (
        base(periods: [
          {'from': '2027-01-15', 'ratePct': '6'},
          {'from': '2027-01-15', 'ratePct': '7'},
        ]),
        'loan.ratePeriods[1].from must be after loan.ratePeriods[0].from'
      ),
      'from at term end': (
        base(periods: [
          {'from': '2027-01-15', 'ratePct': '6'},
          {'from': '2057-01-15', 'ratePct': '7'},
        ]),
        'loan.ratePeriods[1].from must be before the term end 2057-01-15'
      ),
      'rate 5 dp': (
        base(periods: [
          {'from': '2027-01-15', 'ratePct': '6.12345'}
        ]),
        'loan.ratePeriods[0].ratePct must be'
      ),
      'rate number': (
        base(periods: [
          {'from': '2027-01-15', 'ratePct': 6}
        ]),
        'loan.ratePeriods[0].ratePct must be'
      ),
      'rate negative': (
        base(periods: [
          {'from': '2027-01-15', 'ratePct': '-1'}
        ]),
        'loan.ratePeriods[0].ratePct must be'
      ),
      'rate over 100': (
        base(periods: [
          {'from': '2027-01-15', 'ratePct': '100.01'}
        ]),
        'loan.ratePeriods[0].ratePct must be from 0 to 100'
      ),
      'rate type': (
        base(periods: [
          {'from': '2027-01-15', 'ratePct': '6', 'type': 'tracker'}
        ]),
        'loan.ratePeriods[0].type must be one of'
      ),
      'interestOnly type': (
        base(periods: [
          {'from': '2027-01-15', 'ratePct': '6', 'interestOnly': 'yes'}
        ]),
        'loan.ratePeriods[0].interestOnly must be true or false'
      ),
      'simple two periods': (
        base(extra: {
          'mode': 'simple'
        }, periods: [
          {'from': '2027-01-15', 'ratePct': '6'},
          {'from': '2028-01-15', 'ratePct': '7'},
        ]),
        'exactly one item in simple mode'
      ),
      'simple interestOnly': (
        base(extra: {
          'mode': 'simple'
        }, periods: [
          {'from': '2027-01-15', 'ratePct': '6', 'interestOnly': true}
        ]),
        'loan.ratePeriods[0].interestOnly is not allowed in simple mode'
      ),
      'flat monthly schedule': (
        base(extra: {'interestType': 'flat', 'chargeSchedule': 'monthly'}),
        'loan.chargeSchedule must be onRepaymentDates for a flat-rate loan'
      ),
      'flat two periods': (
        base(extra: {
          'interestType': 'flat'
        }, periods: [
          {'from': '2027-01-15', 'ratePct': '6', 'offsetApplies': false},
          {'from': '2028-01-15', 'ratePct': '7', 'offsetApplies': false},
        ]),
        'exactly one item for a flat-rate loan'
      ),
      'flat interestOnly': (
        base(extra: {
          'interestType': 'flat'
        }, periods: [
          {'from': '2027-01-15', 'ratePct': '6', 'interestOnly': true}
        ]),
        'interestOnly is not allowed for a flat-rate loan'
      ),
      'flat offsetApplies': (
        base(extra: {
          'interestType': 'flat'
        }, periods: [
          {'from': '2027-01-15', 'ratePct': '6', 'offsetApplies': true}
        ]),
        'loan.ratePeriods[0].offsetApplies must be false for a flat-rate loan'
      ),
      'flat actual': (
        base(extra: {'interestType': 'flat', 'dayCount': 'actual'}),
        'loan.dayCount must be "365" for a flat-rate loan'
      ),
      'flat variable': (
        base(extra: {
          'interestType': 'flat'
        }, periods: [
          {'from': '2027-01-15', 'ratePct': '6', 'type': 'variable'}
        ]),
        'loan.ratePeriods[0].type must be fixed for a flat-rate loan'
      ),
      'not an object': ({'loan': 1}, 'loan.loan is not a known field'),
      'too big': (
        base(extra: {'mode': 'x' * 17000}),
        'loan must be at most 16 KB'
      ),
    };
    cases.forEach((name, c) {
      test(name, () => expect(() => check(c.$1), rejects(c.$2)));
    });
    test('non-map', () {
      expect(() => LoanTerms.fromJson([1]), rejects('loan must be an object'));
    });
    test('flat N = 0 (first repayment after term end)', () {
      // A weekly loan of one month whose first repayment is pushed past
      // the end is caught by the first-repayment rule.
      expect(
          () => check(base(extra: {
                'interestType': 'flat',
                'termMonths': 1,
                'repaymentFrequency': 'fortnightly',
                'firstRepaymentDate': '2027-01-29',
              })),
          returnsNormally);
      expect(
          () => LoanTerms.fromJson(base(extra: {
                'interestType': 'flat',
                'termMonths': 1,
                'repaymentFrequency': 'monthly',
                'firstRepaymentDate': '2027-02-16',
              })).validate(start),
          rejects('loan.firstRepaymentDate'));
    });
  });

  group('schedule and periods', () {
    test('rate period lookup at boundaries', () {
      final t = LoanTerms.fromJson(base(periods: [
        {'from': '2027-01-15', 'ratePct': '5.5'},
        {'from': '2029-01-15', 'ratePct': '6.4', 'type': 'variable'},
      ]));
      expect(t.rateOn(d(2027, 1, 15)), dec('5.5'));
      expect(t.rateOn(d(2029, 1, 14)), dec('5.5'));
      expect(t.rateOn(d(2029, 1, 15)), dec('6.4'));
      expect(t.periodOn(d(2040, 1, 1)).type, RateType.variable);
      expect(t.rateOn(d(2020, 1, 1)), dec('5.5'));
    });
    test('monthly repayment dates from the 31st roll', () {
      final s = d(2027, 1, 31);
      final t = LoanTerms.fromJson(base(periods: [
        {'from': '2027-01-31', 'ratePct': '6'}
      ]));
      expect(t.repaymentDates(s, d(2027, 5, 31)).map(formatLoanDate), [
        '2027-02-28',
        '2027-03-28',
        '2027-04-28',
        '2027-05-28',
      ]);
      // An explicit first on the 31st rolls per month (R_k from first).
      final t2 = LoanTerms.fromJson(base(extra: {
        'firstRepaymentDate': '2027-02-28'
      }, periods: [
        {'from': '2027-01-31', 'ratePct': '6'}
      ]));
      expect(t2.isRepaymentDate(s, d(2027, 3, 28)), isTrue);
      expect(t2.isRepaymentDate(s, d(2027, 3, 31)), isFalse);
    });
    test('fortnightly dates stay ≤ term end', () {
      final t = LoanTerms.fromJson(
          base(extra: {'termMonths': 2, 'repaymentFrequency': 'fortnightly'}));
      final ds = t.repaymentDates(start, t.termEnd(start));
      expect(ds.map(formatLoanDate),
          ['2027-01-29', '2027-02-12', '2027-02-26', '2027-03-12']);
      expect(t.isRepaymentDate(start, d(2027, 3, 26)), isTrue);
    });
    test('anniversary from the 31st charges 28 Feb, 30 Apr, 29 Feb 2028', () {
      final s = d(2027, 1, 31);
      final r =
          simulate(terms(s, '3.65'), s, dec('1000'), {}, until: d(2028, 3, 1));
      final ds = r.charges.map((c) => formatLoanDate(c.date)).toList();
      expect(ds, containsAll(['2027-02-28', '2027-04-30', '2028-02-29']));
      expect(ds, isNot(contains('2027-03-28')));
      expect(ds, contains('2027-03-31'));
    });
  });

  group('maths', () {
    test('rate 0: B/n rounded up', () {
      expect(amortisedMonthly(dec('1000'), dec('0'), 3), dec('333.34'));
    });
    test('interest-only minimum', () {
      expect(interestOnlyMonthly(dec('500000'), dec('6.1')), dec('2541.67'));
      final s = d(2027, 1, 15);
      final t = LoanTerms.fromJson(base(periods: [
        {'from': '2027-01-15', 'ratePct': '6', 'interestOnly': true},
        {'from': '2032-01-15', 'ratePct': '6'},
      ]));
      final m = minimums(t, s, dec('500000'), {d(2032, 1, 15): dec('500000')});
      expect(m[0].amount, dec('2500.00'));
      expect(m[1].reason, 'interestOnlyEnd');
      expect(m[1].amount, amortisedMonthly(dec('500000'), dec('6'), 300));
    });
    test('frequency conversion rounds up', () {
      expect(perFrequency(dec('100.00'), RepaymentFrequency.fortnightly),
          dec('46.16'));
      expect(
          perFrequency(dec('100.00'), RepaymentFrequency.weekly), dec('23.08'));
      expect(perFrequency(dec('100.00'), RepaymentFrequency.monthly),
          dec('100.00'));
    });
    test('months remaining rounds a part month up', () {
      expect(monthsRemaining(d(2029, 3, 1), d(2057, 3, 1)), 336);
      expect(monthsRemaining(d(2029, 3, 2), d(2057, 3, 1)), 336);
      expect(monthsRemaining(d(2029, 2, 28), d(2057, 3, 1)), 337);
      expect(monthsRemaining(d(2057, 2, 28), d(2057, 3, 1)), 1);
    });
    test('accrual: payout charges the accrued same day, then stops', () {
      final s = d(2027, 1, 1);
      final r = simulate(
          terms(s, '3.65'), s, dec('1000'), {d(2027, 1, 11): dec('1000')},
          until: d(2027, 3, 1));
      expect(r.charges.map((c) => c.toString()), ['2027-01-11 1 payout']);
      expect(r.payoff, isNull); // −1.00 after the payout
      final r2 = simulate(
          terms(s, '3.65'), s, dec('1000'), {d(2027, 1, 11): dec('1001')},
          until: d(2027, 3, 1));
      expect(r2.payoff, d(2027, 1, 11));
      expect(r2.balance, dec('0'));
    });
    test('accrue honours offsetUsable when the period applies', () {
      final s = d(2027, 1, 1);
      final a = LoanAccrual(
          terms(s, '3.65', chargeDay: 'monthEnd'), s, dec('100000'));
      a.accrue(s, dec('100000'), offsetUsable: dec('40000'));
      expect(a.accrued, dec('6'));
    });
  });
}
