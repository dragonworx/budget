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
}
