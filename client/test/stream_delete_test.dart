// Deleting a stream: a stream with events confirms with a scrollable,
// grouped list and a choice for its transfers' far sides (keep there as
// plain rows, default; or delete, only when I can edit every other stream);
// an empty stream keeps the plain confirm. Afterwards nothing stale is left:
// the card goes, other streams' events / balances refetch, this
// browser forgets the stream's saved view and combine choices; another tab
// on the stream leaves it, and a deep link to a gone stream falls back home.
import 'package:budget_client/app.dart';
import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/realtime_service.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/streams/delete_stream_dialog.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/stream_cleanup.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/state/realtime_providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth.dart';
import 'support/fake_streams.dart';

import 'support/fake_categories.dart';

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
  recurrenceMode: RecurrenceMode.every,
  interval: 1,
  unit: RecurrenceUnit.months,
  endMode: EndMode.never,
  transfer: transfer,
);

class _Streams extends FakeStreamRepository {
  _Streams(List<BudgetStream> streams) : super(streams: streams);
  final deletes = <(String, StreamDeleteTransfers)>[];
  final balances = <String>[];
  @override
  Future<void> delete(
    String id, {
    StreamDeleteTransfers transfers = StreamDeleteTransfers.keep,
  }) async {
    deletes.add((id, transfers));
    streams.removeWhere((p) => p.id == id);
  }

  @override
  Future<BalanceSeries> balance(
    String streamId, {
    required DateTime from,
    required DateTime to,
  }) async {
    balances.add(streamId);
    return const BalanceSeries(points: []);
  }
}

