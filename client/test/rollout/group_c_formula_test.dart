// Spec 013 group C: the event editor's interval N (between − / +) and the
// end-after count take formulas. With a formula the steppers are off
// ("Clear the formula to use − / +") and the box widens to fit it; the
// formula is saved as `frequency.intervalExpr` / `occurrenceCountExpr`
// beside its value; saved errors show on open; formulas off is as before.
import 'dart:convert';

import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';

import '../variables/manager_support.dart';

import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/events/event_editor.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_streams.dart';

import '../support/fake_categories.dart';

class _Txs extends EventRepository {
  _Txs() : super(ApiClient());
  final saved = <BudgetEvent>[];
  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async => [];
  @override
  Future<BudgetEvent> create(
    String streamId,
    BudgetEvent draft, {
    ({String name, String? color})? newCategory,
  }) async {
    saved.add(draft);
    return draft;
  }

  @override
  Future<BudgetEvent> update(BudgetEvent t, {bool force = false}) async {
    saved.add(t);
    return t;
  }
}

BudgetEvent _series(
  int? interval,
  RecurrenceUnit? unit, {
  List<int> days = const [],
  int? count,
  String? intervalExpr,
  String? countExpr,
  Map<String, dynamic>? exprErrors,
}) => BudgetEvent(
  id: 't1',
  streamId: 'a',
  name: 'Rent',
  direction: EventDirection.debit,
  amount: Decimal.fromInt(100),
  startDate: DateTime(2026, 10, 20),
  recurrenceMode: interval == null ? RecurrenceMode.once : RecurrenceMode.every,
  interval: interval,
  unit: unit,
  days: days,
  endMode: count == null ? EndMode.never : EndMode.count,
  occurrenceCount: count,
  intervalExpr: intervalExpr,
  occurrenceCountExpr: countExpr,
  exprErrors: exprErrors,
  version: 1,
);

