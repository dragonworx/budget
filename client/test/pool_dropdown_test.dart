// Pool selector (header + transfer): an anchored dropdown with a flat list
// of my pools (current checked), a "Shared with me" section, then the
// New pool / Manage pools actions. No submenus. Rows are touch-sized,
// the menu stays on a 320–390px screen, Esc / outside tap dismiss, and the
// keyboard works.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/widgets/pool_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_pools.dart';

final _all = [
  testPool('a', 'Everyday'),
  testPool('s', 'Savings for a very long holiday abroad and more'),
  testPool('b', 'Joint bills', shared: true, role: Role.editor, ownerName: 'Sam'),
  testPool('v', 'Kids', shared: true, role: Role.viewer, ownerName: 'Sam'),
];

class _Log {
  final picked = <Pool>[];
  int created = 0;
  int managed = 0;
}

Future<_Log> _pump(
  WidgetTester tester,
  Size size, {
  List<Pool>? pools,
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
        poolRepositoryProvider.overrideWithValue(
          FakePoolRepository(pools: List.of(pools ?? _all)),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: triggerAt,
            child: PoolPicker(
              keyPrefix: 'nav',
              currentPoolId: 'a',
              excludePoolId: exclude,
              editableOnly: editableOnly,
              onSelected: log.picked.add,
              onNewPool: actions ? () => log.created++ : null,
              onManagePools: actions ? () => log.managed++ : null,
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
        'all on screen; selecting picks the pool', (tester) async {
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
      // Order: My pools, mine, Shared with me, shared, actions.
      final order = [
        'nav-header-mine',
        'nav-pool-a',
        'nav-pool-s',
        'nav-header-shared',
        'nav-pool-b',
        'nav-pool-v',
        'nav-new-pool',
        'nav-manage-pools',
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
      // The current pool is checked, the others are not.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('nav-pool-a')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      // Shared rows carry the people icon (my role in the tooltip).
      expect(find.byKey(const ValueKey('shared-indicator-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('shared-indicator-a')), findsNothing);
      await touch(find.byKey(const ValueKey('nav-pool-b')));
      expect(log.picked.single.id, 'b');
      expect(find.byKey(const ValueKey('nav-pool-a')), findsNothing);
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
    await tester.tap(find.byKey(const ValueKey('nav-new-pool')));
    await tester.pumpAndSettle();
    expect(log.created, 1);
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-manage-pools')));
    await tester.pumpAndSettle();
    expect(log.managed, 1);
  });

  testWidgets('outside tap and Esc dismiss the menu', (tester) async {
    await _pump(tester, const Size(390, 844));
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-pool-a')), findsOneWidget);
    await tester.tapAt(const Offset(20, 800));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-pool-a')), findsNothing);

    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-pool-a')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-pool-a')), findsNothing);
  });

  testWidgets('desktop keyboard: focus starts on the first pool; arrows '
      'skip headers; Enter picks a shared pool', (tester) async {
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

  testWidgets('desktop keyboard reaches New pool', (tester) async {
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

  testWidgets('transfer picker: only pools I can edit, never the source, '
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
    expect(find.byKey(const ValueKey('nav-pool-a')), findsNothing);
    expect(find.byKey(const ValueKey('nav-pool-v')), findsNothing);
    expect(find.byKey(const ValueKey('nav-pool-s')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-pool-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-header-mine')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-header-shared')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-new-pool')), findsNothing);
    expect(find.byKey(const ValueKey('nav-manage-pools')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('nav-pool-s')));
    await tester.pumpAndSettle();
    expect(log.picked.single.id, 's');
  });

  testWidgets('no other editable pools says so', (tester) async {
    await _pump(
      tester,
      const Size(390, 844),
      pools: [testPool('a', 'Everyday'), _all.last],
      exclude: 'a',
      editableOnly: true,
      actions: false,
    );
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    expect(find.text('No other pools you can edit'), findsOneWidget);
  });

  BorderSide ring(WidgetTester tester, String key) {
    final m = tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(Material),
          )
          .first,
    );
    return (m.shape! as OutlinedBorder).side;
  }

  testWidgets('opened by touch or mouse: first row focused but no outline; '
      'a key press brings the ring back', (tester) async {
    await _pump(tester, const Size(390, 844));
    await tester.tap(find.text('Jump')); // touch
    await tester.pumpAndSettle();
    expect(ring(tester, 'nav-pool-a'), BorderSide.none);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(ring(tester, 'nav-pool-s').width, 2);
    expect(ring(tester, 'nav-pool-a'), BorderSide.none);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Jump')));
    await mouse.down(tester.getCenter(find.text('Jump')));
    await mouse.up();
    await tester.pumpAndSettle();
    await mouse.moveTo(const Offset(5, 830)); // off the menu
    await tester.pumpAndSettle();
    expect(ring(tester, 'nav-pool-a'), BorderSide.none);
  });

  testWidgets('opened with the keyboard: the focused first row shows the '
      'ring', (tester) async {
    await _pump(tester, const Size(1200, 800), triggerAt: Alignment.topLeft);
    // Tab to the trigger, Enter opens.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-pool-a')), findsOneWidget);
    expect(ring(tester, 'nav-pool-a').width, 2);
  });
}
