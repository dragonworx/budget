// Spec 013 group C "before" goldens: the event editor's interval box
// (between − / +) and the end-after count, recorded on the stock fields
// before FormulaField replaced them. With formulas off (the default in
// tests), and with formulas on and plain numbers, the FormulaField
// screens must match these files byte for byte.
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
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

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(_k(key));
  await tester.enterText(_input(key), text);
  await tester.pumpAndSettle();
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

Future<void> _match(Finder f, String name, Size size) => expectLater(
  f,
  matchesGoldenFile('../goldens/rollout_c_${name}_${size.width.toInt()}.png'),
);

// 400, not 320: the test font (Ahem, every glyph 1 em) overflows today's
// "Every − N + weeks" row below ~370 px; real fonts fit (Playwright 320).
const sizes = [Size(700, 1600), Size(400, 1600)];

void main() {
  for (final size in sizes) {
    testWidgets('interval every 2 weeks (${size.width})', (tester) async {
      await _pump(
        tester,
        existing: _series(2, RecurrenceUnit.weeks),
        size: size,
      );
      await _match(_k('editor-freq'), 'interval', size);
    });

    testWidgets('interval typed 0 (${size.width})', (tester) async {
      await _pump(
        tester,
        existing: _series(3, RecurrenceUnit.months),
        size: size,
      );
      await _type(tester, 'editor-interval', '0');
      await _match(_k('editor-freq'), 'interval_error', size);
    });

    testWidgets('interval stepped up (${size.width})', (tester) async {
      await _pump(
        tester,
        existing: _series(2, RecurrenceUnit.weeks),
        size: size,
      );
      await tester.ensureVisible(_k('editor-interval-plus'));
      await tester.tap(_k('editor-interval-plus'));
      await tester.pumpAndSettle();
      await _match(_k('editor-freq'), 'interval_plus', size);
    });

    testWidgets('count 6 (${size.width})', (tester) async {
      await _pump(
        tester,
        existing: _series(1, RecurrenceUnit.weeks, count: 6),
        size: size,
      );
      await tester.ensureVisible(_k('editor-count'));
      await tester.pumpAndSettle();
      await _match(_k('editor-count'), 'count', size);
    });

    testWidgets('count typed 0 (${size.width})', (tester) async {
      await _pump(
        tester,
        existing: _series(1, RecurrenceUnit.weeks, count: 6),
        size: size,
      );
      await _type(tester, 'editor-count', '0');
      await _match(_k('editor-count'), 'count_error', size);
    });
  }
}
