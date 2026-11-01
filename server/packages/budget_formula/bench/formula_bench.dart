// dart run bench/formula_bench.dart (AOT: dart compile exe first for
// steadier numbers). Targets (spec 009): >= 100k/s tokenize+parse+eval of a
// 60-char, 4-variable formula; highlight of 500 chars < 0.5 ms.
import 'package:budget_formula/budget_formula.dart';
import 'package:decimal/decimal.dart';

void main() {
  final vars = MapVariableLookup([
    VariableValue('rent', Decimal.parse('1200'), VariableUnit.money),
    VariableValue('weeks', Decimal.parse('52'), VariableUnit.number),
    VariableValue('bills', Decimal.parse('310.45'), VariableUnit.money),
    VariableValue('fuel', Decimal.parse('85.2'), VariableUnit.money),
  ]);
  const f = r'($rent * 12 + $bills * 4) / $weeks - $fuel * 2.5 + 1_000.756';
  assert(f.length >= 60);
  var sink = 0;
  for (var i = 0; i < 20000; i++) {
    sink ^= evaluate(parseFormula(f).expr!, vars).hashCode;
  }
  const n = 200000;
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    final p = parseFormula(f);
    sink ^= evaluate(p.expr!, vars).hashCode;
  }
  sw.stop();
  final perSec = n / sw.elapsedMicroseconds * 1e6;
  print('parse+eval (${f.length} chars, 4 vars): '
      '${perSec.toStringAsFixed(0)}/s (target >= 100000)');

  final long = '${List.filled(50, r'$rent*12 + ').join().substring(0, 499)}1';
  assert(long.length == 500);
  for (var i = 0; i < 2000; i++) {
    sink ^= highlight(long, (n) => vars.lookup(n) != null).length;
  }
  const m = 5000;
  sw
    ..reset()
    ..start();
  for (var i = 0; i < m; i++) {
    sink ^= highlight(long, (n) => vars.lookup(n) != null).length;
  }
  sw.stop();
  final ms = sw.elapsedMicroseconds / m / 1000;
  print('highlight (500 chars): ${ms.toStringAsFixed(4)} ms (target < 0.5)');
  if (sink == 42) print('');
}
