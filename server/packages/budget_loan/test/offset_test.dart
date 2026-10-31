// Spec 004: OffsetMath.usable and the threshold goldens T1–T4 (the oracle
// /workspace/specs/loan-ref/loan_ref.py `__main__` asserts the same). Loan
// $100,000 drawn 2027-01-01 at 3.65%, day count 365, charged at month end,
// so the daily factor is 0.0001; offset constant unless stated.
import 'package:budget_loan/budget_loan.dart';
import 'package:test/test.dart';

import 'sim.dart';

void main() {
  group('OffsetMath.usable', () {
    test('threshold 0: the whole positive balance', () {
      expect(OffsetMath.usable(dec('40000'), dec('0')), dec('40000'));
    });
    test('positive threshold is the zero', () {
      expect(OffsetMath.usable(dec('40000'), dec('10000')), dec('30000'));
    });
    test('negative threshold counts as zero', () {
      expect(OffsetMath.usable(dec('40000'), dec('-1000')), dec('40000'));
      expect(OffsetMath.thresholdUsed(dec('-1000')), dec('0'));
    });
    test('negative balance never offsets', () {
      expect(OffsetMath.usable(dec('-500'), dec('0')), dec('0'));
      expect(OffsetMath.usable(dec('-500'), dec('-1000')), dec('0'));
    });
    test('balance exactly at the threshold: nothing', () {
      expect(OffsetMath.usable(dec('5000'), dec('5000')), dec('0'));
      expect(OffsetMath.usable(dec('0'), dec('0')), dec('0'));
    });
    test('below a positive threshold: nothing', () {
      expect(OffsetMath.usable(dec('4000'), dec('5000')), dec('0'));
    });
  });

  group('threshold goldens', () {
    final s = d(2027, 1, 1);
    String jan(String balance, String threshold) {
      final r = simulate(
          terms(s, '3.65', chargeDay: 'monthEnd'), s, dec('100000'), {},
          until: d(2027, 1, 31),
          offsetUsable: (_) => OffsetMath.usable(dec(balance), dec(threshold)));
      return r.charges.isEmpty
          ? '0.00'
          : r.charges.first.amount.toStringAsFixed(2);
    }

    test('T1 threshold +10,000: base 70,000', () {
      expect(jan('40000', '10000'), '217.00');
    });
    test('T2 threshold 0: base 60,000', () {
      expect(jan('40000', '0'), '186.00');
    });
    test('T3 threshold -1,000 counts as 0 (not 182.90)', () {
      expect(jan('40000', '-1000'), '186.00');
    });
    test('T4 balance -500, threshold -1,000: no offset', () {
      expect(jan('-500', '-1000'), '310.00');
    });
    test('offset above what is owed: no interest at all', () {
      expect(jan('150000', '0'), '0.00');
    });
    test('offsetApplies false: same as no offset', () {
      final t = LoanTerms.fromJson({
        ...terms(s, '3.65', chargeDay: 'monthEnd').toJson(),
        'ratePeriods': [
          {
            'from': '2027-01-01',
            'ratePct': '3.65',
            'type': 'fixed',
            'interestOnly': false,
            'offsetApplies': false,
          }
        ],
      });
      final r = simulate(t, s, dec('100000'), {},
          until: d(2027, 1, 31), offsetUsable: (_) => dec('40000'));
      expect(r.charges.first.amount.toStringAsFixed(2), '310.00');
    });
  });
}
