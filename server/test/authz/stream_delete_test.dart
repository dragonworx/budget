import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'harness.dart';

// Deleting a stream with transfers: the far side in other streams is kept as a
// plain event (default) or deleted; never left pointing at a missing
// stream. One request = one DB transaction.
void main() {
  final h = Harness('streamdelete.authtest.example');
  setUpAll(() => h.open());
  tearDownAll(() => h.close());

  Future<String> stream(String who, String name) async {
    final r = await h.call('POST', '/api/streams',
        as: who,
        body: {'name': name, 'seedDate': '2026-10-01', 'seedBalance': '1000'});
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

  Future<List<dynamic>> balance(String who, String streamId) async =>
      (await h.call('GET',
              '/api/streams/$streamId/balance?from=2026-10-01&to=2027-03-31',
              as: who))
          .json['points'] as List;

  /// Stream A (deleted) with an own row, A→B (A debit, B credit) and B→A
  /// (B debit, monthly, one skipped date). Returns (a, b, ids in B).
  Future<(String, String, String, String)> setup(String who, String tag) async {
    final a = await stream(who, 'Del A $tag');
    final b = await stream(who, 'Keep B $tag');
    await tx(who, a, 'Own row');
    final ab = await tx(who, a, 'A to B', amount: '100', to: b);
    final ba =
        await tx(who, b, 'Rent from B', amount: '50', to: a, monthly: true);
    final skip = await h.call('PUT', '/api/events/${ba['id']}/skips/2026-11-05',
        as: who, body: {'skipped': true});
    expect(skip.status, lessThan(300), reason: '${skip.json}');
    return (a, b, ab['transfer']['peerEventId'] as String, ba['id'] as String);
  }

  test('keep (default): the far sides become plain rows; balance unchanged',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final (a, b, abPeer, ba) = await setup('own', 'keep');
    final before = await balance('own', b);
    // A saved view of A (removed with it).
    await h.call('PUT', '/api/streams/$a/view',
        as: 'own', body: {'start': 20741, 'days': 30});
    final r = await h.call('DELETE', '/api/streams/$a', as: 'own');
    expect(r.status, 200, reason: '${r.json}');
    expect(r.json['transfers'], 'keep');
    expect(r.json['converted'], 2);
    expect(r.json['affectedStreams'], [b]);
    expect((await h.call('GET', '/api/streams/$a', as: 'own')).status, 404);
    final left = await txs('own', b);
    expect(left.map((t) => t['id']), unorderedEquals([abPeer, ba]));
    for (final t in left) {
      expect(t['transfer'], isNull, reason: 'no link to the deleted stream');
    }
    final credit = left.firstWhere((t) => t['id'] == abPeer);
    expect(credit['direction'], 'credit');
    expect(credit['name'], 'A to B');
    expect(credit['amount'], '100');
    final rent = left.firstWhere((t) => t['id'] == ba);
    expect(rent['direction'], 'debit');
    expect(rent['recurrenceMode'], 'every');
    expect(rent['name'], 'Rent from B');
    expect(await balance('own', b), before);
    final c = h.conn!;
    final skips = await c.execute(
        Sql.named('SELECT date::text FROM skipped_occurrences '
            'WHERE event_id = @t::uuid'),
        parameters: {'t': ba});
    expect(skips.map((r) => r[0]), ['2026-11-05']);
    expect(
        (await c.execute(
                Sql.named(
                    'SELECT 1 FROM stream_views WHERE stream_id = @a::uuid'),
                parameters: {'a': a}))
            .isEmpty,
        isTrue);
    expect(
        (await c.execute(
                Sql.named('SELECT count(*) FROM events '
                    'WHERE stream_id = @a::uuid'),
                parameters: {'a': a}))
            .first[0],
        0);
    // B's viewers hear about it (real-time).
    final ev = await c.execute(
        Sql.named('SELECT action FROM audit_log WHERE stream_id = @b::uuid '
            'ORDER BY id DESC LIMIT 1'),
        parameters: {'b': b});
    expect(ev.first[0], 'events.transfers_unlinked');
  });

  test('delete: the far sides are removed (and from the order)', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final (a, b, abPeer, ba) = await setup('own2', 'del');
    final plain = await tx('own2', b, 'B own');
    final r =
        await h.call('DELETE', '/api/streams/$a?transfers=delete', as: 'own2');
    expect(r.status, 200, reason: '${r.json}');
    expect(r.json['removed'], 2);
    final left = await txs('own2', b);
    expect(left.map((t) => t['id']), [plain['id']]);
    final order = (await h.call('GET', '/api/streams/$b', as: 'own2'))
        .json['eventOrder'] as List;
    expect(order, isNot(contains(abPeer)));
    expect(order, isNot(contains(ba)));
    final ev = await h.conn!.execute(
        Sql.named('SELECT action FROM audit_log WHERE stream_id = @b::uuid '
            'ORDER BY id DESC LIMIT 1'),
        parameters: {'b': b});
    expect(ev.first[0], 'events.transfers_deleted');
  });

  test('a stream with only its own events; unknown mode is 400', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final a = await stream('own3', 'Solo');
    await tx('own3', a, 'Only');
    expect(
        (await h.call('DELETE', '/api/streams/$a?transfers=nope', as: 'own3'))
            .status,
        400);
    expect((await h.call('GET', '/api/streams/$a', as: 'own3')).status, 200);
    final r = await h.call('DELETE', '/api/streams/$a', as: 'own3');
    expect(r.status, 200);
    expect(r.json['converted'], 0);
    expect(r.json['affectedStreams'], isEmpty);
    expect((await h.call('GET', '/api/streams/$a', as: 'own3')).status, 404);
  });

  test('delete mode needs editor on every other stream; keep never does',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    // "boss" owns B and shares it with "me" as editor; I transfer from my
    // stream A to B, then boss drops me to viewer.
    await h.login('me');
    final b = await stream('boss', 'Boss B');
    final inv = await h.call('POST', '/api/streams/$b/invites',
        as: 'boss', body: {'email': h.email('me'), 'role': 'editor'});
    expect(inv.status, 201, reason: '${inv.json}');
    final a = await stream('me', 'My A');
    final t = await tx('me', a, 'To boss', amount: '25', to: b);
    final peer = t['transfer']['peerEventId'] as String;
    final meId = await h.userId('me');
    final down = await h.call('PATCH', '/api/streams/$b/shares/$meId',
        as: 'boss', body: {'role': 'viewer'});
    expect(down.status, lessThan(300), reason: '${down.json}');
    final no =
        await h.call('DELETE', '/api/streams/$a?transfers=delete', as: 'me');
    expect(no.status, 403);
    expect(no.json['details']['streams'], [b]);
    // Rolled back: nothing changed.
    expect((await h.call('GET', '/api/streams/$a', as: 'me')).status, 200);
    expect((await txs('boss', b)).single['transfer'], isNotNull);
    // Keep: boss's row stays (a plain credit), so boss's balance is intact.
    final ok = await h.call('DELETE', '/api/streams/$a', as: 'me');
    expect(ok.status, 200, reason: '${ok.json}');
    final kept = (await txs('boss', b)).single;
    expect(kept['id'], peer);
    expect(kept['transfer'], isNull);
    expect(kept['direction'], 'credit');
  });
}
