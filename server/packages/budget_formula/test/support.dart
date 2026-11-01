import 'package:budget_formula/budget_formula.dart';
import 'package:decimal/decimal.dart';
import 'package:rational/rational.dart';

/// The sample variables from variables-plan-review.md.
final stdVars = MapVariableLookup([
  VariableValue('rent', Decimal.parse('1200'), VariableUnit.money),
  VariableValue('weeks', Decimal.parse('52'), VariableUnit.number),
  VariableValue('rate', Decimal.parse('5.5'), VariableUnit.percent),
  VariableValue('some_var_name', Decimal.parse('5'), VariableUnit.number),
  VariableValue('another_var_name', Decimal.parse('3'), VariableUnit.number),
  VariableValue('zero', Decimal.zero, VariableUnit.number),
]);

/// "5/2" or "2.5".
Rational rat(String s) {
  final i = s.indexOf('/');
  if (i < 0) return Decimal.parse(s).toRational();
  return Rational(
      BigInt.parse(s.substring(0, i)), BigInt.parse(s.substring(i + 1)));
}

Decimal dec(String s) => Decimal.parse(s);
