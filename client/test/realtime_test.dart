import 'dart:async';
import 'dart:convert';

import 'package:budget_client/app.dart';
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/realtime_service.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/transactions/transaction_editor.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/state/realtime_providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/fake_auth.dart';

/// One SSE connection the test writes frames into.
class FakeConn {
  FakeConn(this.request, {this.status = 200});
  final http.BaseRequest request;
  final int status;
  final ctrl = StreamController<List<int>>();
  void send(String s) => ctrl.add(utf8.encode(s));
  void change(int id, Map<String, dynamic> e) =>
      send('event: change\nid: $id\ndata: ${jsonEncode({'id': id, ...e})}\n\n');
  void ready(int id) => send('event: ready\nid: $id\ndata: {"lastEventId":$id}\n\n');
  Future<void> close() => ctrl.close();
}

/// http.Client whose every send opens the next [FakeConn].
class FakeSse extends http.BaseClient {
  FakeSse(this.hub);
  final SseHub hub;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final c = FakeConn(request, status: hub.nextStatus ?? 200);
    hub.nextStatus = null;
    hub.conns.add(c);
    hub._opened.add(c);
    return http.StreamedResponse(c.ctrl.stream, c.status);
  }
}

class SseHub {
  final conns = <FakeConn>[];
  int? nextStatus;
  final _opened = StreamController<FakeConn>.broadcast();
  Future<FakeConn> next() => _opened.stream.first;
}

Future<void> _tick() => Future<void>.delayed(Duration.zero);

