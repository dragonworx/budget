import 'package:budget_formula/budget_formula.dart';
import 'package:rational/rational.dart';
import 'package:test/test.dart';

import 'support.dart';

Rational ev(String s, [VariableLookup? v]) =>
    (evaluate(parseFormula(s).expr!, v ?? stdVars) as EvalOk).value;
FormulaError err(String s) =>
    (evaluate(parseFormula(s).expr!, stdVars) as EvalErr).error;

void main() {
  test('exact rationals', () {
    expect(ev('10/3*3'), rat('10'));
    expect(ev('1/3+1/3+1/3'), rat('1'));
    expect(ev('0.1+0.2'), rat('0.3'));
    expect(ev('1/7*7'), rat('1'));
    expect(ev('2/3'), rat('2/3'));
  });

  test('variables are case-insensitive and recorded lower-case', () {
    final r = evaluate(parseFormula(r'$RENT + $Weeks * $rent').expr!, stdVars)
        as EvalOk;
    expect(r.value, rat('63600'));
    expect(r.usedLower, {'rent', 'weeks'});
  });

  test('division by zero names a bare variable, at the operator', () {
    expect(err(r'$rent / $zero').message, r'Division by zero: $zero is 0');
    expect(err(r'$rent / ($zero)').message, r'Division by zero: $zero is 0');
    expect(err(r'$rent / ($zero * 2)').message, 'Division by zero');
    final e = err(r'5 / (1 - 1)');
    expect([e.start, e.end], [2, 3]);
  });

  test('overflow at the 10^15 boundary', () {
    expect(ev('999999999999999 + 1'), rat('1000000000000000'));
    expect(err('999999999999999 + 2').code, FormulaErrorCode.overflow);
    expect(ev('-999999999999999 - 1'), rat('-1000000000000000'));
    expect(err('-999999999999999 - 2').code, FormulaErrorCode.overflow);
    // An intermediate counts even when the result is small.
    expect(err('999999999999999 * 10 / 100').code, FormulaErrorCode.overflow);
  });

  test('a huge variable overflows where it is used', () {
    final v = MapVariableLookup(
        [VariableValue('big', dec('2000000000000000'), VariableUnit.number)]);
    final e = (evaluate(parseFormula(r'1 + $big').expr!, v) as EvalErr).error;
    expect([e.code, e.start, e.end], [FormulaErrorCode.overflow, 4, 8]);
  });

  test('bit-size guard rounds to 30 dp', () {
    // 20 divisions by 1.0000000NN: ~30 bits each, well past 256.
    final s = ['1', for (var i = 11; i < 31; i++) '1.00000000$i'].join('/');
    expect(s.length, lessThan(500));
    final r = ev(s);
    expect(r.denominator.bitLength, lessThanOrEqualTo(256));
    expect(r.numerator.bitLength, lessThanOrEqualTo(256));
    // Rounded to 30 dp at the guard: close to the exact value.
    var exact = Rational.one;
    for (var i = 11; i < 31; i++) {
      exact = exact / Rational.parse('1.00000000$i');
    }
    expect((r - exact).abs() < Rational.parse('1e-28'), isTrue);
  });

  test('unknown variable hint (edit distance <= 2)', () {
    expect(err(r'$rnt').hint, r'Did you mean $rent?');
    expect(err(r'$weeksss').hint, r'Did you mean $weeks?');
    expect(err(r'$qqqqq').hint, isNull);
  });

  test('first error wins, left to right', () {
    expect(err(r'$nope / $zero').code, FormulaErrorCode.unknownVariable);
    expect(err(r'1 / $zero + $nope').code, FormulaErrorCode.divisionByZero);
  });
}
