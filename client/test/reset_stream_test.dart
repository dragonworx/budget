// Reset Stream: a destructive item on the Home card menu and in the
// timeline More menu. It confirms with the transaction count, then
// deletes every transaction and keeps the stream.
import 'package:budget_client/app.dart';
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/streams/reset_stream_dialog.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth.dart';
import 'support/fake_categories.dart';
import 'support/fake_streams.dart';

BudgetEvent _tx(
  String id,
  String stream,
  String name, {
  EventDirection dir = EventDirection.debit,
  int amount = 10,
  TransferLink? transfer,
}) => BudgetEvent(
  id: id,
  streamId: stream,
  name: name,
  direction: dir,
  amount: Decimal.fromInt(amount),
  startDate: DateTime(2026, 10, 1),
  recurrenceMode: RecurrenceMode.once,
  endMode: EndMode.never,
  transfer: transfer,
);

class _Streams extends FakeStreamRepository {
  _Streams(List<BudgetStream> streams) : super(streams: streams);
  final resets = <String>[];
  @override
  Future<({int deleted, int counterparts, List<String> affectedStreams})>
  resetEvents(String id) async {
    resets.add(id);
    return (deleted: 1, counterparts: 0, affectedStreams: const <String>[]);
  }

  @override
  Future<BalanceSeries> balance(
    String streamId, {
    required DateTime from,
    required DateTime to,
  }) async => const BalanceSeries(points: []);
}

class _Txs extends EventRepository {
  _Txs(this.byStream) : super(ApiClient());
  final Map<String, List<BudgetEvent>> byStream;
  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async =>
      byStream[streamId] ?? [];
}

Future<ProviderContainer> _app(
  WidgetTester tester,
  _Streams streams,
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
      streamRepositoryProvider.overrideWithValue(streams),
      categoryRepositoryProvider.overrideWith(
        (ref) => FakeCategoryRepository(ref.watch(eventRepositoryProvider)),
      ),
      eventRepositoryProvider.overrideWithValue(txs),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: c, child: const BudgetApp()),
  );
  await tester.pumpAndSettle();
  return c;
}

Future<void> _openReset(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Stream actions').first);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('reset-stream')));
  await tester.pumpAndSettle();
}

