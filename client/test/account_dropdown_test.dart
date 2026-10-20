// Account selector (header + transfer): an anchored dropdown with a flat list
// of my accounts (current checked), a "Shared with me" section, then the
// New account / Manage accounts actions. No submenus. Rows are touch-sized,
// the menu stays on a 320–390px screen, Esc / outside tap dismiss, and the
// keyboard works.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/widgets/account_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_accounts.dart';

final _all = [
  testAccount('a', 'Everyday'),
  testAccount('s', 'Savings for a very long holiday abroad and more'),
  testAccount('b', 'Joint bills', shared: true, role: Role.editor, ownerName: 'Sam'),
  testAccount('v', 'Kids', shared: true, role: Role.viewer, ownerName: 'Sam'),
];

class _Log {
  final picked = <Account>[];
  int created = 0;
  int managed = 0;
}

Future<_Log> _pump(
  WidgetTester tester,
  Size size, {
  List<Account>? accounts,
  String? exclude,
  bool editableOnly = false,
  bool actions = true,
  Alignment triggerAt = Alignment.topRight,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final log = _Log();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository(accounts: List.of(accounts ?? _all)),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: triggerAt,
            child: AccountPicker(
              keyPrefix: 'nav',
              currentAccountId: 'a',
              excludeAccountId: exclude,
              editableOnly: editableOnly,
              onSelected: log.picked.add,
              onNewAccount: actions ? () => log.created++ : null,
              onManageAccounts: actions ? () => log.managed++ : null,
              builder: (context, open) =>
                  TextButton(onPressed: open, child: const Text('Jump')),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return log;
}

void _expectOnScreen(WidgetTester tester, Finder f, Size size) {
  for (final e in f.evaluate()) {
    final r = tester.getRect(find.byWidget(e.widget));
    expect(r.left, greaterThanOrEqualTo(0), reason: '$r');
    expect(r.right, lessThanOrEqualTo(size.width), reason: '$r');
    expect(r.bottom, lessThanOrEqualTo(size.height), reason: '$r');
  }
}

double _top(WidgetTester tester, String key) =>
    tester.getRect(find.byKey(ValueKey(key))).top;

void main() {
  for (final size in const [Size(320, 640), Size(390, 844)]) {
    final w = size.width.toInt();
    testWidgets('touch at ${w}px: flat mine / shared / actions; rows ≥44px; '
        'all on screen; selecting picks the account', (tester) async {
      final log = await _pump(tester, size);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.touch);
      Future<void> touch(Finder f) async {
        await gesture.down(tester.getCenter(f));
        await gesture.up();
        await tester.pumpAndSettle();
      }

      await touch(find.text('Jump'));
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(SubmenuButton), findsNothing);
      // Order: My accounts, mine, Shared with me, shared, actions.
      final order = [
        'nav-header-mine',
        'nav-account-a',
        'nav-account-s',
        'nav-header-shared',
        'nav-account-b',
        'nav-account-v',
        'nav-new-account',
        'nav-manage-accounts',
      ];
      for (var i = 1; i < order.length; i++) {
        expect(
          _top(tester, order[i]),
          greaterThan(_top(tester, order[i - 1])),
          reason: order[i],
        );
      }
      for (final k in order.where((k) => !k.contains('header'))) {
        expect(
          tester.getSize(find.byKey(ValueKey(k))).height,
          greaterThanOrEqualTo(44),
          reason: k,
        );
      }
      _expectOnScreen(tester, find.byType(MenuItemButton), size);
      // The current account is checked, the others are not.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('nav-account-a')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      // Shared rows carry the people icon (my role in the tooltip).
      expect(find.byKey(const ValueKey('shared-indicator-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('shared-indicator-a')), findsNothing);
      await touch(find.byKey(const ValueKey('nav-account-b')));
      expect(log.picked.single.id, 'b');
      expect(find.byKey(const ValueKey('nav-account-a')), findsNothing);
      await gesture.removePointer();
    });
  }

  testWidgets('a trigger at the left edge of a 320px screen keeps the menu '
      'on screen; the actions fire', (tester) async {
    const size = Size(320, 640);
    final log = await _pump(tester, size, triggerAt: Alignment.topLeft);
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    _expectOnScreen(tester, find.byType(MenuItemButton), size);
    await tester.tap(find.byKey(const ValueKey('nav-new-account')));
    await tester.pumpAndSettle();
    expect(log.created, 1);
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-manage-accounts')));
    await tester.pumpAndSettle();
    expect(log.managed, 1);
  });

  testWidgets('outside tap and Esc dismiss the menu', (tester) async {
    await _pump(tester, const Size(390, 844));
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-account-a')), findsOneWidget);
    await tester.tapAt(const Offset(20, 800));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-account-a')), findsNothing);

    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-account-a')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-account-a')), findsNothing);
  });

  testWidgets('desktop keyboard: focus starts on the first account; arrows '
      'skip headers; Enter picks a shared account', (tester) async {
    final log = await _pump(
      tester,
      const Size(1200, 800),
      triggerAt: Alignment.topLeft,
    );
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    // a -> s -> (header skipped) -> b
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(log.picked.single.id, 'b');
  });

  testWidgets('desktop keyboard reaches New account', (tester) async {
    final log = await _pump(
      tester,
      const Size(1200, 800),
      triggerAt: Alignment.topLeft,
    );
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(log.created, 1);
    expect(log.picked, isEmpty);
  });

  testWidgets('transfer picker: only accounts I can edit, never the source, '
      'grouped mine / shared, no actions', (tester) async {
    final log = await _pump(
      tester,
      const Size(390, 844),
      exclude: 'a',
      editableOnly: true,
      actions: false,
    );
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-account-a')), findsNothing);
    expect(find.byKey(const ValueKey('nav-account-v')), findsNothing);
    expect(find.byKey(const ValueKey('nav-account-s')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-account-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-header-mine')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-header-shared')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-new-account')), findsNothing);
    expect(find.byKey(const ValueKey('nav-manage-accounts')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('nav-account-s')));
    await tester.pumpAndSettle();
    expect(log.picked.single.id, 's');
  });

  testWidgets('no other editable accounts says so', (tester) async {
    await _pump(
      tester,
      const Size(390, 844),
      accounts: [testAccount('a', 'Everyday'), _all.last],
      exclude: 'a',
      editableOnly: true,
      actions: false,
    );
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    expect(find.text('No other accounts you can edit'), findsOneWidget);
  });
}
