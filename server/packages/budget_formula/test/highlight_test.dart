import 'package:budget_formula/budget_formula.dart';
import 'package:test/test.dart';

String show(String text, {FormulaError? error}) => [
      for (final s in highlight(text, (n) => n == 'rent', error: error))
        '${s.style.name}:${text.substring(s.start, s.end)}'
    ].join('|');

void tiles(String text, List<StyledSpan> spans) {
  var pos = 0;
  for (final s in spans) {
    expect(s.start, pos, reason: text);
    expect(s.end, greaterThan(s.start), reason: text);
    pos = s.end;
  }
  expect(pos, text.length, reason: text);
}

void main() {
  test('styles', () {
    expect(show(r'$rent*2 + $x'),
        'variableKnown:\$rent|operator:*|number:2|whitespace: |operator:+|whitespace: |variableUnknown:\$x');
    expect(show(r'($5)'), 'paren:(|currency:\$|number:5|paren:)');
    expect(show('5%'), 'number:5|reserved:%');
    expect(show('1😀'), 'number:1|invalid:😀');
  });

  test('error span splits tokens', () {
    expect(
        show('12345',
            error: FormulaError(FormulaErrorCode.badNumber, '', 1, 3)),
        'number:1|invalid:23|number:45');
    // Zero-width error at the end marks the last character.
    expect(
        show('5 +',
            error: FormulaError(FormulaErrorCode.expectedOperand, '', 3, 3)),
        'number:5|whitespace: |invalid:+');
    expect(
        show('5😀',
            error: FormulaError(FormulaErrorCode.expectedOperand, '', 3, 3)),
        'number:5|invalid:😀');
  });

  test('empty text has no spans', () {
    expect(highlight('', (_) => true), isEmpty);
  });

  test('spans tile arbitrary text, with or without an error', () {
    for (final s in [r'$rent * (2', '  ', r'$$a%^,;x1e3', '—×÷ ', '😀😀']) {
      tiles(s, highlight(s, (_) => false));
      final e = parseFormula(s).error;
      tiles(s, highlight(s, (_) => false, error: e));
    }
  });
}
