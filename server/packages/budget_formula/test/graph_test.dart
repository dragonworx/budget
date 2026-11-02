import 'package:budget_formula/budget_formula.dart';
import 'package:test/test.dart';

void main() {
  test('cycles of length 1, 2, 3', () {
    expect(
        findCycle({
          'a': {'a'}
        }),
        ['a', 'a']);
    expect(
        findCycle({
          'a': {'b'},
          'b': {'a'}
        }),
        ['a', 'b', 'a']);
    expect(
        findCycle({
          'c': {'a'},
          'a': {'b'},
          'b': {'c'}
        }),
        ['a', 'b', 'c', 'a']);
    expect(formatCycle(['a', 'b', 'a']), 'a → b → a');
    expect(
        () => topoOrder({
              'a': {'a'}
            }),
        throwsA(isA<FormulaCycleException>()));
  });

  test('diamond, leaves and stable order', () {
    final deps = {
      'top': {'left', 'right'},
      'left': {'base'},
      'right': {'base', 'plain'},
      'base': <String>{},
      'z': <String>{},
    };
    expect(findCycle(deps), isNull);
    expect(topoOrder(deps), ['base', 'left', 'right', 'top', 'z']);
    // Same result whatever the insertion order.
    final shuffled = Map.fromEntries(deps.entries.toList().reversed);
    expect(topoOrder(shuffled), topoOrder(deps));
    expect(chainDepths(deps),
        {'base': 1, 'z': 1, 'left': 2, 'right': 2, 'top': 3});
  });

  Map<String, Set<String>> chain(int n) => {
        for (var i = 0; i < n; i++) 'v$i': i == 0 ? <String>{} : {'v${i - 1}'},
      };

  test('chain depth 16 ok, 17 too deep', () {
    expect(tooDeepVariable(chain(16)), isNull);
    expect(tooDeepVariable(chain(17)), 'v16');
    expect(chainDepths(chain(17))['v16'], 17);
  });
}
