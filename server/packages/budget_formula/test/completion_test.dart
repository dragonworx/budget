import 'package:budget_formula/budget_formula.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

/// `|` marks the caret.
CompletionContext? at(String marked) {
  final c = marked.indexOf('|');
  return completionAt(marked.replaceFirst('|', ''), c);
}

void main() {
  test('caret table', () {
    String? s(String m) {
      final c = at(m);
      return c == null ? null : '${c.replaceStart},${c.replaceEnd},${c.prefix}';
    }

    expect(s(r'$|'), '0,1,');
    expect(s(r'$re|'), '0,3,re');
    expect(s(r'$re|nt'), '0,5,re');
    expect(s(r'2*$|'), '2,3,');
    expect(s(r'($r|'), '1,3,r');
    expect(s(r'$rent + $w|eeks * 2'), '8,14,w');
    expect(s(r'|$rent'), isNull);
    expect(s(r'$5|'), isNull);
    expect(s(r'rent|'), isNull);
    expect(s(r'$rent |'), isNull);
    expect(s(''), isNull);
  });

  test('ranking', () {
    VariableValue v(String n) =>
        VariableValue(n, Decimal.one, VariableUnit.number);
    final vars = [
      v('current'),
      v('rent10'),
      v('Rent2'),
      v('rate'),
      v('parent'),
      v('rent')
    ];
    List<String> names(String p, {int limit = 50}) =>
        [for (final x in rankCompletions(p, vars, limit: limit)) x.name];
    expect(names('re'), ['rent', 'Rent2', 'rent10', 'current', 'parent']);
    expect(names('RE', limit: 2), ['rent', 'Rent2']);
    expect(names(''), ['current', 'parent', 'rate', 'rent', 'Rent2', 'rent10']);
    expect(names('zz'), isEmpty);
  });
}
