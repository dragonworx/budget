// Landing after sign-in: the last-used pool opens directly; with none, the
// Pools home shows an empty state with New pool; creating one lands in
// it. There are no projects.
import 'package:budget_client/app.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:budget_client/widgets/pool_icon.dart';

import 'support/fake_pools.dart';
import 'support/fake_auth.dart';

Future<ProviderContainer> _app(
  WidgetTester tester,
  FakePoolRepository repo, {
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
      poolRepositoryProvider.overrideWithValue(repo),
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

void main() {
  testWidgets('lands on the last-used pool', (tester) async {
    final repo = FakePoolRepository(
      pools: [testPool('a1', 'Everyday'), testPool('a2', 'Savings')],
      lastPoolId: 'a2',
    );
    final c = await _app(tester, repo, size: const Size(1200, 900));
    expect(_path(c), '/pools/a2/timeline');
    // Opening another pool (even from cache) records it server-side.
    c.read(routerProvider).go('/pools/a1/timeline');
    await tester.pumpAndSettle();
    c.read(routerProvider).go('/pools/a2/timeline');
    await tester.pumpAndSettle();
    expect(repo.opened, ['a2', 'a1', 'a2']);
  });

  testWidgets('lands once per session: going to the Pools home stays there', (
    tester,
  ) async {
    final repo = FakePoolRepository(
      pools: [testPool('a1', 'Everyday')],
      lastPoolId: 'a1',
    );
    final c = await _app(tester, repo);
    expect(_path(c), '/pools/a1/timeline');
    c.read(routerProvider).go('/');
    await tester.pumpAndSettle();
    expect(_path(c), '/');
    expect(find.byKey(const ValueKey('pool-card-a1')), findsOneWidget);
    c.read(routerProvider).go(poolsPath);
    await tester.pumpAndSettle();
    expect(_path(c), poolsPath);
  });

  testWidgets('no last pool: the Pools home lists mine and shared', (
    tester,
  ) async {
    final repo = FakePoolRepository(
      pools: [
        testPool('a1', 'Everyday'),
        testPool(
          'b1',
          'Joint',
          shared: true,
          role: Role.editor,
          ownerName: 'Sam',
        ),
      ],
      lastPoolId: 'gone',
    );
    final c = await _app(tester, repo);
    expect(_path(c), '/');
    expect(find.text('Pools'), findsWidgets);
    expect(find.byKey(const ValueKey('new-pool')), findsOneWidget);
    expect(find.byKey(const ValueKey('mine-heading')), findsOneWidget);
    expect(find.byKey(const ValueKey('shared-heading')), findsOneWidget);
    expect(find.byKey(const ValueKey('role-chip-editor')), findsOneWidget);
    expect(find.textContaining('roject'), findsNothing);
  });

  testWidgets('first sign-in: empty state, New pool creates and lands in '
      'it', (tester) async {
    final repo = FakePoolRepository();
    final c = await _app(tester, repo);
    expect(_path(c), '/');
    expect(find.byKey(const ValueKey('pools-empty')), findsOneWidget);
    // The empty state shows the bucket pool icon at 30px.
    final emptyIcon = find.descendant(
      of: find.byKey(const ValueKey('pools-empty')),
      matching: find.byType(PoolIcon),
    );
    expect(emptyIcon, findsOneWidget);
    expect(tester.getSize(emptyIcon), const Size(30, 30));
    expect(find.textContaining('roject'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('new-pool')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('pool-name')), 'Everyday');
    await tester.tap(find.byKey(const ValueKey('pool-save')));
    await tester.pumpAndSettle();
    expect(repo.created.single.name, 'Everyday');
    expect(_path(c), '/pools/new-1/timeline');
  });

  for (final size in const [Size(390, 844), Size(1440, 900)]) {
    testWidgets('${size.width.toInt()}px: the header pool menu has no '
        'Manage pools (mine, shared, New pool stay); the back arrow '
        '("All pools") opens the Pools home', (tester) async {
      final repo = FakePoolRepository(
        pools: [
          testPool('a1', 'Everyday'),
          testPool('a2', 'Savings'),
          testPool('b1', 'Kids', shared: true, role: Role.viewer),
        ],
        lastPoolId: 'a1',
      );
      final c = await _app(tester, repo, size: size);
      expect(_path(c), '/pools/a1/timeline');
      await tester.tap(find.byKey(const ValueKey('header-pool-picker')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('nav-header-mine')), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-pool-a2')), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-header-shared')), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-pool-b1')), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-new-pool')), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-manage-pools')), findsNothing);
      expect(find.text('Manage pools'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      final back = find.byKey(const ValueKey('timeline-back'));
      expect(back, findsOneWidget);
      expect(find.byTooltip('All pools'), findsOneWidget);
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(_path(c), poolsPath);
      expect(find.byKey(const ValueKey('pool-card-a1')), findsOneWidget);
      // Pool cards lead with the bucket pool icon (22px in its tile).
      final cardIcon = find.descendant(
        of: find.byKey(const ValueKey('pool-card-a1')),
        matching: find.byType(PoolIcon),
      );
      expect(cardIcon, findsOneWidget);
      expect(tester.getSize(cardIcon), const Size(22, 22));
      expect(find.byIcon(Icons.account_balance_wallet_rounded), findsNothing);
    });
  }
}
