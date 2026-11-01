import 'package:budget_formula/budget_formula.dart';
import 'package:decimal/decimal.dart';
import 'package:rational/rational.dart';
import 'package:test/test.dart';

String tree(String s) => prettyPrintTree(parseFormula(s).expr!);

/// Fully bracketed form, to check precedence.
String prettyPrintTree(Expr e) => switch (e) {
      NumberLit(:final lexeme) => lexeme,
      VarRef(:final name) => '\$$name',
      Unary(:final op, :final operand) =>
        '(${op == UnaryOp.minus ? '-' : '+'}${prettyPrintTree(operand)})',
      Binary(:final op, :final left, :final right) =>
        '(${prettyPrintTree(left)} ${op.name} ${prettyPrintTree(right)})',
      Group(:final inner) => '[${prettyPrintTree(inner)}]',
      PercentLit(:final operand) => '(${prettyPrintTree(operand)}%)',
      Call(:final fn, :final args) =>
        '$fn(${args.map(prettyPrintTree).join(',')})',
    };

void main() {
  test('precedence and associativity', () {
    expect(tree('1 + 2 * 3'), '(1 add (2 multiply 3))');
    expect(tree('10 - 2 - 3'), '((10 subtract 2) subtract 3)');
    expect(tree('12 / 2 / 3'), '((12 divide 2) divide 3)');
    expect(tree('-3 * 2'), '((-3) multiply 2)');
    expect(tree('2 * -3'), '(2 multiply (-3))');
    expect(tree('--5'), '(-(-5))');
    expect(tree(r'-$a * $b + 1'), r'(((-$a) multiply $b) add 1)');
    expect(tree('(1 + 2) * 3'), '([(1 add 2)] multiply 3)');
  });

  test('spans', () {
    final e = parseFormula(r' $rent * (2 + 3) ').expr! as Binary;
    expect([e.start, e.end, e.opStart], [1, 16, 7]);
    expect([e.left.start, e.left.end], [1, 6]);
    expect([e.right.start, e.right.end], [9, 16]);
    final u = parseFormula('- 5').expr! as Unary;
    expect([u.start, u.end, u.opStart], [0, 3, 0]);
  });

  test('currency literal', () {
    final n = parseFormula(r'$1_000.50').expr! as NumberLit;
    expect(n.currency, isTrue);
    expect(n.value, Decimal.parse('1000.5'));
    expect([n.start, n.end], [0, 9]);
  });

  test('parse result carries every token, also on error', () {
    final r = parseFormula('5 +');
    expect(r.ok, isFalse);
    expect(r.tokens.length, 4);
  });

  test('reserved dialect features parse when enabled', () {
    const d = FormulaDialect(percentLiterals: true, power: true);
    expect(tree2('5%', d), '(5%)');
    expect(tree2('2 ^ 3 ^ 2', d), '(2 power (3 power 2))');
    expect(tree2('-2 ^ 2', d), '(-(2 power 2))');
    final r = evaluate(
        parseFormula('-2 ^ 2 + 50%', dialect: d).expr!, VariableLookup.none,
        dialect: d);
    expect((r as EvalOk).value, Rational.parse('-3.5'));
  });

  test('functions when enabled', () {
    final d = FormulaDialect(functions: {
      'max': FormulaFunction(1, 9, (a) => a.reduce((x, y) => x > y ? x : y)),
    });
    final p = parseFormula(r'max(1, $a * 2, 3)', dialect: d);
    expect(p.error, isNull);
    final r = evaluate(
        p.expr!,
        MapVariableLookup(
            [VariableValue('a', Decimal.fromInt(4), VariableUnit.number)]),
        dialect: d);
    expect((r as EvalOk).value, Rational.fromInt(8));
    expect(parseFormula('max()', dialect: d).error!.code,
        FormulaErrorCode.unexpectedToken);
    expect(parseFormula('max(1', dialect: d).error!.code,
        FormulaErrorCode.unclosedParen);
    // v1 still rejects it.
    expect(parseFormula('max(1)').error!.code, FormulaErrorCode.reservedSyntax);
  });

  test('error code names are snake_case', () {
    expect(
        FormulaErrorCode.values.map((c) => FormulaError(c, '', 0, 0).codeName),
        containsAll([
          'unexpected_character',
          'division_by_zero',
          'too_many_decimals',
          'empty'
        ]));
  });
}

String tree2(String s, FormulaDialect d) =>
    prettyPrintTree(parseFormula(s, dialect: d).expr!);
