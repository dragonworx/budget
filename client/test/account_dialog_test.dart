import 'package:decimal/decimal.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/widgets/account_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Future<Account?>> _open(
  WidgetTester tester, {
  Account? existing,
  Future<Account> Function(Account)? onSave,
}) async {
  late Future<Account?> result;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => result = showAccountDialog(
            context,
            projectId: 'p1',
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
  testWidgets(
    'create runs onSave in the dialog and returns the saved account',
    (tester) async {
      Account? draft;
      final result = await _open(
        tester,
        onSave: (a) async {
          draft = a;
          return a.copyWith(id: 'new-id');
        },
      );
      await tester.enterText(find.byType(TextField).first, 'Holiday');
      await tester.tap(find.byKey(const ValueKey('account-save')));
      await tester.pumpAndSettle();
      expect(draft?.name, 'Holiday');
      expect(find.byType(AccountDialog), findsNothing);
      expect((await result)?.id, 'new-id');
    },
  );

  testWidgets('a failed save keeps the dialog open with the error', (
    tester,
  ) async {
    await _open(tester, onSave: (_) async => throw Exception('offline'));
    await tester.enterText(find.byType(TextField).first, 'Holiday');
    await tester.tap(find.byKey(const ValueKey('account-save')));
    await tester.pumpAndSettle();
    expect(find.byType(AccountDialog), findsOneWidget);
    expect(find.byKey(const ValueKey('account-save-error')), findsOneWidget);
    expect(find.textContaining('offline'), findsOneWidget);
  });

  test('seedShiftDays counts calendar days', () {
    expect(seedShiftDays(DateTime(2026, 10, 16), DateTime(2026, 10, 23)), 7);
    expect(seedShiftDays(DateTime(2026, 4, 10, 23), DateTime(2026, 4, 3)), -7);
  });

  testWidgets('changing the seed date shows the move note', (tester) async {
    final existing = Account(
      id: 'a1',
      projectId: 'p1',
      name: 'Main',
      currency: 'AUD',
      seedBalance: Decimal.zero,
      seedDate: DateTime(2026, 10, 16),
      lossThreshold: Decimal.zero,
      transactionOrder: const ['t1', 't2', 't3'],
    );
    await _open(tester, existing: existing);
    expect(find.byKey(const ValueKey('seed-move-note')), findsNothing);
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
