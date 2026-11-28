import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'harness.dart';

// Reset Stream: DELETE /api/streams/:id/events removes every event in the
// stream (and each transfer's far side in other streams, the same as
// deleting those events one by one). The stream, its seed, settings and
// colour stay. Editor or owner; viewers are 403.
void main() {
  final h = Harness('streamreset.authtest.example');
  setUpAll(() => h.open());
  tearDownAll(() => h.close());

  Future<String> stream(String who, String name,
      {String seed = '1000', String? color, String threshold = '0'}) async {
    final r = await h.call('POST', '/api/streams', as: who, body: {
      'name': name,
      'seedDate': '2026-10-01',
      'seedBalance': seed,
      'lossThreshold': threshold,
      if (color != null) 'color': color,
    });
    expect(r.status, 201, reason: '${r.json}');
    return r.json['id'] as String;
  }

  Future<Map<String, dynamic>> tx(String who, String streamId, String name,
      {String dir = 'debit',
      String amount = '10',
      String? to,
      bool monthly = false}) async {
    final r =
        await h.call('POST', '/api/streams/$streamId/events', as: who, body: {
      'name': name,
      'direction': dir,
      'amount': amount,
      'startDate': '2026-10-05',
      'recurrenceMode': monthly ? 'every' : 'once',
      if (monthly) 'interval': 1,
      if (monthly) 'unit': 'months',
      'endMode': 'never',
      if (to != null) 'transferToStreamId': to,
    });
    expect(r.status, 201, reason: '${r.json}');
    return r.json as Map<String, dynamic>;
  }

  Future<List<dynamic>> txs(String who, String streamId) async =>
      (await h.call('GET', '/api/streams/$streamId/events', as: who))
          .json['events'] as List;

  test('deletes every transaction and keeps the stream, seed and colour',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final a = await stream('own', 'Reset Keep',
        seed: '2500.50', color: '#3D5A80', threshold: '100');
    await tx('own', a, 'Rent', amount: '80');
    await tx('own', a, 'Pay', dir: 'credit', amount: '200');
    final r = await h.call('DELETE', '/api/streams/$a/events', as: 'own');
    expect(r.status, 200, reason: '${r.json}');
    expect(r.json['deleted'], 2);
    expect(r.json['counterparts'], 0);
    expect(r.json['affectedStreams'], isEmpty);
    expect((await txs('own', a)), isEmpty);
    final kept = await h.call('GET', '/api/streams/$a', as: 'own');
    expect(kept.status, 200, reason: '${kept.json}');
    expect(kept.json['name'], 'Reset Keep');
    expect(kept.json['seedBalance'], '2500.5');
    expect(kept.json['lossThreshold'], '100');
    expect(kept.json['color'], '#3D5A80');
    expect(kept.json['seedDate'], '2026-10-01');
    expect(kept.json['eventOrder'], isEmpty);
    expect(kept.json['hasLoan'], isFalse);
    final ev = await h.conn!.execute(
        Sql.named('SELECT action FROM audit_log WHERE stream_id = @a::uuid '
            'ORDER BY id DESC LIMIT 1'),
        parameters: {'a': a});
    expect(ev.first[0], 'events.reset');
  });

  test('deletes transfer counterparts in other streams', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final a = await stream('own2', 'Reset A');
    final b = await stream('own2', 'Reset B');
    await tx('own2', a, 'Own row');
    final ab = await tx('own2', a, 'A to B', amount: '100', to: b);
    final ba =
        await tx('own2', b, 'Rent from B', amount: '50', to: a, monthly: true);
    final skip = await h.call(
        'PUT', '/api/events/${ba['id']}/skips/2026-11-05',
        as: 'own2', body: {'skipped': true});
    expect(skip.status, lessThan(300), reason: '${skip.json}');
    final plain = await tx('own2', b, 'B own');
    final peerAb = ab['transfer']['peerEventId'] as String;
    final r = await h.call('DELETE', '/api/streams/$a/events', as: 'own2');
    expect(r.status, 200, reason: '${r.json}');
    expect(r.json['deleted'], 3); // Own row, A to B, and B's transfer peer
    expect(r.json['counterparts'], 2); // B's A-to-B credit + B's Rent-from-B
    expect(r.json['affectedStreams'], [b]);
    expect((await txs('own2', a)), isEmpty);
    final left = await txs('own2', b);
    expect(left.map((t) => t['id']), [plain['id']]);
    final order = (await h.call('GET', '/api/streams/$b', as: 'own2'))
        .json['eventOrder'] as List;
    expect(order, isNot(contains(peerAb)));
    expect(order, isNot(contains(ba['id'])));
    expect(order, contains(plain['id']));
    final ev = await h.conn!.execute(
        Sql.named('SELECT action FROM audit_log WHERE stream_id = @b::uuid '
            'ORDER BY id DESC LIMIT 1'),
        parameters: {'b': b});
    expect(ev.first[0], 'events.reset');
    // Skips on a deleted counterpart are gone.
    final skips = await h.conn!.execute(
        Sql.named('SELECT 1 FROM skipped_occurrences '
            'WHERE event_id = @t::uuid'),
        parameters: {'t': ba['id']});
    expect(skips, isEmpty);
    // A itself is still there.
    expect((await h.call('GET', '/api/streams/$a', as: 'own2')).status, 200);
  });

  test('an empty stream is a no-op; the stream stays', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final a = await stream('own3', 'Empty reset');
    final r = await h.call('DELETE', '/api/streams/$a/events', as: 'own3');
    expect(r.status, 200, reason: '${r.json}');
    expect(r.json['deleted'], 0);
    expect(r.json['counterparts'], 0);
    expect((await h.call('GET', '/api/streams/$a', as: 'own3')).status, 200);
  });

  test('editor can reset; viewer, outsider and anonymous cannot', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final a = await stream('boss', 'Shared reset');
    await tx('boss', a, 'Keep me?');
    await h.login('ed');
    await h.login('view');
    await h.login('out');
    await h.call('POST', '/api/streams/$a/invites',
        as: 'boss', body: {'email': h.email('ed'), 'role': 'editor'});
    await h.call('POST', '/api/streams/$a/invites',
        as: 'boss', body: {'email': h.email('view'), 'role': 'viewer'});
    expect((await h.call('DELETE', '/api/streams/$a/events')).status, 401);
    expect((await h.call('DELETE', '/api/streams/$a/events', as: 'out')).status,
        404);
    expect(
        (await h.call('DELETE', '/api/streams/$a/events', as: 'view')).status,
        403);
    // Rolled back: the event is still there.
    expect((await txs('boss', a)).map((t) => t['name']), ['Keep me?']);
    final ok = await h.call('DELETE', '/api/streams/$a/events', as: 'ed');
    expect(ok.status, 200, reason: '${ok.json}');
    expect(ok.json['deleted'], 1);
    expect((await txs('boss', a)), isEmpty);
    expect((await h.call('GET', '/api/streams/$a', as: 'boss')).status, 200);
  });
}
