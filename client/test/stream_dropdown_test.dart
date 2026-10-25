// Stream selector (header + transfer): an anchored dropdown with a flat list
// of my streams (current checked), a "Shared with me" section, then the
// New stream action (no Manage streams: the back arrow leads home). No submenus. Rows are touch-sized,
// the menu stays on a 320–390px screen, Esc / outside tap dismiss, and the
// keyboard works.
import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/data/models.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/widgets/stream_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:budget_client/widgets/stream_icon.dart';

import 'support/fake_streams.dart';

final _all = [
  testStream('a', 'Everyday'),
  testStream('s', 'Savings for a very long holiday abroad and more'),
  testStream(
    'b',
    'Joint bills',
    shared: true,
    role: Role.editor,
    ownerName: 'Sam',
  ),
  testStream('v', 'Kids', shared: true, role: Role.viewer, ownerName: 'Sam'),
];

class _Log {
  final picked = <BudgetStream>[];
  int created = 0;
}

Future<_Log> _pump(
  WidgetTester tester,
  Size size, {
  List<BudgetStream>? streams,
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
        streamRepositoryProvider.overrideWithValue(
          FakeStreamRepository(streams: List.of(streams ?? _all)),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: triggerAt,
            child: StreamPicker(
              keyPrefix: 'nav',
              currentStreamId: 'a',
              excludeStreamId: exclude,
              editableOnly: editableOnly,
              onSelected: log.picked.add,
              onNewStream: actions ? () => log.created++ : null,
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
        'all on screen; selecting picks the stream', (tester) async {
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
      // Order: My streams, mine, Shared with me, shared, actions.
      final order = [
        'nav-header-mine',
        'nav-stream-a',
        'nav-stream-s',
        'nav-header-shared',
        'nav-stream-b',
        'nav-stream-v',
        'nav-new-stream',
      ];
      // Manage streams was removed (the timeline's back arrow leads home).
      expect(find.byKey(const ValueKey('nav-manage-streams')), findsNothing);
      expect(find.text('Manage streams'), findsNothing);
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
      // The current stream is checked, the others are not.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('nav-stream-a')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      // Every other stream row leads with the bucket stream icon at 18px.
      for (final k in ['nav-stream-s', 'nav-stream-b', 'nav-stream-v']) {
        final icon = find.descendant(
          of: find.byKey(ValueKey(k)),
          matching: find.byType(StreamIcon),
        );
        expect(icon, findsOneWidget, reason: k);
        expect(tester.getSize(icon), const Size(18, 18), reason: k);
      }
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('nav-stream-a')),
          matching: find.byType(StreamIcon),
        ),
        findsNothing,
      );
      expect(find.byIcon(Icons.account_balance_wallet_outlined), findsNothing);
      // Shared rows carry the people icon (my role in the tooltip).
      expect(find.byKey(const ValueKey('shared-indicator-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('shared-indicator-a')), findsNothing);
      await touch(find.byKey(const ValueKey('nav-stream-b')));
      expect(log.picked.single.id, 'b');
      expect(find.byKey(const ValueKey('nav-stream-a')), findsNothing);
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
    await tester.tap(find.byKey(const ValueKey('nav-new-stream')));
    await tester.pumpAndSettle();
    expect(log.created, 1);
  });

  testWidgets('outside tap and Esc dismiss the menu', (tester) async {
    await _pump(tester, const Size(390, 844));
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-stream-a')), findsOneWidget);
    await tester.tapAt(const Offset(20, 800));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-stream-a')), findsNothing);

    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-stream-a')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-stream-a')), findsNothing);
  });

  testWidgets('desktop keyboard: focus starts on the first stream; arrows '
      'skip headers; Enter picks a shared stream', (tester) async {
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

  testWidgets('desktop keyboard reaches New stream', (tester) async {
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

  testWidgets('touch: tapping New stream primes the soft keyboard on the '
      'release (inside the tap), then runs New stream', (tester) async {
    final log = await _pump(tester, const Size(390, 844));
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    final before = page.primeSoftKeyboardCalls;
    await tester.tap(
      find.byKey(const ValueKey('nav-new-stream')),
      kind: PointerDeviceKind.touch,
    );
    await tester.pumpAndSettle();
    expect(page.primeSoftKeyboardCalls, before + 1);
    expect(log.created, 1);
  });

  testWidgets('transfer picker: only streams I can edit, never the source, '
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
    expect(find.byKey(const ValueKey('nav-stream-a')), findsNothing);
    expect(find.byKey(const ValueKey('nav-stream-v')), findsNothing);
    expect(find.byKey(const ValueKey('nav-stream-s')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-stream-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-header-mine')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-header-shared')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-new-stream')), findsNothing);
    expect(find.byKey(const ValueKey('nav-manage-streams')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('nav-stream-s')));
    await tester.pumpAndSettle();
    expect(log.picked.single.id, 's');
  });

  testWidgets('no other editable streams says so', (tester) async {
    await _pump(
      tester,
      const Size(390, 844),
      streams: [testStream('a', 'Everyday'), _all.last],
      exclude: 'a',
      editableOnly: true,
      actions: false,
    );
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    expect(find.text('No other streams you can edit'), findsOneWidget);
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
    expect(ring(tester, 'nav-stream-a'), BorderSide.none);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(ring(tester, 'nav-stream-s').width, 2);
    expect(ring(tester, 'nav-stream-a'), BorderSide.none);
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
    expect(ring(tester, 'nav-stream-a'), BorderSide.none);
  });

  testWidgets('opened with the keyboard: the focused first row shows the '
      'ring', (tester) async {
    await _pump(tester, const Size(1200, 800), triggerAt: Alignment.topLeft);
    // Tab to the trigger, Enter opens.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-stream-a')), findsOneWidget);
    expect(ring(tester, 'nav-stream-a').width, 2);
  });
}