class _Txs extends EventRepository {
  _Txs(this.byStream) : super(ApiClient());
  final Map<String, List<BudgetEvent>> byStream;
  final lists = <String>[];
  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async {
    lists.add(streamId);
    return byStream[streamId] ?? [];
  }
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

String _path(ProviderContainer c) =>
    c.read(routerProvider).routerDelegate.currentConfiguration.uri.path;

Future<void> _openDelete(WidgetTester tester, String streamId) async {
  final card = find.byKey(ValueKey('stream-card-$streamId'));
  await tester.tap(
    find.descendant(of: card, matching: find.byTooltip('Stream actions')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Delete stream').last);
  await tester.pumpAndSettle();
}

/// a1 (deleting) has 25 own rows, sends to b1 and receives from c1.
Map<String, List<BudgetEvent>> _world() => {
  'a1': [
    for (var i = 0; i < 25; i++) _tx('own$i', 'a1', 'Own $i'),
    _tx(
      'tx-out',
      'a1',
      'To savings',
      amount: 50,
      transfer: const TransferLink(
        id: 'x1',
        peerStreamId: 'b1',
        peerStreamName: 'Savings',
      ),
    ),
    _tx(
      'tx-in',
      'a1',
      'Pocket money',
      dir: EventDirection.credit,
      amount: 20,
      transfer: const TransferLink(
        id: 'x2',
        peerStreamId: 'c1',
        peerStreamName: 'Kids',
      ),
    ),
  ],
  'b1': [
    _tx(
      'peer-out',
      'b1',
      'To savings',
      dir: EventDirection.credit,
      amount: 50,
      transfer: const TransferLink(
        id: 'x1',
        peerStreamId: 'a1',
        peerStreamName: 'Everyday',
      ),
    ),
  ],
  'c1': [],
};

void main() {
  setUp(() {
    page.clearLocal();
    resetForgottenStreams();
  });

  group('dialog', () {
    Future<StreamDeleteTransfers?> Function() show(
      WidgetTester tester,
      List<BudgetStream> streams,
    ) {
      StreamDeleteTransfers? result;
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
                  result = await showDeleteStreamDialog(
                    context,
                    stream: streams.first,
                    events: _world()['a1']!,
                    streams: streams,
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
        'is disabled when I cannot edit another stream', (tester) async {
      await show(tester, [
        testStream('a1', 'Everyday'),
        testStream('b1', 'Savings'),
        testStream('c1', 'Kids', shared: true, role: Role.viewer),
      ])();
      expect(
        find.byKey(const ValueKey('stream-delete-dialog')),
        findsOneWidget,
      );
      expect(find.text('In this stream (deleted with it)'), findsOneWidget);
      expect(find.textContaining('and its 27 events'), findsOneWidget);
      // The list is bounded and scrolls to the transfers at the end.
      final list = find.byKey(const ValueKey('stream-delete-list'));
      expect(tester.getSize(list).height, lessThan(844 * 0.41));
      expect(
        find.byKey(const ValueKey('stream-delete-row-tx-in')),
        findsNothing,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('stream-delete-row-tx-in')),
        200,
        scrollable: find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('Transfers with other streams'), findsOneWidget);
      expect(find.text('To Savings · Monthly'), findsOneWidget);
      expect(find.text('From Kids · Monthly'), findsOneWidget);
      String amountIn(String id) => tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(ValueKey('stream-delete-row-$id')),
              matching: find.byType(Text),
            ),
          )
          .last
          .data!;
      expect(amountIn('tx-out'), startsWith('−'));
      expect(amountIn('tx-out'), contains('50'));
      expect(amountIn('tx-in'), startsWith('+'));
      expect(
        find.text('Keep in Savings and Kids as plain events'),
        findsOneWidget,
      );
      final remove = tester.widget<RadioListTile<StreamDeleteTransfers>>(
        find.byKey(const ValueKey('stream-delete-remove')),
      );
      expect(remove.enabled, isFalse);
      expect(find.textContaining("You can't edit Kids"), findsOneWidget);
      // Danger button.
      final confirm = tester.widget<FilledButton>(
        find.byKey(const ValueKey('stream-delete-confirm')),
      );
      final ctx = tester.element(
        find.byKey(const ValueKey('stream-delete-confirm')),
      );
      expect(
        confirm.style?.backgroundColor?.resolve({}),
        Theme.of(ctx).colorScheme.error,
      );
    });

    testWidgets('keep is the default; delete can be chosen; cancel is null', (
      tester,
    ) async {
      final streams = [
        testStream('a1', 'Everyday'),
        testStream('b1', 'Savings'),
        testStream('c1', 'Kids', shared: true, role: Role.editor),
      ];
      // Cancel.
      await show(tester, streams)();
      await tester.tap(find.byKey(const ValueKey('stream-delete-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stream-delete-dialog')), findsNothing);
      // Default keep.
      StreamDeleteTransfers? got;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => got = await showDeleteStreamDialog(
                context,
                stream: streams.first,
                events: _world()['a1']!,
                streams: streams,
              ),
              child: const Text('go2'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('stream-delete-confirm')));
      await tester.pumpAndSettle();
      expect(got, StreamDeleteTransfers.keep);
      await tester.tap(find.text('go2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('stream-delete-remove')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('stream-delete-confirm')));
      await tester.pumpAndSettle();
      expect(got, StreamDeleteTransfers.delete);
    });
  });

  group('streams home', () {
    testWidgets('an empty stream gets the plain confirm and is deleted', (
      tester,
    ) async {
      final streams = _Streams([
        testStream('a1', 'Everyday'),
        testStream('b1', 'S'),
      ]);
      final c = await _app(tester, streams, _Txs({}));
      c.read(routerProvider).go(streamsPath);
      await tester.pumpAndSettle();
      await _openDelete(tester, 'a1');
      expect(find.byKey(const ValueKey('stream-delete-dialog')), findsNothing);
      expect(find.textContaining('It has no events'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete stream'));
      await tester.pumpAndSettle();
      expect(streams.deletes, [('a1', StreamDeleteTransfers.keep)]);
      expect(find.byKey(const ValueKey('stream-card-a1')), findsNothing);
    });

    testWidgets('delete mode is sent; afterwards other streams refetch and '
        'this browser forgets the stream', (tester) async {
      final streams = _Streams([
        testStream('a1', 'Everyday'),
        testStream('b1', 'Savings'),
        testStream('c1', 'Kids'),
      ]);
      final txs = _Txs(_world());
      page.localSet('budget_view:${adminUser.id}:a1', '{}');
      page.localSet('budget_combine:${adminUser.id}:a1', '["b1"]');
      page.localSet('budget_combine:${adminUser.id}:b1', '["a1","c1"]');
      page.localSet('budget_view:${adminUser.id}:b1', '{}');
      final c = await _app(tester, streams, txs);
      c.read(routerProvider).go(streamsPath);
      await tester.pumpAndSettle();
      await c.read(eventsProvider('b1').future);
      final before = txs.lists.where((p) => p == 'b1').length;
      final balancesBefore = streams.balances.where((p) => p == 'b1').length;
      await _openDelete(tester, 'a1');
      expect(
        find.byKey(const ValueKey('stream-delete-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('stream-delete-remove')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('stream-delete-confirm')));
      await tester.pumpAndSettle();
      expect(streams.deletes, [('a1', StreamDeleteTransfers.delete)]);
      expect(find.byKey(const ValueKey('stream-card-a1')), findsNothing);
      expect(find.byKey(const ValueKey('stream-card-b1')), findsOneWidget);
      // Surviving streams' data is fetched again (their far sides changed).
      await c.read(eventsProvider('b1').future);
      expect(txs.lists.where((p) => p == 'b1').length, greaterThan(before));
      expect(
        streams.balances.where((p) => p == 'b1').length,
        greaterThan(balancesBefore),
      );
      expect(page.localGet('budget_view:${adminUser.id}:a1'), isNull);
      expect(page.localGet('budget_combine:${adminUser.id}:a1'), isNull);
      expect(page.localGet('budget_combine:${adminUser.id}:b1'), '["c1"]');
      expect(page.localGet('budget_view:${adminUser.id}:b1'), '{}');
      expect(c.read(streamsProvider).value!.map((p) => p.id), ['b1', 'c1']);
    });
  });

  testWidgets('another tab on the deleted stream leaves it; other streams '
      'refetch; its local choices go', (tester) async {
    final streams = _Streams([
      testStream('a1', 'Everyday'),
      testStream('b1', 'Sav'),
    ]);
    final txs = _Txs(_world());
    page.localSet('budget_view:${adminUser.id}:a1', '{}');
    final c = await _app(tester, streams, txs, size: const Size(1200, 900));
    c.read(routerProvider).go('/streams/a1/timeline');
    await tester.pumpAndSettle();
    await c.read(eventsProvider('b1').future);
    final before = txs.lists.where((p) => p == 'b1').length;
    streams.streams.removeWhere((p) => p.id == 'a1');
    c
        .read(realtimeControllerProvider)
        .handle(
          const ChangeEvent(id: 9, action: 'stream.deleted', streamId: 'a1'),
        );
    await tester.pumpAndSettle();
    expect(_path(c), streamsPath);
    expect(find.text('This stream was deleted'), findsOneWidget);
    expect(find.byKey(const ValueKey('stream-card-a1')), findsNothing);
    await c.read(eventsProvider('b1').future);
    expect(txs.lists.where((p) => p == 'b1').length, greaterThan(before));
    expect(page.localGet('budget_view:${adminUser.id}:a1'), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a deep link to a stream that is gone falls back to the streams '
      'home with a note', (tester) async {
    final streams = _Streams([testStream('b1', 'Savings')]);
    page.localSet('budget_view:${adminUser.id}:zz', '{}');
    final c = await _app(tester, streams, _Txs({}));
    c.read(routerProvider).go('/streams/zz/timeline');
    await tester.pumpAndSettle();
    expect(_path(c), streamsPath);
    expect(find.text('That stream no longer exists'), findsOneWidget);
    expect(page.localGet('budget_view:${adminUser.id}:zz'), isNull);
    expect(find.byKey(const ValueKey('stream-card-b1')), findsOneWidget);
  });
}
