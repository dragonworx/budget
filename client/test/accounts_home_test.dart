// Landing after sign-in: the last-used account opens directly; with none, the
// Accounts home shows an empty state with New account; creating one lands in
// it. There are no projects.
import 'package:budget_client/app.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_accounts.dart';
import 'support/fake_auth.dart';

Future<ProviderContainer> _app(
  WidgetTester tester,
  FakeAccountRepository repo, {
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
      accountRepositoryProvider.overrideWithValue(repo),
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
  testWidgets('lands on the last-used account', (tester) async {
    final repo = FakeAccountRepository(
      accounts: [testAccount('a1', 'Everyday'), testAccount('a2', 'Savings')],
      lastAccountId: 'a2',
    );
    final c = await _app(tester, repo, size: const Size(1200, 900));
    expect(_path(c), '/accounts/a2/timeline');
    // Opening another account (even from cache) records it server-side.
    c.read(routerProvider).go('/accounts/a1/timeline');
    await tester.pumpAndSettle();
    c.read(routerProvider).go('/accounts/a2/timeline');
    await tester.pumpAndSettle();
    expect(repo.opened, ['a2', 'a1', 'a2']);
  });

  testWidgets('lands once per session: Manage accounts stays on the list', (
    tester,
  ) async {
    final repo = FakeAccountRepository(
      accounts: [testAccount('a1', 'Everyday')],
      lastAccountId: 'a1',
    );
    final c = await _app(tester, repo);
    expect(_path(c), '/accounts/a1/timeline');
    c.read(routerProvider).go('/');
    await tester.pumpAndSettle();
    expect(_path(c), '/');
    expect(find.byKey(const ValueKey('account-card-a1')), findsOneWidget);
    c.read(routerProvider).go(accountsPath);
    await tester.pumpAndSettle();
    expect(_path(c), accountsPath);
  });

  testWidgets('no last account: the Accounts home lists mine and shared', (
    tester,
  ) async {
    final repo = FakeAccountRepository(
      accounts: [
        testAccount('a1', 'Everyday'),
        testAccount('b1', 'Joint', shared: true, role: Role.editor, ownerName: 'Sam'),
      ],
      lastAccountId: 'gone',
    );
    final c = await _app(tester, repo);
    expect(_path(c), '/');
    expect(find.text('Accounts'), findsWidgets);
    expect(find.byKey(const ValueKey('new-account')), findsOneWidget);
    expect(find.byKey(const ValueKey('mine-heading')), findsOneWidget);
    expect(find.byKey(const ValueKey('shared-heading')), findsOneWidget);
    expect(find.byKey(const ValueKey('role-chip-editor')), findsOneWidget);
    expect(find.textContaining('roject'), findsNothing);
  });

  testWidgets('first sign-in: empty state, New account creates and lands in '
      'it', (tester) async {
    final repo = FakeAccountRepository();
    final c = await _app(tester, repo);
    expect(_path(c), '/');
    expect(find.byKey(const ValueKey('accounts-empty')), findsOneWidget);
    expect(find.textContaining('roject'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('new-account')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('account-name')), 'Everyday');
    await tester.tap(find.byKey(const ValueKey('account-save')));
    await tester.pumpAndSettle();
    expect(repo.created.single.name, 'Everyday');
    expect(_path(c), '/accounts/new-1/timeline');
  });
}
