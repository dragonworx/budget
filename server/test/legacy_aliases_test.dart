// Deprecated /api/pools* and /api/transactions* aliases (old client builds
// after the Streams/Events rename) and the legacy import wrapper key.
import 'package:budget_server/api/legacy_aliases.dart';
import 'package:budget_server/domain/event_import.dart';
import 'package:test/test.dart';

import 'authz/harness.dart';

void main() {
  group('mapping', () {
    test('paths', () {
      expect(legacyPathToNew('/api/pools'), '/api/streams');
      expect(legacyPathToNew('/api/pools/p1'), '/api/streams/p1');
      expect(legacyPathToNew('/api/pools/p1/transactions'),
          '/api/streams/p1/events');
      expect(legacyPathToNew('/api/pools/p1/transactions/import/undo'),
          '/api/streams/p1/events/import/undo');
      expect(legacyPathToNew('/api/pools/p1/reorder-transactions'),
          '/api/streams/p1/reorder-events');
      expect(legacyPathToNew('/api/transactions/t1/overrides/2026-01-01'),
          '/api/events/t1/overrides/2026-01-01');
      expect(legacyPathToNew('/api/streams/p1'), isNull);
      expect(legacyPathToNew('/api/poolsx'), isNull);
      expect(legacyPathToNew('/api/events'), isNull);
    });

    test('keys both ways', () {
      expect(
          renameKeys({
            'poolId': 1,
            'transferToPoolId': 2,
            'transactions': [
              {'pool_id': 3, 'transactionId': 4}
            ],
            'name': 'pool party',
          }, legacyKeyToNew),
          {
            'streamId': 1,
            'transferToStreamId': 2,
            'events': [
              {'stream_id': 3, 'eventId': 4}
            ],
            'name': 'pool party', // values are never touched
          });
      expect(
          renameKeys({
            'streams': [
              {'eventOrder': [], 'lastStreamId': null}
            ]
          }, newKeyToLegacy),
          {
            'pools': [
              {'transactionOrder': [], 'lastPoolId': null}
            ]
          });
    });
  });

  test('import accepts the legacy {"transactions": [...]} wrapper', () {
    expect(decodeImportPayload('{"transactions":[{"name":"A"}]}'), [
      {'name': 'A'}
    ]);
    expect(decodeImportPayload('{"events":[{"name":"B"}]}'), [
      {'name': 'B'}
    ]);
  });

  group('routes', () {
    final h = Harness('legacyalias.authtest.example');
    setUpAll(() => h.open());
    tearDownAll(() => h.close());

    test('an old client keeps working through /api/pools*', () async {
      if (!h.ok) return markTestSkipped('no test DB');
      final created = await h.call('POST', '/api/pools',
          as: 'old', body: {'name': 'Legacy', 'seedDate': '2026-01-01'});
      expect(created.status, 201, reason: '${created.json}');
      expect(created.headers['deprecation'], 'true');
      final pool = created.json as Map<String, dynamic>;
      expect(pool.containsKey('transactionOrder'), isTrue);
      expect(
          pool.keys.where((k) => k.toLowerCase().contains('stream')), isEmpty);

      final list = await h.call('GET', '/api/pools', as: 'old');
      expect(list.status, 200);
      expect((list.json['pools'] as List).map((p) => p['id']),
          contains(pool['id']));

      final tx = await h.call('POST', '/api/pools/${pool['id']}/transactions',
          as: 'old', body: Harness.tx('Rent'));
      expect(tx.status, 201, reason: '${tx.json}');
      expect(tx.json['poolId'], pool['id']);

      final txs = await h.call('GET', '/api/pools/${pool['id']}/transactions',
          as: 'old');
      expect((txs.json['transactions'] as List).single['id'], tx.json['id']);

      final patched = await h.call(
          'PATCH', '/api/transactions/${tx.json['id']}',
          as: 'old', body: {'name': 'Rent 2', 'version': tx.json['version']});
      expect(patched.status, 200, reason: '${patched.json}');
      expect(patched.json['name'], 'Rent 2');

      final imported = await h.call('POST',
          '/api/pools/${pool['id']}/transactions/import?root=2026-02-01',
          as: 'old',
          body: {
            'transactions': [
              {
                'name': 'Bonus',
                'direction': 'credit',
                'amount': '5',
                'startOffset': 0,
                'recurrence': {'mode': 'once'}
              }
            ]
          });
      expect(imported.status, anyOf(200, 201), reason: '${imported.json}');
      expect(imported.json['created'], 1);

      // The new routes see the same data under the new names.
      final now =
          await h.call('GET', '/api/streams/${pool['id']}/events', as: 'old');
      expect((now.json['events'] as List).length, 2);
      expect(now.headers['deprecation'], isNull);

      final gone = await h.call('DELETE', '/api/transactions/${tx.json['id']}',
          as: 'old');
      expect(gone.status, anyOf(200, 204));
      expect(
          (await h.call('DELETE', '/api/pools/${pool['id']}', as: 'old'))
              .status,
          anyOf(200, 204));
    });

    test('legacy aliases still enforce access control', () async {
      if (!h.ok) return markTestSkipped('no test DB');
      final s = await h.seed('owner', 'Private');
      expect((await h.call('GET', '/api/pools/${s.a}', as: 'stranger')).status,
          404);
      expect(
          (await h.call('GET', '/api/transactions/${s.t}', as: 'stranger'))
              .status,
          404);
      expect((await h.call('GET', '/api/pools')).status, 401);
    });
  });
}