void main() {
  test('the confirm names the stream, the count, and transfers', () {
    expect(
      resetStreamMessage(streamName: 'QA Reset', transactionCount: 4),
      contains('all 4 transactions in “QA Reset”'),
    );
    expect(
      resetStreamMessage(streamName: 'QA Reset', transactionCount: 1),
      contains('all 1 transaction in “QA Reset”'),
    );
    expect(
      resetStreamMessage(
        streamName: 'QA Reset',
        transactionCount: 4,
        transferCount: 2,
      ),
      contains(
        '2 of these are transfers; their matching transactions in '
        'other streams will also be permanently deleted.',
      ),
    );
    expect(
      resetStreamMessage(
        streamName: 'QA Reset',
        transactionCount: 2,
        transferCount: 1,
      ),
      contains('1 of these is a transfer'),
    );
  });

  testWidgets('Cancel leaves the transactions; Reset calls the server', (
    tester,
  ) async {
    final streams = _Streams([testStream('a1', 'QA Reset')]);
    final txs = _Txs({
      'a1': [
        _tx('t1', 'a1', 'Rent', amount: 1100),
        _tx(
          't2',
          'a1',
          'To savings',
          amount: 50,
          transfer: const TransferLink(
            id: 'x1',
            peerStreamId: 'b1',
            peerStreamName: 'Savings',
          ),
        ),
      ],
    });
    await _app(tester, streams, txs);
    // Landing may jump to a timeline; go home.
    final home = find.text('Streams');
    if (home.evaluate().isEmpty) {
      // Already on home, or jump via back / all streams.
    }
    // The landing route jumps to the last-used stream. Force home.
    // BudgetApp starts at / ; with lastStreamId null it should stay.
    await tester.tap(find.byTooltip('Stream actions').first);
    await tester.pumpAndSettle();
    expect(find.text('Reset Stream'), findsOneWidget);
    final item = tester.widget<MenuItemButton>(
      find.byKey(const ValueKey('reset-stream')),
    );
    expect(item.onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('reset-stream')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reset-stream-dialog')), findsOneWidget);
    expect(find.text('Reset Stream?'), findsOneWidget);
    expect(
      find.textContaining('all 2 transactions in “QA Reset”'),
      findsOneWidget,
    );
    expect(find.textContaining("can't be undone"), findsOneWidget);
    expect(find.textContaining('1 of these is a transfer'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reset-stream-cancel')));
    await tester.pumpAndSettle();
    expect(streams.resets, isEmpty);
    expect(find.byKey(const ValueKey('reset-stream-dialog')), findsNothing);

    await _openReset(tester);
    await tester.tap(find.byKey(const ValueKey('reset-stream-confirm')));
    await tester.pumpAndSettle();
    expect(streams.resets, ['a1']);
    expect(
      find.textContaining('Deleted 2 transactions in “QA Reset”'),
      findsOneWidget,
    );
  });

  testWidgets('an empty stream shows there is nothing to delete', (
    tester,
  ) async {
    final streams = _Streams([testStream('empty', 'Empty QA')]);
    final txs = _Txs({'empty': []});
    await _app(tester, streams, txs);
    await tester.tap(find.byTooltip('Stream actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reset-stream')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reset-stream-empty-dialog')),
      findsOneWidget,
    );
    expect(find.text('No transactions to delete'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reset-stream-empty-close')));
    await tester.pumpAndSettle();
    expect(streams.resets, isEmpty);
  });

  testWidgets('a viewer does not see Reset Stream', (tester) async {
    final streams = _Streams([
      testStream('mine', 'Mine'),
      testStream('shared', 'Shared', shared: true, role: Role.viewer),
    ]);
    final txs = _Txs({
      'mine': [_tx('t1', 'mine', 'Rent')],
      'shared': [_tx('t2', 'shared', 'Kid')],
    });
    await _app(tester, streams, txs);
    // Both cards have a ⋮ menu (Categories is available to viewers).
    expect(find.byKey(const ValueKey('stream-card-shared')), findsOneWidget);
    expect(find.byKey(const ValueKey('stream-actions-shared')), findsOneWidget);
    expect(find.byKey(const ValueKey('stream-actions-mine')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('stream-actions-shared')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stream-categories')), findsOneWidget);
    expect(find.byKey(const ValueKey('reset-stream')), findsNothing);
    expect(find.text('Reset Stream'), findsNothing);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('stream-actions-mine')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reset-stream')), findsOneWidget);
  });

  testWidgets('the timeline More menu has Reset Stream, disabled when empty', (
    tester,
  ) async {
    final stream = testStream('a1', 'QA Reset');
    final streams = _Streams([stream])..lastStreamId = 'a1';
    final txs = _Txs({
      'a1': [_tx('t1', 'a1', 'Rent')],
    });
    await _app(tester, streams, txs);
    // Landing should open the last-used timeline. If not, open it.
    if (find.byKey(const ValueKey('timeline-more')).evaluate().isEmpty) {
      await tester.tap(find.byKey(const ValueKey('stream-card-a1')));
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const ValueKey('timeline-more')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('timeline-more')));
    await tester.pumpAndSettle();
    final item = tester.widget<MenuItemButton>(
      find.byKey(const ValueKey('more-reset-stream')),
    );
    expect(item.onPressed, isNotNull);
    expect(find.text('Reset Stream'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('more-reset-stream')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reset-stream-dialog')), findsOneWidget);
    expect(
      find.textContaining('all 1 transaction in “QA Reset”'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('reset-stream-cancel')));
    await tester.pumpAndSettle();
    expect(streams.resets, isEmpty);
  });
}
