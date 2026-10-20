// Account selector (header + transfer): an anchored dropdown with project
// submenus. Touch taps open submenus, rows are touch-sized, menus stay on a
// 320–390px screen, Esc / outside tap dismiss, the keyboard works.
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/widgets/account_picker.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class _Projects extends ProjectRepository {
  _Projects(this.projects) : super(ApiClient());
  final List<Project> projects;
  @override
  Future<List<Project>> list() async => projects;
}

class _Accounts extends AccountRepository {
  _Accounts(this.accounts) : super(ApiClient());
  final Map<String, List<Account>> accounts;
  @override
  Future<List<Account>> listForProject(String projectId) async =>
      accounts[projectId]!;
}

final _two = [
  Project(
    id: 'p1',
    name: 'Household budget and bills',
    createdAt: DateTime(2026),
  ),
  Project(id: 'p2', name: 'Small business', createdAt: DateTime(2026)),
];
final _twoAccounts = {
  'p1': [
    _acct('a', 'p1', 'Everyday'),
    _acct('s', 'p1', 'Savings for a very long holiday abroad'),
  ],
  'p2': [_acct('b', 'p2', 'Operating')],
};

Future<List<Account>> _pump(
  WidgetTester tester,
  Size size, {
  List<Project>? projects,
  Map<String, List<Account>>? accounts,
  String? exclude,
  Alignment triggerAt = Alignment.topRight,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final picked = <Account>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        projectRepositoryProvider.overrideWithValue(
          _Projects(projects ?? _two),
        ),
        accountRepositoryProvider.overrideWithValue(
          _Accounts(accounts ?? _twoAccounts),
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
              onSelected: picked.add,
              builder: (context, open) =>
                  TextButton(onPressed: open, child: const Text('Jump')),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return picked;
}

void _expectOnScreen(WidgetTester tester, Finder f, Size size) {
  for (final e in f.evaluate()) {
    final r = tester.getRect(find.byWidget(e.widget));
    expect(r.left, greaterThanOrEqualTo(0), reason: '$r');
    expect(r.right, lessThanOrEqualTo(size.width), reason: '$r');
    expect(r.bottom, lessThanOrEqualTo(size.height), reason: '$r');
  }
}

void main() {
  for (final size in const [Size(320, 640), Size(390, 844)]) {
    final w = size.width.toInt();
    testWidgets('touch: tap opens the project submenu; rows are ≥44px; all '
        'on screen at ${w}px; selecting picks the account', (tester) async {
      final picked = await _pump(tester, size);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.touch);
      Future<void> touch(Finder f) async {
        await gesture.down(tester.getCenter(f));
        await gesture.up();
        await tester.pumpAndSettle();
      }

      await touch(find.text('Jump'));
      expect(find.byType(BottomSheet), findsNothing);
      // The current account's project starts expanded, in place.
      expect(find.byKey(const ValueKey('nav-account-a')), findsOneWidget);
      // Tap collapses / expands a project (touch: no hover needed).
      await touch(find.byKey(const ValueKey('nav-project-p1')));
      expect(find.byKey(const ValueKey('nav-account-a')), findsNothing);
      await touch(find.byKey(const ValueKey('nav-project-p1')));
      expect(find.byKey(const ValueKey('nav-account-a')), findsOneWidget);
      final p1 = tester.getRect(find.byKey(const ValueKey('nav-project-p1')));
      final a = tester.getRect(find.byKey(const ValueKey('nav-account-a')));
      expect(a.top, greaterThanOrEqualTo(p1.bottom - 1));
      for (final k in [
        'nav-project-p1',
        'nav-project-p2',
        'nav-account-a',
        'nav-account-s',
      ]) {
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
      // Expanding the other project shows its accounts (one open at a time).
      await touch(find.byKey(const ValueKey('nav-project-p2')));
      expect(find.byKey(const ValueKey('nav-account-a')), findsNothing);
      _expectOnScreen(tester, find.byType(MenuItemButton), size);
      await touch(find.byKey(const ValueKey('nav-account-b')));
      expect(picked.single.id, 'b');
      expect(find.byKey(const ValueKey('nav-project-p1')), findsNothing);
      await gesture.removePointer();
    });
  }

  testWidgets('a trigger at the left edge of a 320px screen keeps menus on '
      'screen too', (tester) async {
    const size = Size(320, 640);
    await _pump(tester, size, triggerAt: Alignment.topLeft);
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-project-p2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-account-b')), findsOneWidget);
    _expectOnScreen(tester, find.byType(MenuItemButton), size);
  });

  testWidgets('outside tap and Esc dismiss the menu', (tester) async {
    await _pump(tester, const Size(390, 844));
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-project-p1')), findsOneWidget);
    await tester.tapAt(const Offset(20, 800));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-project-p1')), findsNothing);

    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-project-p1')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-project-p1')), findsNothing);
  });

  testWidgets('desktop: submenus cascade to the side; keyboard picks an '
      'account', (tester) async {
    final picked = await _pump(
      tester,
      const Size(1200, 800),
      triggerAt: Alignment.topLeft,
    );
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    final row = tester.getRect(find.byKey(const ValueKey('nav-project-p2')));
    // Focus starts on the first project; down to the second.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final item = find.byKey(const ValueKey('nav-account-b'));
    expect(item, findsOneWidget);
    expect(tester.getRect(item).left, greaterThanOrEqualTo(row.right - 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked.single.id, 'b');
  });

  testWidgets('one project: its accounts are listed directly', (tester) async {
    final picked = await _pump(
      tester,
      const Size(390, 844),
      projects: [_two.first],
      accounts: {'p1': _twoAccounts['p1']!},
      exclude: 'a',
    );
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    expect(find.text('Projects:'), findsNothing);
    expect(find.byKey(const ValueKey('nav-project-p1')), findsNothing);
    // Excluded (e.g. a transfer's own account) is not offered.
    expect(find.byKey(const ValueKey('nav-account-a')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('nav-account-s')));
    await tester.pumpAndSettle();
    expect(picked.single.id, 's');
  });
}
