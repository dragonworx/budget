// Sync events over the API (spec 015), DB-backed through the full router
// (TEST_DATABASE_URL, default local budget_test; skipped without
// Postgres): create / patch validation, the forced "Sync" category,
// unsupported operations, formulas and variable re-resolution with a
// negative result, import + undo, trim + undo, the `syncs` key, /project
// rank inheritance (S12) and the planner's pin notice.
import 'dart:convert';

import 'package:test/test.dart';

import 'authz/harness.dart';

void main() {
  final h = Harness('syncroutes.authtest.example');
  setUpAll(() => h.open());
  tearDownAll(() => h.close());

  test('sync create, patch and unsupported operations', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('owner', 'Sync');
    final other = await h.seed('owner', 'Other');
    final events = '/api/streams/${s.a}/events';
    Map<String, Object?> body([Map<String, Object?> extra = const {}]) => {
          'kind': 'sync',
          'amount': '-1234.56',
          'startDate': '2026-01-05',
          ...extra
        };

    for (final (b, msg) in [
      (body({'direction': 'debit'}), 'Not available for a sync'),
      (body({'transferToStreamId': other.a}), 'Not available for a sync'),
      (
        body({'recurrenceMode': 'every', 'interval': 1, 'unit': 'weeks'}),
        'Not available for a sync'
      ),
      (
        body({
          'frequency': {'rule': 'weekly', 'interval': 1}
        }),
        'Not available for a sync'
      ),
      (
        body({'endMode': 'count', 'occurrenceCount': 2}),
        'Not available for a sync'
      ),
      (
        body({
          'skippedDates': ['2026-01-05']
        }),
        'Not available for a sync'
      ),
      (body({'loan': <String, Object?>{}}), 'Not available for a sync'),
      (
        body({'startDate': '2025-12-31'}),
        "A sync must be on or after the stream's start date (1 Jan 2026)"
      ),
      (
        {'kind': 'sync', 'startDate': '2026-01-05'},
        'A sync needs an actual balance'
      ),
      (body({'kind': 'bogus'}), 'kind must be standard, loan or sync'),
    ]) {
      final r = await h.call('POST', events, as: 'owner', body: b);
      expect(r.status, 400, reason: '$b -> ${r.json}');
      expect(r.json['error'], msg, reason: '$b');
    }

    final r = await h.call('POST', events,
        as: 'owner', body: body({'categoryId': null, 'name': 'Ignored'}));
    expect(r.status, 201, reason: '${r.json}');
    final id = r.json['id'] as String;
    expect(r.json['kind'], 'sync');
    expect(r.json['amount'], '-1234.56');
    expect(r.json['direction'], 'credit');
    expect(r.json['name'], 'Sync');
    expect(r.json['recurrenceMode'], 'once');
    final cats =
        (await h.call('GET', '/api/streams/${s.a}/categories', as: 'owner'))
            .json['categories'] as List;
    final cat = cats.firstWhere((c) => c['id'] == r.json['categoryId']);
    expect((cat['name'], cat['color']), ('Sync', '#5AA9A3'));

    // The balance: the day's close is the sync's, with the drift.
    final bal = await h.call(
        'GET', '/api/streams/${s.a}/balance?from=2026-01-01&to=2026-01-06',
        as: 'owner');
    final points = {
      for (final p in bal.json['points'] as List) p['date']: p['closingBalance']
    };
    expect(points['2026-01-05'], '-1234.56');
    expect(points['2026-01-06'], '-1234.56');
    expect(bal.json['syncs'], [
      {
        'eventId': id,
        'date': '2026-01-05',
        'balance': '-1234.56',
        'calculated': '-10',
        'drift': '-1224.56',
        'superseded': false,
        'beforeSeed': false,
      }
    ]);
    // A stream without syncs: no key (S11).
    final plain = await h.call(
        'GET', '/api/streams/${other.a}/balance?from=2026-01-01&to=2026-01-06',
        as: 'owner');
    expect((plain.json as Map).containsKey('syncs'), isFalse);

    // PATCH rules.
    for (final (b, msg) in [
      (<String, Object?>{'kind': 'standard'}, 'kind cannot change'),
      ({'direction': 'debit'}, 'Not available for a sync'),
      (
        {
          'frequency': {'rule': 'monthly', 'interval': 1}
        },
        'Not available for a sync'
      ),
      (
        {'endMode': 'until_date', 'endDate': '2026-03-01'},
        'Not available for a sync'
      ),
      ({'transferToStreamId': other.a}, 'Not available for a sync'),
      ({'name': 'Rent'}, 'Not available for a sync'),
      ({'categoryId': cat['id']}, 'Not available for a sync'),
      (
        {'startDate': '2025-06-01'},
        "A sync must be on or after the stream's start date (1 Jan 2026)"
      ),
    ]) {
      final p = await h.call('PATCH', '/api/events/$id', as: 'owner', body: b);
      expect(p.status, 400, reason: '$b -> ${p.json}');
      expect(p.json['error'], msg, reason: '$b');
    }
    // A standard event cannot become a sync.
    expect(
        (await h.call('PATCH', '/api/events/${s.t}',
                as: 'owner', body: {'kind': 'sync'}))
            .json['error'],
        'kind cannot change');
    // Date, amount (zero allowed), enabled; restating the fixed shape is
    // fine.
    final p = await h.call('PATCH', '/api/events/$id', as: 'owner', body: {
      'startDate': '2026-01-04',
      'amount': '0',
      'enabled': false,
      'name': 'Sync',
      'direction': 'credit',
      'recurrenceMode': 'once',
      'endMode': 'never',
      'transferToStreamId': null,
      'version': r.json['version'],
    });
    expect(p.status, 200, reason: '${p.json}');
    expect((p.json['startDate'], p.json['amount'], p.json['enabled']),
        ('2026-01-04', '0', false));
    final off = await h.call(
        'GET', '/api/streams/${s.a}/balance?from=2026-01-01&to=2026-01-06',
        as: 'owner');
    expect((off.json as Map).containsKey('syncs'), isFalse,
        reason: 'a disabled sync has no effect');

    for (final (m, path, b) in [
      ('PUT', '/api/events/$id/skips/2026-01-04', {'skipped': true}),
      (
        'PUT',
        '/api/events/$id/overrides/2026-01-04',
        {'amount': '1', 'direction': 'credit'}
      ),
      ('DELETE', '/api/events/$id/overrides/2026-01-04', null),
      ('DELETE', '/api/events/$id/overrides', null),
      ('POST', '/api/events/$id/split', {'date': '2026-01-04'}),
    ]) {
      final x = await h.call(m, path, as: 'owner', body: b);
      expect(x.status, 400, reason: '$m $path');
      expect(x.json['error'], 'Not available for a sync');
    }
    expect(
        (await h.call('DELETE', '/api/events/$id', as: 'owner')).status, 204);
  });

  test('formula amounts re-resolve to negative balances', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('fowner', 'SyncF');
    final v = await h.call('POST', '/api/streams/${s.a}/variables',
        as: 'fowner',
        body: {'name': 'bank_now', 'expr': '-100', 'unit': 'money'});
    expect(v.status, 201, reason: '${v.json}');
    final r =
        await h.call('POST', '/api/streams/${s.a}/events', as: 'fowner', body: {
      'kind': 'sync',
      'amountExpr': 'bank_now - 20.5',
      'startDate': '2026-01-03',
    });
    expect(r.status, 201, reason: '${r.json}');
    expect((r.json['amount'], r.json['amountExpr']),
        ('-120.5', 'bank_now - 20.5'));
    final p = await h.call('PATCH', '/api/variables/${v.json['id']}',
        as: 'fowner', body: {'expr': '-300', 'version': v.json['version']});
    expect(p.status, 200, reason: '${p.json}');
    final e = await h.call('GET', '/api/events/${r.json['id']}', as: 'fowner');
    expect(e.json['amount'], '-320.5');
    expect(e.json['exprErrors'], isNull);
    // The usage names the sync (client label "Actual balance").
    final u = await h.call('GET', '/api/variables/${v.json['id']}/usages',
        as: 'fowner');
    expect(u.status, 200, reason: '${u.json}');
    final usage = (u.json['usages'] as List).cast<Map>().single;
    expect((usage['eventKind'], usage['field']), ('sync', 'amount'));
  });

  test('import sync rows + undo; trim + undo', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('iowner', 'SyncI');
    final base = '/api/streams/${s.a}/events';
    // Before the seed (root 2026-01-01, offset -1): rejected per item.
    final early = await h.call('POST', '$base/import?root=2026-01-01',
        as: 'iowner',
        body: jsonEncode([
          {'kind': 'sync', 'amount': '5', 'startOffset': -1}
        ]));
    expect(early.status, 400);
    expect(jsonEncode(early.json),
        contains("A sync must be on or after the stream's start date"));
    final bad = await h.call('POST', '$base/import?root=2026-01-01',
        as: 'iowner',
        body: jsonEncode([
          {
            'kind': 'sync',
            'amount': '5',
            'startOffset': 1,
            'recurrence': {'mode': 'once'}
          }
        ]));
    expect(bad.status, 400);
    expect(jsonEncode(bad.json), contains('not available for a sync'));

    final imp = await h.call('POST', '$base/import?root=2026-01-01',
        as: 'iowner',
        body: jsonEncode([
          {'kind': 'sync', 'amount': '-120.50', 'startOffset': 2},
          {'kind': 'sync', 'amount': '0', 'startOffset': 3, 'enabled': false},
        ]));
    expect(imp.status, 201, reason: '${imp.json}');
    final ids = (imp.json['createdIds'] as List).cast<String>();
    final first =
        (await h.call('GET', '/api/events/${ids[0]}', as: 'iowner')).json;
    expect((first['kind'], first['amount'], first['startDate'], first['name']),
        ('sync', '-120.5', '2026-01-03', 'Sync'));
    final undo = await h
        .call('POST', '$base/import/undo', as: 'iowner', body: {'ids': ids});
    expect(undo.json['deleted'], 2);

    // Trim deletes a sync after the day (a once-off); Undo restores it.
    final c = await h.call('POST', base,
        as: 'iowner',
        body: {'kind': 'sync', 'amount': '-7', 'startDate': '2026-02-01'});
    final id = c.json['id'] as String;
    final t = await h.call('POST', '$base/trim', as: 'iowner', body: {
      'date': '2026-01-15',
      'ids': [id]
    });
    expect(t.status, 200, reason: '${t.json}');
    expect(t.json['deleted'], [id]);
    final u = await h.call('POST', '$base/trim/undo',
        as: 'iowner', body: {'batchId': t.json['batchId']});
    expect(u.status, 200, reason: '${u.json}');
    final back = (await h.call('GET', '/api/events/$id', as: 'iowner')).json;
    expect((back['kind'], back['amount']), ('sync', '-7'));
  });

  test('/project: an edited sync keeps its rank (S12); goal pin notice',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('powner', 'SyncP');
    final base = '/api/streams/${s.a}/events';
    Future<String> mk(String amount) async =>
        (await h.call('POST', base, as: 'powner', body: {
          'kind': 'sync',
          'amount': amount,
          'startDate': '2026-01-10'
        }))
            .json['id'] as String;
    final a = await mk('100');
    final b = await mk('200');
    // Order: b before a, so a (later) wins.
    final st = (await h.call('GET', '/api/streams/${s.a}', as: 'powner')).json;
    final order = [
      for (final e in st['eventOrder'] as List)
        if (e != a) e,
      a,
    ];
    final re = await h.call('PATCH', '/api/streams/${s.a}/reorder-events',
        as: 'powner', body: {'eventIds': order});
    expect(re.status, 200, reason: '${re.json}');
    Future<String> projected(String replaces, String amount) async {
      final r = await h
          .call('POST', '/api/streams/${s.a}/project', as: 'powner', body: {
        'from': '2026-01-10',
        'to': '2026-01-10',
        'events': [
          {
            'kind': 'sync',
            'amount': amount,
            'startDate': '2026-01-10',
            'replacesEventId': replaces,
          }
        ],
      });
      expect(r.status, 200, reason: '${r.json}');
      expect((r.json['syncs'] as List), hasLength(2));
      return (r.json['points'] as List).single['closingBalance'] as String;
    }

    // Editing a (the winner) keeps it winning; editing b keeps it
    // superseded (a preview would otherwise rank last and win).
    expect(await projected(a, '150'), '150');
    expect(await projected(b, '250'), '100');

    // The planner: a pin in the window resets the plan there.
    final g =
        await h.call('POST', '/api/streams/${s.a}/goal', as: 'powner', body: {
      'solveFor': 'targetBalance',
      'startDate': '2026-01-01',
      'endDate': '2026-01-31',
      'amount': 50,
      'interval': 1,
      'unit': 'weeks',
      'today': '2026-01-01',
    });
    expect(g.status, 200, reason: '${g.json}');
    expect(
        g.json['syncNotice'],
        'A sync on 10 Jan sets the balance; planned changes before it are '
        'reset there.');
    final pts = {
      for (final p in g.json['points'] as List) p['date']: p['closingBalance']
    };
    expect(pts['2026-01-10'], '100.00');
    // Jan 15 payment after the pin (weekly from Jan 1: 1, 8, 15, ...).
    expect(pts['2026-01-15'], '150.00');
  });
}
