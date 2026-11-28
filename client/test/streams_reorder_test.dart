// Home list mode: a drag handle on each stream row reorders within its
// section (mine / shared) and persists through the repository. Grid
// mode has no handles. Taps still open a stream; the ⋮ menu still works.
// Narrow and landscape list layouts must not overflow.
import 'package:budget_client/app.dart';
import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/streams/stream_home_layout.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth.dart';
import 'support/fake_streams.dart';

Future<ProviderContainer> _app(
  WidgetTester tester,
  FakeStreamRepository repo, {
  Size size = const Size(390, 844),
  String? layout = 'list',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  page.clearLocal();
  if (layout != null) writeStreamHomeLayout(layout);
  final c = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(user: adminUser),
      ),
      streamRepositoryProvider.overrideWithValue(repo),
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

double _top(WidgetTester tester, String id) =>
    tester.getTopLeft(find.byKey(ValueKey('stream-card-$id'))).dy;

Future<void> _dragRow(WidgetTester tester, String fromId, String ontoId) async {
  final from = tester.getCenter(find.byKey(ValueKey('stream-drag-$fromId')));
  final onto = tester.getCenter(find.byKey(ValueKey('stream-card-$ontoId')));
  await tester.timedDragFrom(
    from,
    Offset(0, onto.dy - from.dy),
    const Duration(milliseconds: 300),
  );
  await tester.pumpAndSettle();
}

void main() {
  final streams = [
    testStream('a1', 'Everyday'),
    testStream('a2', 'Savings'),
    testStream('a3', 'Holiday'),
    testStream('s1', 'Shared One', shared: true, role: Role.viewer),
    testStream('s2', 'Shared Two', shared: true, role: Role.editor),
  ];

  testWidgets('list mode shows a drag handle on every row; grid does not', (
    tester,
  ) async {
    final repo = FakeStreamRepository(streams: List.of(streams));
    await _app(tester, repo, layout: 'list');
    expect(find.byKey(const ValueKey('stream-drag-a1')), findsOneWidget);
    expect(find.byKey(const ValueKey('stream-drag-a2')), findsOneWidget);
    expect(find.byKey(const ValueKey('stream-drag-s1')), findsOneWidget);
    expect(find.byKey(const ValueKey('stream-drag-s2')), findsOneWidget);
    expect(find.byType(ReorderableDragStartListener), findsNWidgets(5));

    writeStreamHomeLayout('grid');
    await tester.tap(find.byKey(const ValueKey('streams-layout-toggle')).first);
    await tester.pumpAndSettle();
    expect(find.byType(ReorderableDragStartListener), findsNothing);
    expect(find.byKey(const ValueKey('stream-drag-a1')), findsNothing);
    expect(find.byKey(const ValueKey('stream-card-a1')), findsOneWidget);
  });

  testWidgets('dragging a mine row persists the new order, shared unchanged', (
    tester,
  ) async {
    final repo = FakeStreamRepository(streams: List.of(streams));
    await _app(tester, repo);
    expect(_top(tester, 'a1'), lessThan(_top(tester, 'a2')));
    expect(_top(tester, 'a2'), lessThan(_top(tester, 'a3')));

    await _dragRow(tester, 'a1', 'a2');

    expect(_top(tester, 'a2'), lessThan(_top(tester, 'a1')));
    expect(_top(tester, 'a1'), lessThan(_top(tester, 'a3')));
    expect(repo.reorders, isNotEmpty);
    expect(repo.reorders.last, ['a2', 'a1', 'a3', 's1', 's2']);
    // Shared section is still below, in its original relative order.
    expect(_top(tester, 'a3'), lessThan(_top(tester, 's1')));
    expect(_top(tester, 's1'), lessThan(_top(tester, 's2')));
  });

  testWidgets('a viewer can reorder shared streams in their list', (
    tester,
  ) async {
    final repo = FakeStreamRepository(streams: List.of(streams));
    await _app(tester, repo);

    await _dragRow(tester, 's1', 's2');

    expect(_top(tester, 's2'), lessThan(_top(tester, 's1')));
    expect(_top(tester, 'a3'), lessThan(_top(tester, 's2')));
    expect(repo.reorders.last, ['a1', 'a2', 'a3', 's2', 's1']);
  });

  testWidgets('tapping a row still opens it; the handle does not', (
    tester,
  ) async {
    final repo = FakeStreamRepository(streams: List.of(streams));
    final c = await _app(tester, repo);
    expect(_path(c), '/');

    await tester.tap(find.byKey(const ValueKey('stream-drag-a2')));
    await tester.pumpAndSettle();
    expect(_path(c), '/');

    await tester.tap(find.byKey(const ValueKey('stream-card-a2')));
    await tester.pumpAndSettle();
    expect(_path(c), '/streams/a2/timeline');
  });

  testWidgets('the stream actions menu still opens from a list row', (
    tester,
  ) async {
    final repo = FakeStreamRepository(streams: List.of(streams));
    await _app(tester, repo);
    await tester.tap(find.byKey(const ValueKey('stream-actions-a1')));
    await tester.pumpAndSettle();
    expect(find.text('Stream settings'), findsOneWidget);
    expect(find.text('Categories'), findsOneWidget);
  });

  testWidgets('list rows do not overflow at 320px or in landscape', (
    tester,
  ) async {
    for (final size in const [Size(320, 640), Size(844, 390)]) {
      final repo = FakeStreamRepository(
        streams: [
          testStream(
            'a1',
            'A very long stream name that must ellipsize on a narrow phone',
          ),
          testStream('a2', 'Savings'),
          testStream('s1', 'Shared One', shared: true, role: Role.viewer),
        ],
      );
      await _app(tester, repo, size: size, layout: 'list');
      expect(tester.takeException(), isNull, reason: '$size');
      expect(find.byKey(const ValueKey('stream-drag-a1')), findsOneWidget);
      expect(find.byKey(const ValueKey('stream-actions-a1')), findsOneWidget);
      final card = tester.getRect(find.byKey(const ValueKey('stream-card-a1')));
      expect(card.left, greaterThanOrEqualTo(-0.5), reason: '$size');
      expect(card.right, lessThanOrEqualTo(size.width + 0.5), reason: '$size');
    }
  });
}
