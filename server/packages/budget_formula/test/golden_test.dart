// AST and highlight dumps for a fixed formula set. Regenerate with
// UPDATE_GOLDENS=1 dart test test/golden_test.dart and review the diff.
import 'dart:io';

import 'package:budget_formula/budget_formula.dart';
import 'package:test/test.dart';

import 'support.dart';

const formulas = [
  r'rent * 3',
  r'rent * 12 / 52',
  r'(1 + 2) * 3',
  r'1 + 2 * 3 - 4 / 5',
  r'-rent + --5',
  r'RENT×2 − Weeks ÷ 4',
  r'$1_250.50 + $.5',
  r'(((rent)))',
  r'10 / 3 * 3',
  r'0.1 + 0.2',
  r'rent / zero',
  r'nope * 2',
  r'rnt * 2',
  r'5 +',
  r'* 5',
  r'(5 + 3',
  r'5 + 3)',
  r'5 x 3',
  r'5%',
  r'2 ^ 3',
  r'1,250 + 1',
  r'round(5)',
  r'rent2 * 2',
  r'1e3',
  r'1.2.3',
  r'5.',
  r'$',
  r'12 😀',
  r'1234567890123456',
  r'999999999999999 * 2',
  ' \t\u00a0weeks\u00a0*\u00a07 ',
  r'$rent * 3',
  r'3 weeks',
  r'_x + 1',
  r'2rent',
];

String render(String text) {
  final b = StringBuffer(
      'text: ${text.replaceAll('\t', r'\t').replaceAll('\u00a0', r'\u00a0')}\n');
  final p = parseFormula(text);
  FormulaError? e = p.error;
  if (p.expr != null) {
    b.write(dumpAst(p.expr!));
    b.writeln('pretty: ${prettyPrint(p.expr!)}');
    final r = evaluate(p.expr!, stdVars);
    if (r is EvalOk) {
      b.writeln('value: ${plainDecimal(r.value, maxScale: 10)}');
    } else {
      e = (r as EvalErr).error;
    }
  }
  if (e != null) b.writeln('error: $e');
  b.writeln('highlight:');
  for (final s in highlight(text, (n) => stdVars.lookup(n) != null, error: e)) {
    b.writeln(
        '  ${s.style.name.padRight(16)}[${s.start},${s.end}) ${text.substring(s.start, s.end).replaceAll('\t', r'\t').replaceAll('\u00a0', r'\u00a0')}');
  }
  return b.toString();
}

void main() {
  final update = Platform.environment['UPDATE_GOLDENS'] == '1';
  for (final (i, f) in formulas.indexed) {
    test('golden ${i.toString().padLeft(2, '0')}: $f', () {
      final file = File('test/goldens/${i.toString().padLeft(2, '0')}.txt');
      final got = render(f);
      if (update) {
        file.writeAsStringSync(got);
      } else {
        expect(file.existsSync(), isTrue, reason: 'run with UPDATE_GOLDENS=1');
        expect(got, file.readAsStringSync());
      }
    });
  }
}
