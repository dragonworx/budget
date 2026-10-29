// Categories (migration 024) over the full API pipeline: CRUD, unique
// names, rename follows everywhere, hidden leaves the balance, delete with
// transfer counterparts, delete-events-only, categoryId / newCategory /
// legacy-name event writes, import mapping, viewer read-only. DB-backed
// (TEST_DATABASE_URL, default local budget_test); skipped without Postgres.
import 'package:test/test.dart';

import 'authz/harness.dart';

void main() {
  final h = Harness('categories.authtest.example');
  setUpAll(() => h.open());
  tearDownAll(() => h.close());

  Future<List<Map<String, dynamic>>> cats(String a,
          [String who = 'own']) async =>
      [
        for (final c
            in (await h.call('GET', '/api/streams/$a/categories', as: who))
                .json['categories'] as List)
          (c as Map).cast<String, dynamic>()
      ];
  Future<List<Map<String, dynamic>>> evs(String a) async => [
        for (final e
            in (await h.call('GET', '/api/streams/$a/events', as: 'own'))
                .json['events'] as List)
          (e as Map).cast<String, dynamic>()
      ];

  test('CRUD, unique names, rename follows the events, colours', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('own', 'Cats');
    // The seeded event's name made its category.
    var list = await cats(s.a);
    expect(list.map((c) => c['name']), ['Pay']);
    expect(list.single['eventCount'], 1);
    expect(list.single['color'], matches(RegExp(r'^#[0-9A-F]{6}$')));

    final made = await h.call('POST', '/api/streams/${s.a}/categories',
        as: 'own', body: {'name': '  Rent  ', 'color': '#b8488e'});
    expect(made.status, 201, reason: '${made.json}');
    expect(made.json['name'], 'Rent');
    expect(made.json['color'], '#B8488E');
    for (final dup in ['rent', ' RENT', 'pay']) {
      final r = await h.call('POST', '/api/streams/${s.a}/categories',
          as: 'own', body: {'name': dup});
      expect(r.status, 409, reason: dup);
      expect(r.json['details']['code'], 'category_name_taken');
    }
    expect(
        (await h.call('POST', '/api/streams/${s.a}/categories',
                as: 'own', body: {'name': '   '}))
            .status,
        400);
    // No colour given: a free palette colour.
    final auto = await h.call('POST', '/api/streams/${s.a}/categories',
        as: 'own', body: {'name': 'Fuel'});
    expect(auto.json['color'], isNot(list.single['color']));

    // Event by categoryId takes the category's name and colour.
    final rentId = made.json['id'] as String;
    final e = await h.call('POST', '/api/streams/${s.a}/events',
        as: 'own', body: {...Harness.tx('ignored'), 'categoryId': rentId});
    expect(e.status, 201, reason: '${e.json}');
    expect(e.json['name'], 'Rent');
    expect(e.json['categoryId'], rentId);
    expect(e.json['color'], '#B8488E');

    // Rename + recolour: the event follows.
    final ren = await h.call('PATCH', '/api/streams/${s.a}/categories/$rentId',
        as: 'own', body: {'name': 'Housing', 'color': '#3C8A6E'});
    expect(ren.status, 200, reason: '${ren.json}');
    final ev = await h.call('GET', '/api/events/${e.json['id']}', as: 'own');
    expect(ev.json['name'], 'Housing');
    expect(ev.json['color'], '#3C8A6E');
    // Renaming onto another category's name is a 409; case change is fine.
    expect(
        (await h.call('PATCH', '/api/streams/${s.a}/categories/$rentId',
                as: 'own', body: {'name': 'PAY'}))
            .status,
        409);
    expect(
        (await h.call('PATCH', '/api/streams/${s.a}/categories/$rentId',
                as: 'own', body: {'name': 'housing'}))
            .status,
        200);

    // Moving the event to another category by id.
    final payId = list.single['id'] as String;
    final moved = await h.call('PATCH', '/api/events/${e.json['id']}',
        as: 'own', body: {'categoryId': payId});
    expect(moved.json['name'], 'Pay');
    // Unknown / foreign category ids are a 400.
    final other = await h.seed('own', 'Other');
    final foreign = (await cats(other.a)).single['id'];
    expect(
        (await h.call('PATCH', '/api/events/${e.json['id']}',
                as: 'own', body: {'categoryId': foreign}))
            .status,
        400);

    // Legacy name writes map to (or create) the category by name.
    final legacy = await h.call('POST', '/api/streams/${s.a}/events',
        as: 'own', body: Harness.tx(' pay '));
    expect(legacy.json['categoryId'], payId);
    expect(legacy.json['name'], 'Pay');
    final fresh = await h.call('POST', '/api/streams/${s.a}/events',
        as: 'own', body: Harness.tx('Brand new'));
    expect((await cats(s.a)).map((c) => c['name']), contains('Brand new'));
    expect(fresh.json['categoryId'], isNotNull);
  });

  test('newCategory: plans make their own category, never reuse one', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('own', 'Plans');
    final ok =
        await h.call('POST', '/api/streams/${s.a}/events', as: 'own', body: {
      ...Harness.tx('x'),
      'newCategory': {'name': 'Holiday fund', 'color': '#6A62D6'}
    });
    expect(ok.status, 201, reason: '${ok.json}');
    expect(ok.json['name'], 'Holiday fund');
    expect(ok.json['color'], '#6A62D6');
    final taken =
        await h.call('POST', '/api/streams/${s.a}/events', as: 'own', body: {
      ...Harness.tx('x'),
      'newCategory': {'name': 'holiday FUND'}
    });
    expect(taken.status, 409);
    expect((await evs(s.a)).length, 2, reason: 'nothing written on a 409');
  });

  test('hidden category: out of the balance, own enabled flag kept', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('own', 'Hide');
    Future<String> closing() async {
      final b = await h.call(
          'GET', '/api/streams/${s.a}/balance?from=2026-01-01&to=2026-01-02',
          as: 'own');
      return (b.json['points'] as List).last['closingBalance'] as String;
    }

    expect(await closing(), '-10');
    final cid = (await cats(s.a)).single['id'];
    final hid = await h.call('PATCH', '/api/streams/${s.a}/categories/$cid',
        as: 'own', body: {'hidden': true});
    expect(hid.json['hidden'], true);
    expect(await closing(), '0');
    final ev = (await evs(s.a)).single;
    expect(ev['enabled'], true);
    expect(ev['categoryHidden'], true);
    await h.call('PATCH', '/api/streams/${s.a}/categories/$cid',
        as: 'own', body: {'hidden': false});
    expect(await closing(), '-10');
  });

  test('delete: the category, its events and transfer counterparts', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('own', 'DelA');
    final b = await h.seed('own', 'DelB');
    final t = await h.call('POST', '/api/streams/${s.a}/events',
        as: 'own', body: Harness.tx('Pay', transferTo: b.a));
    expect(t.status, 201);
    // The far side uses B's same-named category ("Pay" exists there too).
    final peer = await h.call(
        'GET', '/api/events/${t.json['transfer']['peerEventId']}',
        as: 'own');
    expect(peer.json['name'], 'Pay');
    final bPay = (await cats(b.a)).single;
    expect(peer.json['categoryId'], bPay['id']);
    expect(bPay['eventCount'], 2);

    final cid = (await cats(s.a)).single['id'];
    final pre = await h.call(
        'GET', '/api/streams/${s.a}/categories/$cid/delete-preview',
        as: 'own');
    expect(pre.json, {'events': 2, 'counterparts': 1});

    final del = await h.call('DELETE', '/api/streams/${s.a}/categories/$cid',
        as: 'own');
    expect(del.status, 200, reason: '${del.json}');
    expect((del.json['deletedEvents'] as List).length, 3);
    expect(await evs(s.a), isEmpty);
    expect(await cats(s.a), isEmpty);
    // B keeps its own event, loses the counterpart; its order is tidy.
    final bEvents = await evs(b.a);
    expect(bEvents.map((e) => e['id']), [b.t]);
    final bStream = await h.call('GET', '/api/streams/${b.a}', as: 'own');
    expect(bStream.json['eventOrder'], [b.t]);
    final aStream = await h.call('GET', '/api/streams/${s.a}', as: 'own');
    expect(aStream.json['eventOrder'], isEmpty);
  });

  test('delete events only: keeps the category', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('own', 'DelEv');
    await h.call('POST', '/api/streams/${s.a}/events',
        as: 'own', body: Harness.tx('Pay'));
    await h.call('POST', '/api/streams/${s.a}/events',
        as: 'own', body: Harness.tx('Keep'));
    final pay = (await cats(s.a)).firstWhere((c) => c['name'] == 'Pay');
    expect(pay['eventCount'], 2);
    final r = await h.call(
        'DELETE', '/api/streams/${s.a}/categories/${pay['id']}/events',
        as: 'own');
    expect(r.status, 200, reason: '${r.json}');
    expect((r.json['deletedEvents'] as List).length, 2);
    final after = await cats(s.a);
    expect(after.map((c) => [c['name'], c['eventCount']]), [
      ['Pay', 0],
      ['Keep', 1]
    ]);
    expect((await evs(s.a)).map((e) => e['name']), ['Keep']);

    // Undo (the trim batch undo) brings them back, same ids, in the list.
    final batch = r.json['batchId'] as String;
    final u = await h.call('POST', '/api/streams/${s.a}/events/trim/undo',
        as: 'own', body: {'batchId': batch});
    expect(u.status, 200, reason: '${u.json}');
    final back = await evs(s.a);
    expect(back.map((e) => e['name']).toList()..sort(), ['Keep', 'Pay', 'Pay']);
    expect(back.where((e) => e['name'] == 'Pay').map((e) => e['id']).toSet(),
        (r.json['deletedEvents'] as List).toSet());
    expect((await cats(s.a)).first['eventCount'], 2);
  });

  test('import maps the name column to categories', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('own', 'Imp');
    final r = await h.call(
        'POST', '/api/streams/${s.a}/events/import?root=2026-01-01',
        as: 'own',
        body: [
          {
            'name': 'PAY',
            'direction': 'credit',
            'amount': '1',
            'startOffset': 0,
            'recurrence': {'mode': 'once'}
          },
          {
            'name': 'Groceries',
            'direction': 'debit',
            'amount': '1',
            'startOffset': 0,
            'recurrence': {'mode': 'once'},
            'color': '#5b7a2a'
          },
        ]);
    expect(r.status, anyOf(200, 201), reason: '${r.json}');
    final list = await cats(s.a);
    expect(list.map((c) => c['name']), ['Pay', 'Groceries']);
    expect(list.last['color'], '#5B7A2A');
    expect(list.first['eventCount'], 2);
  });

  test('viewers read categories, cannot change them', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('own', 'Share');
    await h.login('view');
    await h.call('POST', '/api/streams/${s.a}/invites',
        as: 'own', body: {'email': h.email('view')});
    final list = await cats(s.a, 'view');
    expect(list.single['name'], 'Pay');
    final cid = list.single['id'];
    for (final (m, p, b) in [
      ('POST', '/api/streams/${s.a}/categories', {'name': 'X'}),
      ('PATCH', '/api/streams/${s.a}/categories/$cid', {'hidden': true}),
      ('DELETE', '/api/streams/${s.a}/categories/$cid', null),
      ('DELETE', '/api/streams/${s.a}/categories/$cid/events', null),
    ]) {
      expect((await h.call(m, p, as: 'view', body: b)).status, 403,
          reason: '$m $p');
    }
    expect((await cats(s.a)).single['hidden'], false);
  });
}
