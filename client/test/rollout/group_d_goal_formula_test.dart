// Spec 013 group D (D11): the goal panel's money, rate, count and
// interval fields take formulas, worked out against the stream owner's
// variables. The goal solve gets numbers only; a saved scenario keeps the
// formulas in `request.exprs`; on load, a formula that now works out
// differently shows "Values changed since saved" and the stored number
// stays in use until "Use new value". Formulas off is as before.
import 'dart:convert';

import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/planning/goal_models.dart';
import 'package:budget_client/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../variables/manager_support.dart' show FakeVars, baseVars;
import 'group_d_support.dart';

final _vars = [
  variableRepositoryProvider.overrideWithValue(FakeVars(baseVars())),
];

Finder _input(String key) =>
    find.descendant(of: k(key), matching: find.byType(EditableText));

String _text(WidgetTester tester, String key) =>
    tester.widget<EditableText>(_input(key)).controller.text;

String? _error(WidgetTester tester, String key) {
  final under = find.byKey(ValueKey('$key-error'));
  if (under.evaluate().isNotEmpty) return tester.widget<Text>(under).data;
  return tester
      .widget<InputDecorator>(
        find.descendant(of: k(key), matching: find.byType(InputDecorator)),
      )
      .decoration
      .errorText;
}

/// Variables arriving re-solve after the panel's 250 ms debounce.
Future<void> _debounce(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await typeIn(tester, _input(key), text);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

const _scenario = GoalRequest(
  solveFor: GoalVar.endDate,
  targetBalance: 5000,
  amount: 2000,
  interval: 2,
  count: 6,
  exprs: {
    'amount': r'$rent * 2',
    'interval': r'$months / 6',
    'count': r'$months / 2',
  },
);

void main() {
  group('formulas on', () {
    setUp(() => ServerFeatures.variables = true);
    tearDown(() => ServerFeatures.variables = false);

    testWidgets('formulas solve as numbers; the request keeps exprs', (
      tester,
    ) async {
      final (repo, key) = await pumpGoal(
        tester,
        width: 700,
        overrides: _vars,
        initial: const GoalRequest(solveFor: GoalVar.endDate),
      );
      await _type(tester, 'goal-field-amount', r'$rent / 4');
      await _type(tester, 'goal-field-targetBalance', r'$rent * 10');
      await _type(tester, 'goal-field-rate', r'$rate + 1');
      await _type(tester, 'goal-field-count', r'$months / 3');
      await _type(tester, 'goal-field-startBalance', r'-$rent');
      await _type(tester, 'goal-field-interval-interval', r'$months / 6');
      final r = repo.goals.last;
      expect(r.amount, 300);
      expect(r.targetBalance, 12000);
      expect(r.rate, 6.5);
      expect(r.count, 4);
      expect(r.startBalance, -1200);
      expect(r.interval, 2);
      // The solve call sends numbers only…
      expect(jsonEncode(r.toJson(withExprs: false)), isNot(contains(r'$')));
      // …and a saved scenario keeps the formulas.
      final saved = key.currentState!.request;
      expect(saved.exprs, {
        'startBalance': r'-$rent',
        'targetBalance': r'$rent * 10',
        'amount': r'$rent / 4',
        'interval': r'$months / 6',
        'count': r'$months / 3',
        'rate': r'$rate + 1',
      });
      final back = GoalRequest.fromJson(
        jsonDecode(jsonEncode(saved.toJson())) as Map<String, dynamic>,
      );
      expect(back.exprs, saved.exprs);
      expect(back.amount, 300);
    });

    testWidgets('errors show in the field and block the solve', (tester) async {
      final (repo, _) = await pumpGoal(
        tester,
        width: 700,
        overrides: _vars,
        initial: const GoalRequest(solveFor: GoalVar.endDate),
      );
      await _type(tester, 'goal-field-amount', '100');
      final before = repo.goals.length;
      await _type(tester, 'goal-field-amount', r'$nope * 2');
      expect(_error(tester, 'goal-field-amount'), contains('nope'));
      await _type(tester, 'goal-field-count', r'$months / 5');
      expect(_error(tester, 'goal-field-count'), contains('whole number'));
      await _type(tester, 'goal-field-rate', r'$rent');
      expect(_error(tester, 'goal-field-rate'), isNotNull);
      expect(repo.goals.length, before);
      await _type(tester, 'goal-field-amount', '100');
      await _type(tester, 'goal-field-count', '');
      await _type(tester, 'goal-field-rate', '');
      expect(repo.goals.length, greaterThan(before));
    });

    testWidgets('scenario load: unchanged formulas show no warning', (
      tester,
    ) async {
      final (repo, key) = await pumpGoal(
        tester,
        width: 700,
        overrides: _vars,
        initial: _scenario.copyWith(),
      );
      key.currentState!.load(
        GoalRequest.fromJson({..._scenario.toJson(), 'amount': 2400}),
      );
      await _debounce(tester);
      expect(_text(tester, 'goal-field-amount'), r'$rent * 2');
      expect(k('goal-field-amount-changed'), findsNothing);
      expect(repo.goals.last.amount, 2400);
    });

    testWidgets('scenario load: changed formula keeps the stored number', (
      tester,
    ) async {
      final (repo, key) = await pumpGoal(
        tester,
        width: 700,
        overrides: _vars,
        initial: _scenario,
      );
      await _debounce(tester);
      expect(_text(tester, 'goal-field-amount'), r'$rent * 2');
      expect(
        tester.widget<Text>(k('goal-field-amount-changed')).data,
        r'Values changed since saved: $2,000.00 → $2,400.00',
      );
      // interval and count still work out to the stored 2 and 6.
      expect(k('goal-field-interval-changed'), findsNothing);
      expect(k('goal-field-count-changed'), findsNothing);
      expect(repo.goals.last.amount, 2000);
      expect(key.currentState!.request.exprs!['amount'], r'$rent * 2');

      await tester.tap(k('goal-field-amount-use-new'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(k('goal-field-amount-changed'), findsNothing);
      expect(repo.goals.last.amount, 2400);
    });

    testWidgets('scenario load: editing the formula drops the stored number', (
      tester,
    ) async {
      final (repo, _) = await pumpGoal(
        tester,
        width: 700,
        overrides: _vars,
        initial: _scenario,
      );
      await _debounce(tester);
      await _type(tester, 'goal-field-amount', r'$rent');
      expect(k('goal-field-amount-changed'), findsNothing);
      expect(repo.goals.last.amount, 1200);
    });
  });

  testWidgets('formulas off: exprs ignored on load, none sent, as before', (
    tester,
  ) async {
    final (repo, key) = await pumpGoal(tester, width: 700, initial: _scenario);
    expect(_text(tester, 'goal-field-amount'), '2000');
    expect(k('goal-field-amount-changed'), findsNothing);
    expect(key.currentState!.request.exprs, isNull);
    await _type(tester, 'goal-field-amount', r'$rent');
    expect(_error(tester, 'goal-field-amount'), 'Invalid number');
    expect(repo.goals.last.amount, 2000);
    expect(find.text('✦'), findsNothing);
  });
}
