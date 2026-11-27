// DEV-17: Move to… on a Transactions row, confirmation, and the move call.
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/events/events_panel.dart';
import 'package:budget_client/widgets/stream_icon.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_categories.dart';

final _wages = BudgetStream(
  id: 'wages',
  ownerId: 'u1',
  name: 'Wages',
  seedBalance: Decimal.zero,
  seedDate: DateTime(2026, 1, 1),
  lossThreshold: Decimal.zero,
  color: '#3D6FD8',
  role: Role.owner,
);

final _savings = BudgetStream(
  id: 'savings',
  ownerId: 'u1',
  name: 'Savings',
  seedBalance: Decimal.zero,
  seedDate: DateTime(2026, 3, 1),
  lossThreshold: Decimal.zero,
  color: '#3C8A6E',
  role: Role.owner,
);

final _sharedView = BudgetStream(
  id: 'shared',
  ownerId: 'u2',
  name: 'Shared view-only',
  seedBalance: Decimal.zero,
  seedDate: DateTime(2026, 1, 1),
  lossThreshold: Decimal.zero,
  role: Role.viewer,
);

BudgetEvent _tx({
  String id = 'rent',
  String name = 'Rent',
  RecurrenceMode mode = RecurrenceMode.every,
  TransferLink? transfer,
}) => BudgetEvent(
  id: id,
  streamId: 'wages',
  name: name,
  direction: EventDirection.debit,
  amount: Decimal.fromInt(1100),
  startDate: DateTime(2026, 10, 15),
  recurrenceMode: mode,
  interval: mode == RecurrenceMode.every ? 2 : null,
  unit: mode == RecurrenceMode.every ? RecurrenceUnit.weeks : null,
  endMode: EndMode.never,
  transfer: transfer,
  version: 1,
);

class _StreamRepo extends StreamRepository {
  _StreamRepo(this.streams) : super(ApiClient());
  final List<BudgetStream> streams;
  @override
  Future<StreamList> list() async => StreamList(streams);
  @override
  Future<BudgetStream> get(String id) async =>
      streams.firstWhere((s) => s.id == id);
}

class _EventRepo extends EventRepository {
  _EventRepo(this.items) : super(ApiClient());
  List<BudgetEvent> items;
  final moves = <(String, String)>[];

  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async =>
      [for (final t in items) if (t.streamId == streamId) t];

  @override
  Future<BudgetEvent> move(String id, String streamId, {int? version}) async {
    moves.add((id, streamId));
    final i = items.indexWhere((t) => t.id == id);
    final moved = items[i].copyWith(streamId: streamId);
    items[i] = moved;
    return moved;
  }

  @override
  Future<void> delete(String id) async {
    items.removeWhere((t) => t.id == id);
  }
}

Future<(_EventRepo, List<(BudgetStream, BudgetEvent)>)> _pump(
  WidgetTester tester, {
  List<BudgetEvent>? items,
  Size size = const Size(412, 915),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repo = _EventRepo(items ?? [_tx()]);
  final moved = <(BudgetStream, BudgetEvent)>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        streamRepositoryProvider.overrideWithValue(
          _StreamRepo([_wages, _savings, _sharedView]),
        ),
        categoryRepositoryProvider.overrideWith(
          (ref) => FakeCategoryRepository(ref.watch(eventRepositoryProvider), [
            'Rent',
          ]),
        ),
        eventRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EventsPanel(
            stream: _wages,
            skipsFor: (_) => const {},
            onPanelClosed: (_) {},
            onChanged: () {},
            onMoved: (dest, event) => moved.add((dest, event)),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (repo, moved);
}

Finder _menu(String id) => find.byKey(ValueKey('row-menu-$id'));

void main() {
  testWidgets('Move to… lists editable streams, not the current or view-only', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(_menu('rent'));
    await tester.pumpAndSettle();
    final move = find.byKey(const ValueKey('row-move-rent'));
    expect(move, findsOneWidget);
    expect(find.text('Move to…'), findsOneWidget);
    await tester.tap(move);
    await tester.pumpAndSettle();
    expect(find.text('Savings'), findsOneWidget);
    expect(find.text('Wages'), findsNothing);
    expect(find.text('Shared view-only'), findsNothing);
    expect(find.byType(StreamIcon), findsWidgets);
  });

  testWidgets('Picking a stream confirms, moves the series, and jumps', (
    tester,
  ) async {
    final (repo, jumped) = await _pump(tester);
    await tester.tap(_menu('rent'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('row-move-rent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('row-move-to-rent-savings')));
    await tester.pumpAndSettle();
    expect(find.text('Move to Savings?'), findsOneWidget);
    expect(find.textContaining('whole series'), findsOneWidget);
    await tester.tap(find.text('Move'));
    await tester.pumpAndSettle();
    expect(repo.moves, [('rent', 'savings')]);
    expect(jumped, hasLength(1));
    expect(jumped.single.$1.id, 'savings');
    expect(find.text('Moved to Savings'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(repo.moves, [('rent', 'savings'), ('rent', 'wages')]);
  });

  testWidgets('A one-off confirmation does not mention a series', (
    tester,
  ) async {
    await _pump(tester, items: [_tx(mode: RecurrenceMode.once)]);
    await tester.tap(_menu('rent'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('row-move-rent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('row-move-to-rent-savings')));
    await tester.pumpAndSettle();
    expect(find.textContaining('whole series'), findsNothing);
    expect(find.textContaining('same date, amount, category and label'), findsOneWidget);
  });

  testWidgets('Move to… is disabled for a transfer', (tester) async {
    await _pump(
      tester,
      items: [
        _tx(
          id: 'xfer',
          name: 'To Mortgage',
          transfer: const TransferLink(peerStreamId: 'mortgage'),
        ),
      ],
    );
    await tester.tap(_menu('xfer'));
    await tester.pumpAndSettle();
    expect(find.text("Transfers can't be moved"), findsOneWidget);
    final item = tester.widget<MenuItemButton>(
      find.byKey(const ValueKey('row-move-xfer')),
    );
    expect(item.onPressed, isNull);
  });

  testWidgets('Desktop keeps a one-click delete icon and still has Move to…', (
    tester,
  ) async {
    await _pump(tester, size: const Size(1200, 800));
    expect(find.byKey(const ValueKey('row-delete-rent')), findsOneWidget);
    await tester.tap(_menu('rent'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text('Move to…'), findsOneWidget);
  });
}
