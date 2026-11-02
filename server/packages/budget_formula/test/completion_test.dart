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

    expect(s(r'r|'), '0,1,r');
    expect(s(r're|'), '0,2,re');
    expect(s(r're|nt'), '0,4,re');
    expect(s(r'2*r|'), '2,3,r');
    expect(s(r'(r|'), '1,2,r');
    expect(s(r'rent + w|eeks * 2'), '7,12,w');
    expect(s(r'|rent'), isNull);
    expect(s(r'$5|'), isNull);
    // Numbers never open suggestions, nor does a word glued to one.
    expect(s(r'12|'), isNull);
    expect(s(r'1e|'), isNull);
    expect(s(r'1e3|'), isNull);
    expect(s(r'12mo|'), isNull);
    expect(s(r'12 mo|'), '3,5,mo');
    expect(s(r'1_250.5|'), isNull);
    expect(s(r'2*|'), isNull);
    // Reserved words still complete (a variable may start with "round").
    expect(s(r'round|'), '0,5,round');
    // The retired $name and _names don't.
    expect(s(r'$re|'), isNull);
    expect(s(r'_re|'), isNull);
    expect(s(r'rent|'), '0,4,rent');
    expect(s(r'rent |'), isNull);
    expect(s(''), isNull);
  });

  test('insertionFor keeps names apart from neighbours', () {
    expect(insertionFor('2', 1, 1, 'rent'), ' rent');
    expect(insertionFor('2 * ', 4, 4, 'rent'), 'rent');
    expect(insertionFor('(2)', 3, 3, 'rent'), ' rent');
    expect(insertionFor('re + 1', 0, 2, 'rent'), 'rent');
    expect(insertionFor('x(1)', 0, 1, 'rent'), 'rent ');
    expect(insertionFor('a b', 1, 1, 'rent'), ' rent');
    expect(insertionFor('', 0, 0, 'rent'), 'rent');
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