void main() {
  group('SseParser', () {
    test('frames across chunks, comments, CRLF, retry, multi-line data', () {
      final p = SseParser();
      expect(p.add('retry: 3000\n\n: ping\n\nevent: cha'), hasLength(1));
      final f = p.add('nge\r\nid: 5\r\ndata: {"a":\r\ndata: 1}\r\n\r\n');
      expect(f.single.event, 'change');
      expect(f.single.id, '5');
      expect(f.single.data, '{"a":\n1}');
    });
  });

  group('RealtimeService', () {
    late SseHub hub;
    late List<Duration> sleeps;
    late RealtimeService s;
    late List<ChangeEvent> got;
    late List<String> resyncs, goodbyes;
    var now = DateTime(2026, 10, 19, 12);

    setUp(() {
      hub = SseHub();
      sleeps = [];
      got = [];
      resyncs = [];
      goodbyes = [];
      now = DateTime(2026, 10, 19, 12);
      s = RealtimeService(
        clientFactory: () => FakeSse(hub),
        baseUrl: 'http://x',
        clientId: 'me-tab',
        sleep: (d) async => sleeps.add(d),
        now: () => now,
        onEvent: got.add,
        onResync: resyncs.add,
        onGoodbye: goodbyes.add,
      );
    });
    tearDown(() => s.stop());

    test('delivers changes, de-dupes, skips own echoes, tracks cursor', () async {
      final first = hub.next();
      s.start();
      final c = await first;
      expect(c.request.headers['X-Client-Id'], 'me-tab');
      c.send('retry: 3000\n\n');
      c.ready(10);
      await _tick();
      expect(s.status.value, RealtimeStatus.connected);
      c.change(11, {'action': 'transaction.updated', 'poolId': 'a1', 'clientId': 'other'});
      c.change(11, {'action': 'transaction.updated', 'poolId': 'a1'});
      c.change(12, {'action': 'pool.updated', 'clientId': 'me-tab'});
      await _tick();
      expect(got.map((e) => e.id), [11]);
      expect(s.lastEventId, 12);
    });

    test('reconnects with Last-Event-ID / since, honouring retry then backoff', () async {
      var opened = hub.next();
      s.start();
      final c1 = await opened;
      c1.send('retry: 3000\n\n');
      c1.ready(20);
      await _tick();
      opened = hub.next();
      await c1.close();
      final c2 = await opened;
      expect(sleeps.first, const Duration(seconds: 3));
      expect(c2.request.headers['Last-Event-ID'], '20');
      expect(c2.request.url.queryParameters['since'], '20');
      expect(s.status.value, RealtimeStatus.reconnecting);
      opened = hub.next();
      await c2.close(); // fails again before ready -> longer delay
      await opened;
      expect(sleeps[1], greaterThanOrEqualTo(const Duration(seconds: 6)));
    });

    test('goodbye stops for good and reports', () async {
      final opened = hub.next();
      s.start();
      final c = await opened;
      c.send('event: goodbye\ndata: {"reason":"session ended"}\n\n');
      await _tick();
      await _tick();
      expect(goodbyes, ['session ended']);
      expect(s.running, isFalse);
      expect(hub.conns, hasLength(1));
      expect(s.status.value, RealtimeStatus.offline);
    });

    test('401 is treated as goodbye', () async {
      hub.nextStatus = 401;
      s.start();
      await _tick();
      await _tick();
      expect(goodbyes, ['unauthorized']);
      expect(hub.conns, hasLength(1));
    });

    test('resync and error refresh everything and move the cursor', () async {
      final opened = hub.next();
      s.start();
      final c = await opened;
      c.send('event: resync\nid: 99\ndata: {"lastEventId":99,"reason":"too far behind"}\n\n');
      c.send('event: error\ndata: {"error":"boom"}\n\n');
      await _tick();
      expect(resyncs, ['too far behind', 'boom']);
      expect(s.lastEventId, 99);
    });

    test('reconnect event resumes promptly from the cursor', () async {
      var opened = hub.next();
      s.start();
      final c1 = await opened;
      c1.ready(5);
      await _tick();
      opened = hub.next();
      c1.send('retry: 1000\n\nevent: reconnect\ndata: {"reason":"shutdown","lastEventId":7}\n\n');
      final c2 = await opened;
      expect(sleeps.last, const Duration(seconds: 1));
      expect(c2.request.headers['Last-Event-ID'], '7');
    });

    test('a long disconnect triggers a full refresh on reconnect', () async {
      var opened = hub.next();
      s.start();
      final c1 = await opened;
      c1.ready(1);
      await _tick();
      opened = hub.next();
      await c1.close();
      final c2 = await opened;
      now = now.add(const Duration(minutes: 5));
      c2.ready(1);
      await _tick();
      expect(resyncs, ['long disconnect']);
    });
  });

  group('controller', () {
    testWidgets('events invalidate data; revocation navigates away', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final tx = _Txs();
      final c = ProviderContainer(overrides: [
        authRepositoryProvider.overrideWithValue(FakeAuthRepository(user: adminUser)),
        poolRepositoryProvider.overrideWithValue(_Pools()),
        transactionRepositoryProvider.overrideWithValue(tx),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const BudgetApp()));
      await tester.pumpAndSettle();
      await c.read(transactionsProvider('a1').future);
      expect(tx.lists, 1);
      final ctl = c.read(realtimeControllerProvider);
      ctl.handle(const ChangeEvent(id: 1, action: 'transaction.updated', poolId: 'a1', entityId: 't1'));
      await c.read(transactionsProvider('a1').future);
      expect(tx.lists, 2);
      expect(c.read(remoteChangesProvider)['t1']?.id, 1);

      c.read(routerProvider).go('/pools/a1/timeline');
      await tester.pumpAndSettle();
      // Someone else's share going away does not move me.
      ctl.handle(const ChangeEvent(
        id: 2,
        action: 'pool_share.revoked',
        poolId: 'a1',
        subjectUserId: 'u2',
      ));
      await tester.pumpAndSettle();
      expect(
        c.read(routerProvider).routerDelegate.currentConfiguration.uri.path,
        '/pools/a1/timeline',
      );
      ctl.handle(ChangeEvent(
        id: 3,
        action: 'pool_share.revoked',
        poolId: 'a1',
        subjectUserId: adminUser.id,
      ));
      await tester.pumpAndSettle();
      expect(
        c.read(routerProvider).routerDelegate.currentConfiguration.uri.path,
        poolsPath,
      );
      expect(find.text('You no longer have access to that pool'), findsOneWidget);
    });

    testWidgets('open editor shows "Updated by" instead of clobbering', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = ProviderContainer(overrides: [
        poolRepositoryProvider.overrideWithValue(_Pools()),
        transactionRepositoryProvider.overrideWithValue(_Txs()),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: TransactionEditor(poolId: 'a1', existing: _t, onDone: (_) {}),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('editor-name')), 'My edit');
      expect(find.byKey(const ValueKey('editor-remote-banner')), findsNothing);
      c.read(remoteChangesProvider.notifier).state = {
        't1': const ChangeEvent(id: 9, action: 'transaction.updated', entityId: 't1', actorId: 'u2'),
      };
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-remote-banner')), findsOneWidget);
      expect(find.textContaining('Updated by'), findsOneWidget);
      expect(find.text('My edit'), findsOneWidget);
    });
  });
}

final _t = Transaction(
  id: 't1',
  poolId: 'a1',
  name: 'Rent',
  direction: TransactionDirection.debit,
  amount: Decimal.fromInt(100),
  startDate: DateTime(2026, 10, 1),
  recurrenceMode: RecurrenceMode.once,
  endMode: EndMode.never,
  version: 1,
);

class _Pools extends PoolRepository {
  _Pools() : super(ApiClient());
  @override
  Future<PoolList> list() async => const PoolList([]);
  @override
  Future<Pool> get(String id) async => Pool(
    id: id,
    ownerId: 'u1',
    name: 'Everyday',
    seedBalance: Decimal.zero,
    seedDate: DateTime(2026, 10, 1),
    lossThreshold: Decimal.zero,
  );
}

class _Txs extends TransactionRepository {
  _Txs() : super(ApiClient());
  int lists = 0;
  @override
  Future<List<Transaction>> listForPool(String poolId) async {
    lists++;
    return [_t];
  }
}
