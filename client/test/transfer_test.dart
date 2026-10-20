import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/transactions/transaction_editor.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/widgets/account_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_accounts.dart';

final _accounts = [
  testAccount('a', 'Everyday'),
  testAccount('s', 'Savings'),
  testAccount('b', 'Ops', shared: true, role: Role.editor, ownerName: 'Sam'),
  testAccount('v', 'Kids', shared: true, role: Role.viewer, ownerName: 'Sam'),
];

FakeAccountRepository _repo() => FakeAccountRepository(accounts: List.of(_accounts));

class _Txs extends TransactionRepository {
  _Txs() : super(ApiClient());
  final created = <Map<String, dynamic>>[];
  @override
  Future<List<Transaction>> listForAccount(String accountId) async => [];
  @override
  Future<Transaction> create(String accountId, Transaction draft) async {
    created.add(draft.toCreateJson());
    return draft;
  }
}

Transaction _transfer(TransactionDirection dir, String peer) =>
    Transaction.fromJson({
      'id': 't1',
      'accountId': 'a',
      'name': 'Save',
      'direction': dir.name,
      'amount': '10',
      'startDate': '2026-10-20',
      'recurrenceMode': 'once',
      'endMode': 'never',
      'transfer': {
        'id': 'x',
        'peerTransactionId': 't2',
        'peerAccountId': 'b',
        'peerAccountName': peer,
      },
    });

void main() {
  test('transfer JSON parses and patches carry the destination', () {
    final t = _transfer(TransactionDirection.debit, 'Ops');
    expect(t.isTransfer, isTrue);
    expect(t.transfer!.peerAccountName, 'Ops');
    expect(t.toCreateJson()['transferToAccountId'], 'b');
    expect(transactionLabel(t), 'Save · To: Ops');
    expect(
      transactionLabel(_transfer(TransactionDirection.credit, 'Ops')),
      'Save · From: Ops',
    );
    expect(transferPhrase(_transfer(TransactionDirection.credit, 'Ops')),
        'From: Ops');
    expect(transferPhrase(t), 'To: Ops');
    // An unnamed incoming transfer reads just "From: <account>".
    expect(
      transactionLabel(
        _transfer(TransactionDirection.credit, 'Ops').copyWith(name: ''),
      ),
      'From: Ops',
    );
    // A plain series explicitly sends null (unlinks on patch).
    final plain = t.copyWith(clearTransfer: true);
    expect(plain.toCreateJson().containsKey('transferToAccountId'), isTrue);
    expect(plain.toCreateJson()['transferToAccountId'], isNull);
    expect(transactionLabel(plain), 'Save');
  });

  Future<_Txs> pumpEditor(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final txs = _Txs();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider.overrideWithValue(_repo()),
          transactionRepositoryProvider.overrideWithValue(txs),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: TransactionEditor(
              accountId: 'a',
              initialDate: DateTime(2026, 10, 20),
              onDone: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('editor-name')), 'Save');
    await tester.enterText(find.byKey(const ValueKey('editor-amount')), '10');
    await tester.tap(find.byKey(const ValueKey('editor-kind-transfer')));
    await tester.pumpAndSettle();
    expect(find.text('To account'), findsOneWidget);
    expect(find.text('Solve from a target total…'), findsNothing);
    return txs;
  }

  testWidgets('desktop: Transfer offers every account I can edit except the '
      'source, mine then shared', (tester) async {
    final txs = await pumpEditor(tester, const Size(1200, 1600));
    // Saving without a destination is blocked.
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('Pick the other account'), findsOneWidget);
    expect(txs.created, isEmpty);

    await tester.tap(find.byKey(const ValueKey('editor-transfer-account')));
    await tester.pumpAndSettle();
    expect(find.byType(SubmenuButton), findsNothing);
    expect(find.byKey(const ValueKey('transfer-header-mine')), findsOneWidget);
    expect(find.byKey(const ValueKey('transfer-header-shared')), findsOneWidget);
    // Headers are not focusable menu items.
    expect(
      find.ancestor(
        of: find.text('Shared with me'),
        matching: find.byType(MenuItemButton),
      ),
      findsNothing,
    );
    // The source and read-only accounts are not offered.
    expect(find.byKey(const ValueKey('transfer-account-a')), findsNothing);
    expect(find.byKey(const ValueKey('transfer-account-v')), findsNothing);
    expect(find.byKey(const ValueKey('transfer-account-s')), findsOneWidget);
    expect(find.byKey(const ValueKey('transfer-new-account')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('transfer-account-b')));
    await tester.pumpAndSettle();
    expect(find.text('To: Ops'), findsOneWidget);
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(txs.created.single['transferToAccountId'], 'b');
    expect(txs.created.single['direction'], 'debit');
  });

  testWidgets('phone: the transfer picker is an on-screen dropdown', (
    tester,
  ) async {
    await pumpEditor(tester, const Size(390, 1600));
    await tester.tap(find.byKey(const ValueKey('editor-transfer-account')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Projects:'), findsNothing);
    expect(find.byKey(const ValueKey('transfer-account-a')), findsNothing);
    final item = tester.getRect(find.byKey(const ValueKey('transfer-account-s')));
    expect(item.right, lessThanOrEqualTo(390));
    expect(item.height, greaterThanOrEqualTo(44));
    await tester.tap(find.byKey(const ValueKey('transfer-account-s')));
    await tester.pumpAndSettle();
    expect(find.text('To: Savings'), findsOneWidget);
  });

  testWidgets('AccountPicker marks the current account', (tester) async {
    Account? picked;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider.overrideWithValue(_repo()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: AccountPicker(
              keyPrefix: 'nav',
              currentAccountId: 'a',
              onSelected: (a) => picked = a,
              builder: (context, open) =>
                  TextButton(onPressed: open, child: const Text('Jump')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nav-account-s')));
    await tester.pumpAndSettle();
    expect(picked?.id, 's');
  });
}