Future<_Txs> _pump(
  WidgetTester tester, {
  BudgetEvent? existing,
  Size size = const Size(390, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final txs = _Txs();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        streamRepositoryProvider.overrideWithValue(FakeStreamRepository()),
        categoryRepositoryProvider.overrideWith(
          (ref) => FakeCategoryRepository(ref.watch(eventRepositoryProvider), [
            'Pay',
          ]),
        ),
        eventRepositoryProvider.overrideWithValue(txs),
        variableRepositoryProvider.overrideWithValue(FakeVars(baseVars())),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EventEditor(
            streamId: 'a',
            existing: existing,
            initialDate: DateTime(2026, 10, 20),
            onDone: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return txs;
}

Finder _k(String k) => find.byKey(ValueKey(k));

Finder _input(String key) =>
    find.descendant(of: _k(key), matching: find.byType(EditableText));

String _text(WidgetTester tester, String key) =>
    tester.widget<EditableText>(_input(key)).controller.text;

String? _error(WidgetTester tester, String key) {
  final under = find.byKey(ValueKey('$key-error'));
  if (under.evaluate().isNotEmpty) return tester.widget<Text>(under).data;
  return tester
      .widget<InputDecorator>(
        find.descendant(of: _k(key), matching: find.byType(InputDecorator)),
      )
      .decoration
      .errorText;
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(_k(key));
  await tester.enterText(_input(key), text);
  await tester.pumpAndSettle();
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

IconButton _step(WidgetTester tester, String k) =>
    tester.widget<IconButton>(_k('editor-interval-$k'));

Future<void> _save(WidgetTester tester) async {
  await tester.ensureVisible(_k('editor-save'));
  await tester.tap(_k('editor-save'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => ServerFeatures.variables = true);
  tearDown(() => ServerFeatures.variables = false);

  testWidgets('interval formula: steppers off, wide box, intervalExpr', (
    tester,
  ) async {
    final txs = await _pump(
      tester,
      existing: _series(3, RecurrenceUnit.months),
    );
    expect(_step(tester, 'plus').onPressed, isNotNull);
    expect(_k('editor-interval-wide'), findsNothing);

    await _type(tester, 'editor-interval', r'$months / 6');
    expect(_step(tester, 'plus').onPressed, isNull);
    expect(_step(tester, 'minus').onPressed, isNull);
    expect(_step(tester, 'plus').tooltip, 'Clear the formula to use − / +');
    expect(_k('editor-interval-wide'), findsOneWidget);
    final w = tester.getSize(_k('editor-interval')).width;
    expect(w, greaterThan(48));
    expect(w, lessThanOrEqualTo(180));
    expect(_error(tester, 'editor-interval'), isNull);

    await _save(tester);
    final e = txs.saved.single;
    expect(e.frequency.interval, 2);
    expect(e.intervalExpr, r'$months / 6');
    final json = e.toCreateJson();
    expect((json['frequency'] as Map)['intervalExpr'], r'$months / 6');
    expect((json['frequency'] as Map)['interval'], 2);
  });

  testWidgets('interval back to a number: steppers work as before', (
    tester,
  ) async {
    final txs = await _pump(
      tester,
      existing: _series(3, RecurrenceUnit.months),
    );
    await _type(tester, 'editor-interval', r'$months / 6');
    await _type(tester, 'editor-interval', '4');
    expect(_k('editor-interval-wide'), findsNothing);
    expect(_step(tester, 'plus').tooltip, 'More');
    await tester.tap(_k('editor-interval-plus'));
    await tester.pumpAndSettle();
    expect(_text(tester, 'editor-interval'), '5');
    await _save(tester);
    expect(txs.saved.single.frequency.interval, 5);
    expect(txs.saved.single.intervalExpr, isNull);
    expect(
      (txs.saved.single.toCreateJson()['frequency'] as Map).containsKey(
        'intervalExpr',
      ),
      isFalse,
    );
  });

  testWidgets('interval formula errors block Save', (tester) async {
    final txs = await _pump(
      tester,
      existing: _series(3, RecurrenceUnit.months),
    );
    await _type(tester, 'editor-interval', r'$months / 5');
    expect(_error(tester, 'editor-interval'), contains('whole number'));
    await _type(tester, 'editor-interval', r'$months * 10');
    expect(_error(tester, 'editor-interval'), '2–99');
    await _type(tester, 'editor-interval', r'$nope + 1');
    expect(_error(tester, 'editor-interval'), contains('nope'));
    await _save(tester);
    expect(txs.saved, isEmpty);
  });

  testWidgets('a rule change keeps a formula N (its error explains)', (
    tester,
  ) async {
    await _pump(tester, existing: _series(1, RecurrenceUnit.days));
    await tester.ensureVisible(_k('editor-freq-every_n_months'));
    await tester.tap(_k('editor-freq-every_n_months'));
    await tester.pumpAndSettle();
    await _type(tester, 'editor-interval', r'$months / 12');
    await tester.tap(_k('editor-freq-every_n_weeks'));
    await tester.pumpAndSettle();
    expect(_text(tester, 'editor-interval'), r'$months / 12');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(_error(tester, 'editor-interval'), '2–99');
  });

  testWidgets('count formula: occurrenceCountExpr and value', (tester) async {
    final txs = await _pump(
      tester,
      existing: _series(1, RecurrenceUnit.weeks, count: 6),
    );
    await _type(tester, 'editor-count', r'$months / 2');
    expect(_error(tester, 'editor-count'), isNull);
    await _save(tester);
    final e = txs.saved.single;
    expect(e.occurrenceCount, 6);
    expect(e.occurrenceCountExpr, r'$months / 2');
    expect(e.toCreateJson()['occurrenceCountExpr'], r'$months / 2');
  });

  testWidgets('count errors: "At least 1" unchanged, formula errors', (
    tester,
  ) async {
    final txs = await _pump(
      tester,
      existing: _series(1, RecurrenceUnit.weeks, count: 6),
    );
    await _type(tester, 'editor-count', '0');
    expect(_error(tester, 'editor-count'), 'At least 1');
    await _type(tester, 'editor-count', r'$months - 12');
    expect(_error(tester, 'editor-count'), isNotNull);
    await _type(tester, 'editor-count', r'$months / 5');
    expect(_error(tester, 'editor-count'), contains('whole number'));
    await _save(tester);
    expect(txs.saved, isEmpty);
  });

  testWidgets('formulas off: the stock fields, no exprs', (tester) async {
    ServerFeatures.variables = false;
    final txs = await _pump(
      tester,
      existing: _series(3, RecurrenceUnit.months, count: 6),
    );
    await _type(tester, 'editor-interval', r'$4');
    expect(_text(tester, 'editor-interval'), '4');
    await _type(tester, 'editor-count', r'$months');
    expect(_error(tester, 'editor-count'), 'At least 1');
    await _type(tester, 'editor-count', '8');
    await _save(tester);
    final json = txs.saved.single.toCreateJson();
    expect(jsonEncode(json), isNot(contains('Expr')));
  });

  testWidgets('saved formulas show; a saved error is flagged', (tester) async {
    await _pump(
      tester,
      existing: _series(
        3,
        RecurrenceUnit.months,
        count: 6,
        intervalExpr: r'$gone + 1',
        countExpr: r'$months / 2',
        exprErrors: {
          'interval': {'message': 'Unknown variable: gone'},
        },
      ),
    );
    expect(_text(tester, 'editor-interval'), r'$gone + 1');
    expect(_text(tester, 'editor-count'), r'$months / 2');
    expect(_error(tester, 'editor-interval'), contains('no longer works'));
    expect(_step(tester, 'plus').onPressed, isNull);
  });

  for (final size in const [Size(700, 1600), Size(400, 1600)]) {
    testWidgets('widened interval box golden (${size.width})', (tester) async {
      await _pump(
        tester,
        existing: _series(3, RecurrenceUnit.months),
        size: size,
      );
      await _type(tester, 'editor-interval', r'$months / 6');
      await expectLater(
        _k('editor-freq'),
        matchesGoldenFile(
          '../goldens/rollout_c_interval_formula_${size.width.toInt()}.png',
        ),
      );
    });
  }
}
