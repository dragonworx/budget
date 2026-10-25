// Save options: once-off overrides of one occurrence and "from now on"
// series splits. DB-backed (TEST_DATABASE_URL); skipped without Postgres.
import 'package:budget_server/domain/enums.dart';
import 'package:budget_server/domain/models.dart';
import 'package:budget_server/engine/balance_engine.dart';
import 'package:budget_server/repo/event_repo.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'authz/harness.dart';

Map<String, Object?> weekly(String name,
        {String amount = '100',
        String start = '2026-01-05',
        String endMode = 'never',
        String? endDate,
        int? count,
        String? transferTo}) =>
    {
      'name': name,
      'direction': 'debit',
      'amount': amount,
      'startDate': start,
      'recurrenceMode': 'every',
      'interval': 1,
      'unit': 'weeks',
      'endMode': endMode,
      if (endDate != null) 'endDate': endDate,
      if (count != null) 'occurrenceCount': count,
      if (transferTo != null) 'transferToStreamId': transferTo,
    };

void main() {
  test('engine: an override replaces only its occurrence', () {
    final t = BudgetEvent(
      id: 't',
      streamId: 'a',
      name: 'Rent',
      direction: Direction.debit,
      amount: Decimal.parse('100'),
      startDate: DateTime.utc(2026, 1, 5),
      recurrenceMode: RecurrenceMode.every,
      interval: 1,
      unit: RecurrenceUnit.weeks,
      endMode: EndMode.never,
      enabled: true,
      createdAt: DateTime.utc(2026),
      overrides: {
        DateTime.utc(2026, 1, 12): AmountOverride(
            direction: Direction.credit, amount: Decimal.parse('30')),
      },
    );
    final s = BalanceEngine.compute(
      seedBalance: Decimal.zero,
      seedDate: DateTime.utc(2026, 1, 1),
      events: [t],
      eventOrder: const ['t'],
      from: DateTime.utc(2026, 1, 1),
      to: DateTime.utc(2026, 1, 25),
    );
    expect(s.occurrences.map((o) => o.signedDelta.toString()).toList(),
        ['-100', '30', '-100']);
    expect(s.points.last.closingBalance, Decimal.parse('-170'));
    expect(t.toJson()['overrides'], [
      {'date': '2026-01-12', 'direction': 'credit', 'amount': '30'}
    ]);
  });

  final h = Harness('saveopts.authtest.example');
  setUpAll(() => h.open());
  tearDownAll(() => h.close());

  Future<String> stream(String who, String name) async {
    final a = await h.call('POST', '/api/streams',
        as: who, body: {'name': name, 'seedDate': '2026-01-01'});
    expect(a.status, 201, reason: '${a.json}');
    return a.json['id'] as String;
  }

  Future<Map<String, dynamic>> create(
      String who, String a, Map<String, Object?> body) async {
    final r =
        await h.call('POST', '/api/streams/$a/events', as: who, body: body);
    expect(r.status, 201, reason: '${r.json}');
    return r.json as Map<String, dynamic>;
  }

  Future<List<String>> deltas(String who, String a, String to) async {
    final b = await h
        .call('GET', '/api/streams/$a/balance?from=2026-01-01&to=$to', as: who);
    expect(b.status, 200, reason: '${b.json}');
    return [
      for (final o in b.json['occurrences'] as List)
        '${o['date']} ${o['signedDelta']}${o['skipped'] == true ? ' skip' : ''}'
    ];
  }

  Future<List<Map<String, dynamic>>> list(String who, String a) async => [
        for (final t in (await h.call('GET', '/api/streams/$a/events', as: who))
            .json['events'] as List)
          t as Map<String, dynamic>
      ];

  test('once-off override: set, projection, version, clear, clear all',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('o1', 'Overrides');
    final t = await create('o1', s.a, weekly('Rent'));
    final id = t['id'];
    var v = t['version'] as int;

    // Not an occurrence: 400, nothing stored.
    final bad = await h.call('PUT', '/api/events/$id/overrides/2026-01-06',
        as: 'o1', body: {'amount': '5', 'direction': 'debit'});
    expect(bad.status, 400);

    final set = await h.call('PUT', '/api/events/$id/overrides/2026-01-12',
        as: 'o1', body: {'amount': '250', 'direction': 'debit', 'version': v});
    expect(set.status, 200, reason: '${set.json}');
    expect(set.json['overrides'], [
      {'date': '2026-01-12', 'direction': 'debit', 'amount': '250'}
    ]);
    expect(set.json['amount'], '100', reason: 'series value unchanged');
    expect(set.json['version'], v + 1, reason: 'override bumps version');
    // A stale editor of the series now conflicts.
    final stale = await h.call('PATCH', '/api/events/$id',
        as: 'o1', body: {'amount': '1', 'version': v});
    expect(stale.status, 409);
    v = set.json['version'] as int;

    await h.call('PUT', '/api/events/$id/overrides/2026-01-19',
        as: 'o1', body: {'amount': '40', 'direction': 'credit', 'version': v});
    final d = await deltas('o1', s.a, '2026-01-26');
    expect(d.where((x) => !x.startsWith('2026-01-01')), [
      '2026-01-05 -100',
      '2026-01-12 -250',
      '2026-01-19 40',
      '2026-01-26 -100',
    ]);

    // A whole-series Save keeps the overrides.
    final saved = await h
        .call('PATCH', '/api/events/$id', as: 'o1', body: {'amount': '120'});
    expect((saved.json['overrides'] as List).length, 2);

    // Clear one: the natural value returns.
    final c1 = await h.call('DELETE', '/api/events/$id/overrides/2026-01-12',
        as: 'o1');
    expect(c1.status, 200);
    expect((c1.json['overrides'] as List).single['date'], '2026-01-19');
    expect(await deltas('o1', s.a, '2026-01-19'), contains('2026-01-12 -120'));

    // Clear all (reports how many).
    final all = await h.call('DELETE', '/api/events/$id/overrides', as: 'o1');
    expect(all.status, 200);
    expect(all.json['cleared'], 1);
    expect(all.json['overrides'], isEmpty);

    // A schedule change drops overrides that are no longer occurrences.
    await h.call('PUT', '/api/events/$id/overrides/2026-01-12',
        as: 'o1', body: {'amount': '1', 'direction': 'debit'});
    final moved = await h.call('PATCH', '/api/events/$id',
        as: 'o1', body: {'startDate': '2026-01-06'});
    expect(moved.json['overrides'], isEmpty);
  });

  test('split "from now on": ends original, new series, moves later state',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('o2', 'Split');
    final t = await create('o2', s.a, weekly('Rent'));
    final id = t['id'];
    await h.call('PUT', '/api/events/$id/skips/2026-01-26',
        as: 'o2', body: {'skipped': true});
    await h.call('PUT', '/api/events/$id/skips/2026-01-19',
        as: 'o2', body: {'skipped': true});
    await h.call('PUT', '/api/events/$id/overrides/2026-01-12',
        as: 'o2', body: {'amount': '7', 'direction': 'debit'});
    await h.call('PUT', '/api/events/$id/overrides/2026-01-19',
        as: 'o2', body: {'amount': '8', 'direction': 'debit'});
    await h.call('PUT', '/api/events/$id/overrides/2026-02-02',
        as: 'o2', body: {'amount': '9', 'direction': 'debit'});
    final v = (await h.call('GET', '/api/events/$id', as: 'o2')).json['version']
        as int;

    final r = await h.call('POST', '/api/events/$id/split', as: 'o2', body: {
      'date': '2026-01-19',
      'name': 'Rent (new)',
      'direction': 'debit',
      'amount': '150',
      'interval': 1,
      'unit': 'weeks',
      'version': v,
    });
    expect(r.status, 200, reason: '${r.json}');
    final orig = r.json['original'] as Map;
    final next = r.json['created'] as Map;
    expect(orig['endMode'], 'until_date');
    expect(orig['endDate'], '2026-01-18');
    expect(orig['amount'], '100');
    expect(orig['overrides'], [
      {'date': '2026-01-12', 'direction': 'debit', 'amount': '7'}
    ]);
    expect(next['startDate'], '2026-01-19');
    expect(next['endMode'], 'never');
    expect(next['amount'], '150');
    expect(next['name'], 'Rent (new)');
    expect(
        next['overrides'],
        [
          {'date': '2026-02-02', 'direction': 'debit', 'amount': '9'}
        ],
        reason: 'later override moves; the one at the split date is dropped');

    final d = await deltas('o2', s.a, '2026-02-09');
    expect(d.where((x) => !x.startsWith('2026-01-01')), [
      '2026-01-05 -100',
      '2026-01-12 -7',
      '2026-01-19 -150 skip',
      '2026-01-26 -150 skip',
      '2026-02-02 -9',
      '2026-02-09 -150',
    ]);
    // New series is listed right after the original.
    final ids = [for (final x in await list('o2', s.a)) x['id']];
    expect(ids.indexOf(next['id']), ids.indexOf(id) + 1);

    // Stale version: 409, nothing changed.
    final stale =
        await h.call('POST', '/api/events/$id/split', as: 'o2', body: {
      'date': '2026-01-12',
      'name': 'x',
      'direction': 'debit',
      'amount': '1',
      'version': v,
    });
    expect(stale.status, 409);
  });

  test('split keeps the end condition: until date and remaining count',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('o3', 'SplitEnds');
    final until = await create(
        'o3', s.a, weekly('U', endMode: 'until_date', endDate: '2026-02-02'));
    final r1 = await h.call('POST', '/api/events/${until['id']}/split',
        as: 'o3',
        body: {
          'date': '2026-01-19',
          'name': 'U',
          'direction': 'debit',
          'amount': '5'
        });
    expect(r1.json['created']['endMode'], 'until_date');
    expect(r1.json['created']['endDate'], '2026-02-02');

    final count =
        await create('o3', s.a, weekly('C', endMode: 'count', count: 5));
    final r2 = await h.call('POST', '/api/events/${count['id']}/split',
        as: 'o3',
        body: {
          'date': '2026-01-19',
          'name': 'C',
          'direction': 'debit',
          'amount': '5'
        });
    expect(r2.status, 200, reason: '${r2.json}');
    expect(r2.json['original']['endDate'], '2026-01-18');
    expect(r2.json['original']['occurrenceCount'], isNull);
    expect(r2.json['created']['endMode'], 'count');
    expect(r2.json['created']['occurrenceCount'], 3, reason: '5 - 2 before');

    // First occurrence: same as Save (no new series).
    final first = await create('o3', s.a, weekly('F'));
    final before = (await list('o3', s.a)).length;
    final r3 = await h.call('POST', '/api/events/${first['id']}/split',
        as: 'o3',
        body: {
          'date': '2026-01-05',
          'name': 'F2',
          'direction': 'credit',
          'amount': '9'
        });
    expect(r3.status, 200);
    expect(r3.json['created'], isNull);
    expect(r3.json['original']['name'], 'F2');
    expect(r3.json['original']['amount'], '9');
    expect(r3.json['original']['endMode'], 'never');
    expect((await list('o3', s.a)).length, before);

    // Not an occurrence / not repeating: 400.
    expect(
        (await h.call('POST', '/api/events/${first['id']}/split',
                as: 'o3',
                body: {
              'date': '2026-01-06',
              'name': 'F',
              'direction': 'debit',
              'amount': '1'
            }))
            .status,
        400);
    expect(
        (await h.call('POST', '/api/events/${s.t}/split', as: 'o3', body: {
          'date': '2026-01-01',
          'name': 'F',
          'direction': 'debit',
          'amount': '1'
        }))
            .status,
        400);
  });

  test('split is atomic: a failure leaves the series untouched', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('o4', 'Atomic');
    final t = await create('o4', s.a, weekly('A'));
    await h.call('PUT', '/api/events/${t['id']}/overrides/2026-01-26',
        as: 'o4', body: {'amount': '3', 'direction': 'debit'});
    final before = await list('o4', s.a);

    // Fails after the split's writes (inside the same DB transaction).
    await expectLater(
        h.conn!.runTx((tx) async {
          await EventRepo(tx).splitAt(
              t['id'] as String, DateTime.utc(2026, 1, 19),
              name: 'A', direction: Direction.debit, amount: Decimal.one);
          throw StateError('boom');
        }),
        throwsStateError);
    // Fails inside the endpoint (invalid edited interval).
    final bad =
        await h.call('POST', '/api/events/${t['id']}/split', as: 'o4', body: {
      'date': '2026-01-19',
      'name': 'A',
      'direction': 'debit',
      'amount': '1',
      'interval': 0,
    });
    expect(bad.status, 400);
    expect(await list('o4', s.a), before);
  });

  test('transfers mirror overrides and split into a new pair', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('o5', 'Transfer');
    final b = await stream('o5', 'Savings');
    final t = await create('o5', s.a, weekly('Save', transferTo: b));
    final id = t['id'];
    final set = await h.call('PUT', '/api/events/$id/overrides/2026-01-12',
        as: 'o5', body: {'amount': '60', 'direction': 'debit'});
    expect(set.status, 200);
    expect(await deltas('o5', b, '2026-01-12'),
        containsAll(['2026-01-05 100', '2026-01-12 60']));

    final r = await h.call('POST', '/api/events/$id/split', as: 'o5', body: {
      'date': '2026-01-19',
      'name': 'Save',
      'direction': 'debit',
      'amount': '200'
    });
    expect(r.status, 200, reason: '${r.json}');
    expect(r.json['created']['transfer']['peerStreamId'], b);
    final peerSide = await list('o5', b);
    expect(peerSide.length, 2);
    expect(await deltas('o5', b, '2026-01-26'), [
      '2026-01-05 100',
      '2026-01-12 60',
      '2026-01-19 200',
      '2026-01-26 200',
    ]);
    // Clearing on one side clears the mirror.
    await h.call('DELETE', '/api/events/$id/overrides', as: 'o5');
    expect(await deltas('o5', b, '2026-01-12'), contains('2026-01-12 100'));
  });

  test('seed shift moves overrides with their occurrences', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('o6', 'Shift');
    final t = await create('o6', s.a, weekly('S'));
    await h.call('PUT', '/api/events/${t['id']}/overrides/2026-01-12',
        as: 'o6', body: {'amount': '1', 'direction': 'debit'});
    final p = await h.call('PATCH', '/api/streams/${s.a}',
        as: 'o6', body: {'seedDate': '2026-01-03'});
    expect(p.status, 200, reason: '${p.json}');
    final got = await h.call('GET', '/api/events/${t['id']}', as: 'o6');
    expect(got.json['overrides'].single['date'], '2026-01-14');
  });

  test('authz: viewers cannot override, clear or split', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('o7', 'Authz');
    await h.login('v7');
    await h.call('POST', '/api/streams/${s.a}/invites',
        as: 'o7', body: {'email': h.email('v7'), 'role': 'viewer'});
    final t = await create('o7', s.a, weekly('R'));
    final id = t['id'];
    await h.call('PUT', '/api/events/$id/overrides/2026-01-12',
        as: 'o7', body: {'amount': '1', 'direction': 'debit'});
    for (final (m, path, body) in [
      ('PUT', 'overrides/2026-01-19', {'amount': '1', 'direction': 'debit'}),
      ('DELETE', 'overrides/2026-01-12', null),
      ('DELETE', 'overrides', null),
      (
        'POST',
        'split',
        {'date': '2026-01-19', 'name': 'x', 'direction': 'debit', 'amount': '1'}
      ),
    ]) {
      final r = await h.call(m, '/api/events/$id/$path', as: 'v7', body: body);
      expect(r.status, 403, reason: '$m $path');
    }
    // Strangers see nothing.
    await h.login('x7');
    expect(
        (await h.call('DELETE', '/api/events/$id/overrides', as: 'x7')).status,
        404);
    final still = await h.call('GET', '/api/events/$id', as: 'v7');
    expect((still.json['overrides'] as List).length, 1);
    expect((await list('o7', s.a)).length, 2);
  });

  test('deleting a series removes its overrides', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('o8', 'Cascade');
    final t = await create('o8', s.a, weekly('D'));
    await h.call('PUT', '/api/events/${t['id']}/overrides/2026-01-12',
        as: 'o8', body: {'amount': '1', 'direction': 'debit'});
    await h.call('DELETE', '/api/events/${t['id']}', as: 'o8');
    final rows = await h.conn!.execute(
        Sql.named(
            'SELECT 1 FROM occurrence_overrides WHERE event_id = @t::uuid'),
        parameters: {'t': t['id']});
    expect(rows, isEmpty);
  });

  test(
      'trim (dot popup): a counted series ends on an occurrence; later '
      'overrides go; undo restores the count and they can be set again',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('o9', 'Trim');
    final t =
        await create('o9', s.a, weekly('Gym', endMode: 'count', count: 6));
    final id = t['id'];
    for (final d in ['2026-01-12', '2026-01-26']) {
      final r = await h.call('PUT', '/api/events/$id/overrides/$d',
          as: 'o9', body: {'amount': '7', 'direction': 'debit'});
      expect(r.status, 200, reason: '${r.json}');
    }
    // What the client sends: the full schedule, unset fields as null.
    final full = {
      ...weekly('Gym'),
      'endMode': 'untilDate',
      'endDate': '2026-01-19',
      'occurrenceCount': null,
    };
    final trim = await h.call('PATCH', '/api/events/$id', as: 'o9', body: full);
    expect(trim.status, 200, reason: '${trim.json}');
    expect(trim.json['endMode'], 'until_date');
    expect(trim.json['occurrenceCount'], isNull);
    expect(trim.json['overrides'], [
      {'date': '2026-01-12', 'direction': 'debit', 'amount': '7'}
    ]);
    final d = await deltas('o9', s.a, '2026-03-01');
    expect(d.where((x) => !x.startsWith('2026-01-01')),
        ['2026-01-05 -100', '2026-01-12 -7', '2026-01-19 -100']);
    // Undo: back to 6 times (endDate cleared), then the dropped once-off.
    final undo = await h.call('PATCH', '/api/events/$id', as: 'o9', body: {
      ...weekly('Gym'),
      'endMode': 'count',
      'endDate': null,
      'occurrenceCount': 6,
    });
    expect(undo.status, 200, reason: '${undo.json}');
    expect(undo.json['endDate'], isNull);
    expect(undo.json['occurrenceCount'], 6);
    final again = await h.call('PUT', '/api/events/$id/overrides/2026-01-26',
        as: 'o9', body: {'amount': '7', 'direction': 'debit'});
    expect(again.status, 200);
    expect((again.json['overrides'] as List).length, 2);
  });
}
