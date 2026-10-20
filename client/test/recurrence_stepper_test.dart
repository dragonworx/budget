// Transaction editor schedule: Once / Repeats, then Every [− N +] [unit ▾].
// Every former preset (weekly, fortnightly, monthly, quarterly, yearly …) is
// just N + unit, so existing series open and save unchanged.
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/frequency.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/transactions/transaction_editor.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Projects extends ProjectRepository {
  _Projects() : super(ApiClient());
  @override
  Future<List<Project>> list() async => [];
}

class _Txs extends TransactionRepository {
  _Txs() : super(ApiClient());
  final saved = <Transaction>[];
  @override
  Future<List<Transaction>> listForAccount(String accountId) async => [];
  @override
  Future<Transaction> create(String accountId, Transaction draft) async {
    saved.add(draft);
    return draft;
  }

  @override
  Future<Transaction> update(Transaction t, {bool force = false}) async {
    saved.add(t);
    return t;
  }
}

Transaction _series(int? interval, RecurrenceUnit? unit) => Transaction(
  id: 't1',
  accountId: 'a',
  name: 'Rent',
  direction: TransactionDirection.debit,
  amount: Decimal.fromInt(100),
  startDate: DateTime(2026, 10, 20),
  recurrenceMode: interval == null ? RecurrenceMode.once : RecurrenceMode.every,
  interval: interval,
  unit: unit,
  endMode: EndMode.never,
  version: 1,
);

Future<_Txs> _pump(WidgetTester tester, {Transaction? existing}) async {
  tester.view.physicalSize = const Size(390, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final txs = _Txs();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        projectRepositoryProvider.overrideWithValue(_Projects()),
        transactionRepositoryProvider.overrideWithValue(txs),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: TransactionEditor(
            accountId: 'a',
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

String _intervalText(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('editor-interval')),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

Future<void> _touch(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  final g = await tester.startGesture(
    tester.getCenter(f),
    kind: PointerDeviceKind.touch,
  );
  await g.up();
  await tester.pumpAndSettle();
}

void main() {
  for (final preset in FrequencyPreset.repeating) {
    testWidgets('${preset.label} opens as Every ${preset.interval} '
        '${preset.unit!.name} and saves unchanged', (tester) async {
      final txs = await _pump(
        tester,
        existing: _series(preset.interval, preset.unit),
      );
      expect(_intervalText(tester), '${preset.interval}');
      final unit = tester.widget<DropdownButtonFormField<RecurrenceUnit>>(
        find.byKey(const ValueKey('editor-unit')),
      );
      expect(unit.initialValue, preset.unit);
      await _touch(tester, find.byKey(const ValueKey('editor-save')));
      // Unchanged: nothing to save, or saved with the same schedule.
      for (final t in txs.saved) {
        expect(t.recurrenceMode, RecurrenceMode.every);
        expect(t.interval, preset.interval);
        expect(t.unit, preset.unit);
      }
    });
  }

  testWidgets('a non-preset schedule (every 5 weeks) round-trips too', (
    tester,
  ) async {
    await _pump(tester, existing: _series(5, RecurrenceUnit.weeks));
    expect(_intervalText(tester), '5');
    expect(find.text('weeks'), findsWidgets);
  });

  testWidgets('a one-off opens as Once, with no Every row', (tester) async {
    await _pump(tester, existing: _series(null, null));
    final toggle = tester.widget<SegmentedButton<bool>>(
      find.byKey(const ValueKey('editor-repeats')),
    );
    expect(toggle.selected, {false});
    expect(find.byKey(const ValueKey('editor-interval')), findsNothing);
  });

  testWidgets('touch: − / + step 1…99, are ≥44px, unit is singular for 1; '
      'Once / Repeats toggles the row; the new schedule saves', (tester) async {
    final txs = await _pump(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-name')), 'Gym');
    await tester.enterText(find.byKey(const ValueKey('editor-amount')), '20');
    await tester.pumpAndSettle();
    final minus = find.byKey(const ValueKey('editor-interval-minus'));
    final plus = find.byKey(const ValueKey('editor-interval-plus'));
    for (final b in [minus, plus]) {
      final size = tester.getSize(b);
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }
    // Default: every 1 month; − is disabled at 1.
    expect(_intervalText(tester), '1');
    expect(find.text('month'), findsWidgets);
    expect(tester.widget<IconButton>(minus).onPressed, isNull);
    await _touch(tester, plus);
    await _touch(tester, plus);
    expect(_intervalText(tester), '3');
    expect(find.text('months'), findsWidgets);
    await _touch(tester, minus);
    expect(_intervalText(tester), '2');
    // Typed, capped at two digits; + stops at 99.
    await tester.enterText(
      find.byKey(const ValueKey('editor-interval')),
      '990',
    );
    await tester.pumpAndSettle();
    expect(_intervalText(tester), '99');
    expect(tester.widget<IconButton>(plus).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('editor-interval')), '2');
    await tester.pumpAndSettle();
    // Unit: weeks.
    await _touch(tester, find.byKey(const ValueKey('editor-unit')));
    await _touch(tester, find.byKey(const ValueKey('editor-unit-weeks')).last);
    expect(find.text('weeks'), findsWidgets);
    // Once hides the row; Repeats brings it back with the same values.
    await _touch(tester, find.byKey(const ValueKey('editor-repeats-once')));
    expect(find.byKey(const ValueKey('editor-interval')), findsNothing);
    await _touch(tester, find.byKey(const ValueKey('editor-repeats-every')));
    expect(_intervalText(tester), '2');
    await _touch(tester, find.byKey(const ValueKey('editor-save')));
    expect(txs.saved, isNotEmpty);
    final t = txs.saved.last;
    expect(t.recurrenceMode, RecurrenceMode.every);
    expect(t.interval, 2);
    expect(t.unit, RecurrenceUnit.weeks);
  });
}
