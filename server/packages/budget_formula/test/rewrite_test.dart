import 'package:budget_formula/budget_formula.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('referencedNames', () {
    expect(referencedNames(r'Rent * rent + weeks / $'), {'rent', 'weeks'});
    expect(referencedNames(r'$old + round + _x'), isEmpty);
    expect(referencedNames(r'$5 + 3'), isEmpty);
    expect(referencedNames(r'a ( ( b'), {'a', 'b'}, reason: 'broken text');
  });

  test('renameVariable is token-aware and keeps everything else', () {
    expect(
        renameVariable(r'rent*2 + rental', 'rent', 'home'), r'home*2 + rental');
    expect(renameVariable(r'RENT × 2', 'rent', 'Home'), r'Home × 2');
    expect(renameVariable(r'2rent+(rent)', 'rent', 'home'), r'2home+(home)');
    expect(renameVariable(r'  rent  +  ( rent', 'Rent', 'r'), r'  r  +  ( r');
    expect(renameVariable(r'$5 + rent5', 'rent', 'x'), r'$5 + rent5');
    expect(renameVariable('no vars', 'rent', 'x'), 'no vars');
  });

  test('canonicalise', () {
    expect(canonicalise('  RENT×2 −\u00a0WEEKS ÷ nope  ', stdVars),
        r'rent*2 - weeks / nope');
    expect(canonicalise(r'rent', stdVars), r'rent');
  });

  test('names: validation', () {
    expect(variableNameProblem('rent', []), isNull);
    expect(variableNameProblem('Rent_2', []), isNull);
    expect(variableNameProblem(r'$rent', []),
        r'Leave out the $: a variable is written as just its name');
    expect(variableNameProblem('', []), 'Enter a name');
    expect(variableNameProblem(r'$', []), isNotNull);
    expect(variableNameProblem('2x', []), 'Start the name with a letter');
    expect(variableNameProblem('_tmp', []), 'Start the name with a letter');
    expect(variableNameProblem('a-b', []),
        'Use only letters, digits and _ (no spaces)');
    expect(variableNameProblem('a b', []), isNotNull);
    expect(variableNameProblem('é', []), isNotNull);
    expect(variableNameProblem('a' * 40, []), isNull);
    expect(variableNameProblem('a' * 41, []), 'At most 40 characters');
    for (final w in ['round', 'MAX', 'and', 'True', 'if']) {
      expect(variableNameProblem(w, []), contains('is reserved'), reason: w);
    }
    expect(variableNameProblem('rounding', []), isNull);
    expect(variableNameProblem('RENT', ['rent']),
        r'A variable named "rent" already exists');
    expect(variableNameProblem('RENT', ['rent'], self: 'rent'), isNull);
    expect(variableNameProblem('weeks', ['rent', 'Weeks'], self: 'rent'),
        isNotNull);
    expect(variableNamePattern.hasMatch('a_9'), isTrue);
    expect(variableNamePattern.hasMatch('_a9'), isFalse);
    expect(variableNamePattern.hasMatch('9a'), isFalse);
    expect(variableNamePattern.hasMatch('é'), isFalse);
  });

  test('names: order and distance', () {
    final l = ['rent10', 'Rent2', 'rent', 'apple', 'Apple', 'b'];
    expect(l..sort(compareNames),
        ['Apple', 'apple', 'b', 'rent', 'Rent2', 'rent10']);
    expect(editDistance('rent', 'RNT'), 1);
    expect(editDistance('', 'abc'), 3);
    expect(closestName('rnt', ['rent', 'rate']), 'rent');
    expect(closestName('rat', ['rent', 'rate']), 'rate');
    expect(closestName('zzzz', ['rent']), isNull);
  });
}
