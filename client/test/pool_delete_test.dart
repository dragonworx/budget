// Deleting a pool: a pool with transactions confirms with a scrollable,
// grouped list and a choice for its transfers' far sides (keep there as
// plain rows, default; or delete, only when I can edit every other pool);
// an empty pool keeps the plain confirm. Afterwards nothing stale is left:
// the card goes, other pools' transactions / balances refetch, this
// browser forgets the pool's saved view and combine choices; another tab
// on the pool leaves it, and a deep link to a gone pool falls back home.
import 'package:budget_client/app.dart';
import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/realtime_service.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/pools/delete_pool_dialog.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/pool_cleanup.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/state/realtime_providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth.dart';
import 'support/fake_pools.dart';

Transaction _tx(
  String id,
  String pool,
  String name, {
  TransactionDirection dir = TransactionDirection.debit,
  int amount = 10,
  TransferLink? transfer,
}) => Transaction(
  id: id,
  poolId: pool,
  name: name,
  direction: dir,
  amount: Decimal.fromInt(amount),
  startDate: DateTime(2026, 10, 1),
  recurrenceMode: RecurrenceMode.every,
  interval: 1,
  unit: RecurrenceUnit.months,
  endMode: EndMode.never,
  transfer: transfer,
);

class _Pools extends FakePoolRepository {
  _Pools(List<Pool> pools) : super(pools: pools);
  final deletes = <(String, PoolDeleteTransfers)>[];
  final balances = <String>[];
  @override
  Future<void> delete(
    String id, {
    PoolDeleteTransfers transfers = PoolDeleteTransfers.keep,
  }) async {
    deletes.add((id, transfers));
    pools.removeWhere((p) => p.id == id);
  }

  @override
  Future<BalanceSeries> balance(
    String poolId, {
    required DateTime from,
    required DateTime to,
  }) async {
    balances.add(poolId);
    return const BalanceSeries(points: []);
  }
}

class _Txs extends TransactionRepository {
  _Txs(this.byPool) : super(ApiClient());
  final Map<String, List<Transaction>> byPool;
  final lists = <String>[];
  @override
  Future<List<Transaction>> listForPool(String poolId) async {
    lists.add(poolId);
    return byPool[poolId] ?? [];
  }
}

Future<ProviderContainer> _app(
  WidgetTester tester,
  _Pools pools,
  _Txs txs, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final c = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(user: adminUser),
      ),
      poolRepositoryProvider.overrideWithValue(pools),
      transactionRepositoryProvider.overrideWithValue(txs),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: c, child: const BudgetApp()),
  );
  await tester.pumpAndSettle();
  return c;
}

String _path(ProviderContainer c) =>
    c.read(routerProvider).routerDelegate.currentConfiguration.uri.path;

