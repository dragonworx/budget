import 'package:decimal/decimal.dart';
import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/data/models.dart';
import 'package:budget_client/widgets/pool_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Future<Pool?>> _open(
  WidgetTester tester, {
  Pool? existing,
  Future<Pool> Function(Pool)? onSave,
}) async {
  late Future<Pool?> result;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => result = showPoolDialog(
            context,
            existing: existing,
            onSave: onSave,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('create runs onSave in the dialog and returns the saved pool', (
    tester,
  ) async {
    Pool? draft;
    final result = await _open(
      tester,
      onSave: (a) async {
        draft = a;
        return a.copyWith(id: 'new-id');
      },
    );
    await tester.enterText(find.byType(TextField).first, 'Holiday');
    await tester.tap(find.byKey(const ValueKey('pool-save')));
    await tester.pumpAndSettle();
    expect(draft?.name, 'Holiday');
    expect(find.byType(PoolDialog), findsNothing);
    expect((await result)?.id, 'new-id');
  });

  testWidgets('a failed save keeps the dialog open with the error', (
    tester,
  ) async {
    await _open(tester, onSave: (_) async => throw Exception('offline'));
    await tester.enterText(find.byType(TextField).first, 'Holiday');
    await tester.tap(find.byKey(const ValueKey('pool-save')));
    await tester.pumpAndSettle();
    expect(find.byType(PoolDialog), findsOneWidget);
    expect(find.byKey(const ValueKey('pool-save-error')), findsOneWidget);
    expect(find.textContaining('offline'), findsOneWidget);
  });

  testWidgets('the dialog has no currency field; amounts use a plain \$', (
    tester,
  ) async {
    await _open(tester, onSave: (a) async => a);
    expect(find.byKey(const ValueKey('pool-currency')), findsNothing);
    expect(find.text('Currency'), findsNothing);
    expect(find.textContaining('3-letter code'), findsNothing);
    final seed = tester.widget<TextField>(
      find.byKey(const ValueKey('pool-seed')),
    );
    expect(seed.decoration?.prefixText, r'$ ');
    // New pools have no Currency Scale field (they start at Hundreds).
    expect(find.textContaining('Currency Scale'), findsNothing);
  });

  testWidgets('New pool: Name is focused on open and the soft keyboard is '
      'primed inside the tap; Edit pool does neither', (tester) async {
    final before = page.primeSoftKeyboardCalls;
    await _open(tester, onSave: (a) async => a);
    expect(page.primeSoftKeyboardCalls, before + 1);
    final name = tester.widget<TextField>(
      find.byKey(const ValueKey('pool-name')),
    );
    expect(name.focusNode?.hasFocus, isTrue);
    // Typing goes straight into Name.
    tester.testTextInput.enterText('Holiday');
    await tester.pump();
    expect(name.controller?.text, 'Holiday');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    final existing = Pool(
      id: 'a1',
      name: 'Main',
      seedBalance: Decimal.zero,
      seedDate: DateTime(2026, 10, 16),
      lossThreshold: Decimal.zero,
    );
    final primed = page.primeSoftKeyboardCalls;
    await _open(tester, existing: existing, onSave: (a) async => a);
    expect(page.primeSoftKeyboardCalls, primed);
    expect(find.text('Currency Scale'), findsOneWidget);
  });

  testWidgets('New pool: focus taken away while it opens (a closing menu) '
      'comes back to Name', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPoolDialog(context, onSave: (a) async => a),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    TextField name() =>
        tester.widget<TextField>(find.byKey(const ValueKey('pool-name')));
    expect(name().focusNode?.hasFocus, isFalse);
    await tester.pump(poolNameRefocusDelay);
    expect(name().focusNode?.hasFocus, isTrue);
    await tester.pumpAndSettle();
  });

  test('seedShiftDays counts calendar days', () {
    expect(seedShiftDays(DateTime(2026, 10, 16), DateTime(2026, 10, 23)), 7);
    expect(seedShiftDays(DateTime(2026, 4, 10, 23), DateTime(2026, 4, 3)), -7);
  });

  testWidgets('changing the seed date shows the move note', (tester) async {
    final existing = Pool(
      id: 'a1',
      name: 'Main',
      seedBalance: Decimal.zero,
      seedDate: DateTime(2026, 10, 16),
      lossThreshold: Decimal.zero,
      transactionOrder: const ['t1', 't2', 't3'],
    );
    await _open(tester, existing: existing);
    expect(find.byKey(const ValueKey('seed-move-note')), findsNothing);
    await tester.ensureVisible(find.text('Fri 16 Oct 2026'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fri 16 Oct 2026'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('23'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(
      find.text('All 3 transactions will move 7 days later'),
      findsOneWidget,
    );
  });
}
