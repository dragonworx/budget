// Spec 013 group D (D11): the planner's total, amount, interval and count
// take formulas. They are worked out on the client and the solve request
// carries only numbers; a formula with an error (or waiting for its
// variables) blocks the solve and shows in its field; formulas off is as
// before.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../variables/manager_support.dart' show FakeVars, baseVars;
import 'group_d_support.dart';

final _vars = [
  variableRepositoryProvider.overrideWithValue(FakeVars(baseVars())),
];

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

Future<void> _type(WidgetTester tester, String key, String text) async {
  await typeIn(
    tester,
    find.descendant(of: k(key), matching: find.byType(EditableText)),
    text,
  );
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

void main() {
  group('formulas on', () {
    setUp(() => ServerFeatures.variables = true);
    tearDown(() => ServerFeatures.variables = false);

    testWidgets('amount, interval and count formulas solve as numbers', (
      tester,
    ) async {
      final repo = await pumpPlan(tester, width: 700, overrides: _vars);
      expect(k('plan-formula-note'), findsOneWidget);
      await _type(tester, 'plan-amount', 'rent / 16');
      await _type(tester, 'plan-interval', 'months / 6');
      await _type(tester, 'plan-count', 'months / 2');
      final r = repo.solves.last;
      expect(r.amount, Decimal.parse('75'));
      expect(r.interval, 2);
      expect(r.occurrenceCount, 6);
      expect(r.toJson().toString(), isNot(contains(r'$')));
      expect(_error(tester, 'plan-amount'), isNull);
    });

    testWidgets('total formula is a given value; blank amount is solved', (
      tester,
    ) async {
      final repo = await pumpPlan(tester, width: 700, overrides: _vars);
      await _type(tester, 'plan-total', 'rent * 2');
      final r = repo.solves.last;
      expect(r.targetTotal, Decimal.parse('2400'));
      expect(r.amount, isNull);
    });

    testWidgets('a formula error blocks the solve and shows in the field', (
      tester,
    ) async {
      final repo = await pumpPlan(tester, width: 700, overrides: _vars);
      await _type(tester, 'plan-amount', '75');
      final before = repo.solves.length;
      await _type(tester, 'plan-amount', 'nope + 1');
      expect(_error(tester, 'plan-amount'), contains('nope'));
      expect(repo.solves.length, before);
      await _type(tester, 'plan-count', 'months - 12');
      expect(_error(tester, 'plan-count'), isNotNull);
      await _type(tester, 'plan-interval', 'months * 10');
      expect(_error(tester, 'plan-interval'), '1–99');
      expect(repo.solves.length, before);
      // Fixing them solves again.
      await _type(tester, 'plan-amount', 'rent / 16');
      await _type(tester, 'plan-count', '6');
      await _type(tester, 'plan-interval', '1');
      expect(repo.solves.length, greaterThan(before));
      expect(repo.solves.last.amount, Decimal.parse('75'));
    });

    testWidgets('plain numbers keep the planner messages', (tester) async {
      await pumpPlan(tester, width: 700, overrides: _vars);
      await _type(tester, 'plan-interval', '0');
      // Drawn as the field's note, as before 013.
      expect(find.text('Whole number ≥ 1'), findsOneWidget);
    });
  });

  testWidgets('formulas off: no note, \$ text is just invalid', (tester) async {
    final repo = await pumpPlan(tester, width: 700);
    expect(k('plan-formula-note'), findsNothing);
    await _type(tester, 'plan-amount', '75');
    final before = repo.solves.length;
    await _type(tester, 'plan-amount', 'rent');
    expect(repo.solves.length, before);
    expect(_error(tester, 'plan-amount'), isNotNull);
    expect(find.text('✦'), findsNothing);
  });
}