Future<void> _openDelete(WidgetTester tester, String poolId) async {
  final card = find.byKey(ValueKey('pool-card-$poolId'));
  await tester.tap(
    find.descendant(of: card, matching: find.byTooltip('Pool actions')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Delete pool').last);
  await tester.pumpAndSettle();
}

/// a1 (deleting) has 25 own rows, sends to b1 and receives from c1.
Map<String, List<Transaction>> _world() => {
  'a1': [
    for (var i = 0; i < 25; i++) _tx('own$i', 'a1', 'Own $i'),
    _tx(
      'tx-out',
      'a1',
      'To savings',
      amount: 50,
      transfer: const TransferLink(
        id: 'x1',
        peerPoolId: 'b1',
        peerPoolName: 'Savings',
      ),
    ),
    _tx(
      'tx-in',
      'a1',
      'Pocket money',
      dir: TransactionDirection.credit,
      amount: 20,
      transfer: const TransferLink(
        id: 'x2',
        peerPoolId: 'c1',
        peerPoolName: 'Kids',
      ),
    ),
  ],
  'b1': [
    _tx(
      'peer-out',
      'b1',
      'To savings',
      dir: TransactionDirection.credit,
      amount: 50,
      transfer: const TransferLink(
        id: 'x1',
        peerPoolId: 'a1',
        peerPoolName: 'Everyday',
      ),
    ),
  ],
  'c1': [],
};

void main() {
  setUp(() {
    page.clearLocal();
    resetForgottenPools();
  });

  group('dialog', () {
    Future<PoolDeleteTransfers?> Function() show(
      WidgetTester tester,
      List<Pool> pools,
    ) {
      PoolDeleteTransfers? result;
      var done = false;
      return () async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDeletePoolDialog(
                    context,
                    pool: pools.first,
                    transactions: _world()['a1']!,
                    pools: pools,
                  );
                  done = true;
                },
                child: const Text('go'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        return done ? result : null;
      };
    }

    testWidgets('groups own rows and transfers in a scrollable list; delete '
        'is disabled when I cannot edit another pool', (tester) async {
      await show(tester, [
        testPool('a1', 'Everyday'),
        testPool('b1', 'Savings'),
        testPool('c1', 'Kids', shared: true, role: Role.viewer),
      ])();
      expect(find.byKey(const ValueKey('pool-delete-dialog')), findsOneWidget);
      expect(find.text('In this pool (deleted with it)'), findsOneWidget);
      expect(find.textContaining('and its 27 transactions'), findsOneWidget);
      // The list is bounded and scrolls to the transfers at the end.
      final list = find.byKey(const ValueKey('pool-delete-list'));
      expect(tester.getSize(list).height, lessThan(844 * 0.41));
      expect(find.byKey(const ValueKey('pool-delete-row-tx-in')), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('pool-delete-row-tx-in')),
        200,
        scrollable: find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('Transfers with other pools'), findsOneWidget);
      expect(find.text('To Savings · Every month'), findsOneWidget);
      expect(find.text('From Kids · Every month'), findsOneWidget);
      String amountIn(String id) => tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(ValueKey('pool-delete-row-$id')),
              matching: find.byType(Text),
            ),
          )
          .last
          .data!;
      expect(amountIn('tx-out'), startsWith('−'));
      expect(amountIn('tx-out'), contains('50'));
      expect(amountIn('tx-in'), startsWith('+'));
      expect(
        find.text('Keep in Savings and Kids as plain transactions'),
        findsOneWidget,
      );
      final remove = tester.widget<RadioListTile<PoolDeleteTransfers>>(
        find.byKey(const ValueKey('pool-delete-remove')),
      );
      expect(remove.enabled, isFalse);
      expect(find.textContaining("You can't edit Kids"), findsOneWidget);
      // Danger button.
      final confirm = tester.widget<FilledButton>(
        find.byKey(const ValueKey('pool-delete-confirm')),
      );
      final ctx = tester.element(
        find.byKey(const ValueKey('pool-delete-confirm')),
      );
      expect(
        confirm.style?.backgroundColor?.resolve({}),
        Theme.of(ctx).colorScheme.error,
      );
    });

    testWidgets('keep is the default; delete can be chosen; cancel is null', (
      tester,
    ) async {
      final pools = [
        testPool('a1', 'Everyday'),
        testPool('b1', 'Savings'),
        testPool('c1', 'Kids', shared: true, role: Role.editor),
      ];
      // Cancel.
      await show(tester, pools)();
      await tester.tap(find.byKey(const ValueKey('pool-delete-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pool-delete-dialog')), findsNothing);
      // Default keep.
      PoolDeleteTransfers? got;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => got = await showDeletePoolDialog(
                context,
                pool: pools.first,
                transactions: _world()['a1']!,
                pools: pools,
              ),
              child: const Text('go2'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pool-delete-confirm')));
      await tester.pumpAndSettle();
      expect(got, PoolDeleteTransfers.keep);
      await tester.tap(find.text('go2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pool-delete-remove')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pool-delete-confirm')));
      await tester.pumpAndSettle();
      expect(got, PoolDeleteTransfers.delete);
    });
  });

  group('pools home', () {
    testWidgets('an empty pool gets the plain confirm and is deleted', (
      tester,
    ) async {
      final pools = _Pools([testPool('a1', 'Everyday'), testPool('b1', 'S')]);
      final c = await _app(tester, pools, _Txs({}));
      c.read(routerProvider).go(poolsPath);
      await tester.pumpAndSettle();
      await _openDelete(tester, 'a1');
      expect(find.byKey(const ValueKey('pool-delete-dialog')), findsNothing);
      expect(find.textContaining('It has no transactions'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete pool'));
      await tester.pumpAndSettle();
      expect(pools.deletes, [('a1', PoolDeleteTransfers.keep)]);
      expect(find.byKey(const ValueKey('pool-card-a1')), findsNothing);
    });

    testWidgets('delete mode is sent; afterwards other pools refetch and '
        'this browser forgets the pool', (tester) async {
      final pools = _Pools([
        testPool('a1', 'Everyday'),
        testPool('b1', 'Savings'),
        testPool('c1', 'Kids'),
      ]);
      final txs = _Txs(_world());
      page.localSet('budget_view:${adminUser.id}:a1', '{}');
      page.localSet('budget_combine:${adminUser.id}:a1', '["b1"]');
      page.localSet('budget_combine:${adminUser.id}:b1', '["a1","c1"]');
      page.localSet('budget_view:${adminUser.id}:b1', '{}');
      final c = await _app(tester, pools, txs);
      c.read(routerProvider).go(poolsPath);
      await tester.pumpAndSettle();
      await c.read(transactionsProvider('b1').future);
      final before = txs.lists.where((p) => p == 'b1').length;
      final balancesBefore = pools.balances.where((p) => p == 'b1').length;
      await _openDelete(tester, 'a1');
      expect(find.byKey(const ValueKey('pool-delete-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pool-delete-remove')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pool-delete-confirm')));
      await tester.pumpAndSettle();
      expect(pools.deletes, [('a1', PoolDeleteTransfers.delete)]);
      expect(find.byKey(const ValueKey('pool-card-a1')), findsNothing);
      expect(find.byKey(const ValueKey('pool-card-b1')), findsOneWidget);
      // Surviving pools' data is fetched again (their far sides changed).
      await c.read(transactionsProvider('b1').future);
      expect(txs.lists.where((p) => p == 'b1').length, greaterThan(before));
      expect(
        pools.balances.where((p) => p == 'b1').length,
        greaterThan(balancesBefore),
      );
      expect(page.localGet('budget_view:${adminUser.id}:a1'), isNull);
      expect(page.localGet('budget_combine:${adminUser.id}:a1'), isNull);
      expect(page.localGet('budget_combine:${adminUser.id}:b1'), '["c1"]');
      expect(page.localGet('budget_view:${adminUser.id}:b1'), '{}');
      expect(c.read(poolsProvider).value!.map((p) => p.id), ['b1', 'c1']);
    });
  });

  testWidgets('another tab on the deleted pool leaves it; other pools '
      'refetch; its local choices go', (tester) async {
    final pools = _Pools([testPool('a1', 'Everyday'), testPool('b1', 'Sav')]);
    final txs = _Txs(_world());
    page.localSet('budget_view:${adminUser.id}:a1', '{}');
    final c = await _app(tester, pools, txs, size: const Size(1200, 900));
    c.read(routerProvider).go('/pools/a1/timeline');
    await tester.pumpAndSettle();
    await c.read(transactionsProvider('b1').future);
    final before = txs.lists.where((p) => p == 'b1').length;
    pools.pools.removeWhere((p) => p.id == 'a1');
    c
        .read(realtimeControllerProvider)
        .handle(const ChangeEvent(id: 9, action: 'pool.deleted', poolId: 'a1'));
    await tester.pumpAndSettle();
    expect(_path(c), poolsPath);
    expect(find.text('This pool was deleted'), findsOneWidget);
    expect(find.byKey(const ValueKey('pool-card-a1')), findsNothing);
    await c.read(transactionsProvider('b1').future);
    expect(txs.lists.where((p) => p == 'b1').length, greaterThan(before));
    expect(page.localGet('budget_view:${adminUser.id}:a1'), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a deep link to a pool that is gone falls back to the pools '
      'home with a note', (tester) async {
    final pools = _Pools([testPool('b1', 'Savings')]);
    page.localSet('budget_view:${adminUser.id}:zz', '{}');
    final c = await _app(tester, pools, _Txs({}));
    c.read(routerProvider).go('/pools/zz/timeline');
    await tester.pumpAndSettle();
    expect(_path(c), poolsPath);
    expect(find.text('That pool no longer exists'), findsOneWidget);
    expect(page.localGet('budget_view:${adminUser.id}:zz'), isNull);
    expect(find.byKey(const ValueKey('pool-card-b1')), findsOneWidget);
  });
}
