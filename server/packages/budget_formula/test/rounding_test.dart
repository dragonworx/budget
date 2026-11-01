import 'package:budget_formula/budget_formula.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('half away from zero', () {
    final cases = {
      ('2.675', 2): '2.68',
      ('-2.675', 2): '-2.68',
      ('0.005', 2): '0.01',
      ('-0.005', 2): '-0.01',
      ('0.0049999', 2): '0',
      ('1.00005', 4): '1.0001',
      ('-1.00005', 4): '-1.0001',
      ('1.00004999', 4): '1',
      ('2.5', 0): '3',
      ('-2.5', 0): '-3',
      ('1.5', 0): '2',
      ('0.5', 0): '1',
      ('0.4999', 0): '0',
      ('-0.4999', 0): '0',
      ('276.9230769', 2): '276.92',
      ('2/3', 2): '0.67',
      ('-2/3', 4): '-0.6667',
      ('1/8', 2): '0.13',
      ('-1/8', 2): '-0.13',
      ('123', 2): '123',
      ('0', 10): '0',
      ('1/3', 10): '0.3333333333',
      ('2/3', 10): '0.6666666667',
    };
    for (final MapEntry(key: (v, scale), value: want) in cases.entries) {
      expect(roundHalfAwayFromZero(rat(v), scale), dec(want),
          reason: '$v @ $scale');
    }
  });

  test('isWhole', () {
    expect(isWhole(rat('4')), isTrue);
    expect(isWhole(rat('8/2')), isTrue);
    expect(isWhole(rat('2.5')), isFalse);
    expect(isWhole(rat('-3')), isTrue);
  });
}
