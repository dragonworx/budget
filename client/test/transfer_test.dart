import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/transactions/transaction_editor.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/widgets/account_picker.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Account _acct(String id, String project, String name) => Account(
  id: id,
  projectId: project,
  name: name,
  seedBalance: Decimal.zero,
  seedDate: DateTime(2026, 10, 1),
  lossThreshold: Decimal.zero,
);

final _projects = [
  Project(id: 'p1', name: 'Home', createdAt: DateTime(2026)),
  Project(id: 'p2', name: 'Business', createdAt: DateTime(2026)),
];
final _accounts = {
  'p1': [_acct('a', 'p1', 'Everyday'), _acct('s', 'p1', 'Savings')],
  'p2': [_acct('b', 'p2', 'Ops')],
};

class _Projects extends ProjectRepository {
  _Projects() : super(ApiClient());
  @override
  Future<List<Project>> list() async => _projects;
}

class _Accounts extends AccountRepository {
  _Accounts() : super(ApiClient());
  @override
  Future<List<Account>> listForProject(String projectId) async =>
      _accounts[projectId]!;
}

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
        'peerProjectName': 'Business',
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
          projectRepositoryProvider.overrideWithValue(_Projects()),
          accountRepositoryProvider.overrideWithValue(_Accounts()),
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

  testWidgets('desktop: Transfer uses a project > account cascading menu', (
    tester,
  ) async {
    final txs = await pumpEditor(tester, const Size(1200, 1600));
    // Saving without a destination is blocked.
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('Pick the other account'), findsOneWidget);
    expect(txs.created, isEmpty);

    await tester.tap(find.byKey(const ValueKey('editor-transfer-account')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('transfer-header-projects')),
      findsOneWidget,
    );
    expect(find.text('Projects:'), findsOneWidget);
    // Headers are not focusable menu items.
    expect(
      find.ancestor(
        of: find.text('Projects:'),
        matching: find.byType(MenuItemButton),
      ),
      findsNothing,
    );
    // The source account itself is not offered.
    await tester.tap(find.byKey(const ValueKey('transfer-project-p1')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('transfer-header-accounts-p1')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('transfer-account-a')), findsNothing);
    expect(find.byKey(const ValueKey('transfer-account-s')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('transfer-project-p2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('transfer-account-b')));
    await tester.pumpAndSettle();
    expect(find.text('To: Ops'), findsOneWidget);
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(txs.created.single['transferToAccountId'], 'b');
    expect(txs.created.single['direction'], 'debit');
  });

  testWidgets('phone: the transfer picker is a dropdown; tapping a project '
      'opens its accounts below it', (tester) async {
    await pumpEditor(tester, const Size(390, 1600));
    await tester.tap(find.byKey(const ValueKey('editor-transfer-account')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Projects:'), findsOneWidget);
    expect(find.byKey(const ValueKey('transfer-account-b')), findsNothing);
    final row = tester.getRect(
      find.byKey(const ValueKey('transfer-project-p2')),
    );
    await tester.tap(find.byKey(const ValueKey('transfer-project-p2')));
    await tester.pumpAndSettle();
    // The source account itself is not offered.
    expect(find.byKey(const ValueKey('transfer-account-a')), findsNothing);
    final item = tester.getRect(
      find.byKey(const ValueKey('transfer-account-b')),
    );
    // Opens below its project row (not off the side of a narrow screen).
    expect(item.top, greaterThanOrEqualTo(row.bottom - 1));
    expect(item.right, lessThanOrEqualTo(390));
    await tester.tap(find.byKey(const ValueKey('transfer-account-b')));
    await tester.pumpAndSettle();
    expect(find.text('Projects:'), findsNothing);
    expect(find.text('To: Ops'), findsOneWidget);
    expect(find.textContaining('(Business)'), findsOneWidget);
  });

  testWidgets('AccountPicker marks the current account', (tester) async {
    Account? picked;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectRepositoryProvider.overrideWithValue(_Projects()),
          accountRepositoryProvider.overrideWithValue(_Accounts()),
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
    await tester.tap(find.byKey(const ValueKey('nav-project-p1')));
    await tester.pumpAndSettle();
    // A second click (e.g. after hover opened it) keeps it open.
    await tester.tap(find.byKey(const ValueKey('nav-project-p1')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nav-account-s')));
    await tester.pumpAndSettle();
    expect(picked?.id, 's');
  });
}
