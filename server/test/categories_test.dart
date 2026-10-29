// Categories (migrations 024, 025: one global set per owner) over the full
// API pipeline: CRUD, unique
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

  // Each test has its own owner (categories are per owner, not per stream).
  var me = 'own';
  Future<List<Map<String, dynamic>>> cats(String a, [String? who]) async => [
        for (final c in (await h.call('GET', '/api/streams/$a/categories',
                as: who ?? me))
            .json['categories'] as List)
          (c as Map).cast<String, dynamic>()
      ];
  Future<List<Map<String, dynamic>>> evs(String a) async => [
        for (final e in (await h.call('GET', '/api/streams/$a/events', as: me))
            .json['events'] as List)
          (e as Map).cast<String, dynamic>()
      ];

  test('CRUD, unique names, rename follows the events, colours', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    me = 'cat1';
    final s = await h.seed(me, 'Cats');
    // The seeded event's name made its category.
    var list = await cats(s.a);
    expect(list.map((c) => c['name']), ['Pay']);
    expect(list.single['eventCount'], 1);
    expect(list.single['color'], matches(RegExp(r'^#[0-9A-F]{6}$')));

    final made = await h.call('POST', '/api/streams/${s.a}/categories',
        as: me, body: {'name': '  Rent  ', 'color': '#b8488e'});
    expect(made.status, 201, reason: '${made.json}');
    expect(made.json['name'], 'Rent');
    expect(made.json['color'], '#B8488E');
    for (final dup in ['rent', ' RENT', 'pay']) {
      final r = await h.call('POST', '/api/streams/${s.a}/categories',
          as: me, body: {'name': dup});
      expect(r.status, 409, reason: dup);
      expect(r.json['details']['code'], 'category_name_taken');
    }
    expect(
        (await h.call('POST', '/api/streams/${s.a}/categories',
                as: me, body: {'name': '   '}))
            .status,
        400);
    // No colour given: a free palette colour.
    final auto = await h.call('POST', '/api/streams/${s.a}/categories',
        as: me, body: {'name': 'Fuel'});
    expect(auto.json['color'], isNot(list.single['color']));

    // Event by categoryId takes the category's name and colour.
    final rentId = made.json['id'] as String;
    final e = await h.call('POST', '/api/streams/${s.a}/events',
        as: me, body: {...Harness.tx('ignored'), 'categoryId': rentId});
    expect(e.status, 201, reason: '${e.json}');
    expect(e.json['name'], 'Rent');
    expect(e.json['categoryId'], rentId);
    expect(e.json['color'], '#B8488E');

    // Rename + recolour: the event follows.
    final ren = await h.call('PATCH', '/api/streams/${s.a}/categories/$rentId',
        as: me, body: {'name': 'Housing', 'color': '#3C8A6E'});
    expect(ren.status, 200, reason: '${ren.json}');
    final ev = await h.call('GET', '/api/events/${e.json['id']}', as: me);
    expect(ev.json['name'], 'Housing');
    expect(ev.json['color'], '#3C8A6E');
    // Renaming onto another category's name is a 409; case change is fine.
    expect(
        (await h.call('PATCH', '/api/streams/${s.a}/categories/$rentId',
                as: me, body: {'name': 'PAY'}))
            .status,
        409);
    expect(
        (await h.call('PATCH', '/api/streams/${s.a}/categories/$rentId',
                as: me, body: {'name': 'housing'}))
            .status,
        200);

    // Moving the event to another category by id.
    final payId = list.single['id'] as String;
    final moved = await h.call('PATCH', '/api/events/${e.json['id']}',
        as: me, body: {'categoryId': payId});
    expect(moved.json['name'], 'Pay');
    // Global: another stream of the same owner uses the same set.
    final mine2 = await h.seed(me, 'Mine 2');
    expect((await cats(mine2.a)).map((c) => c['id']),
        (await cats(s.a)).map((c) => c['id']));
    final there = await h.call('POST', '/api/streams/${mine2.a}/events',
        as: me, body: {...Harness.tx('x'), 'categoryId': payId});
    expect(there.status, 201, reason: '${there.json}');
    expect(there.json['name'], 'Pay');
    // Unknown / another owner's category ids are a 400.
    final other = await h.seed('${me}x', 'Other');
    final foreign = (await cats(other.a, '${me}x')).single['id'];
    expect(
        (await h.call('PATCH', '/api/events/${e.json['id']}',
                as: me, body: {'categoryId': foreign}))
            .status,
        400);

    // Legacy name writes map to (or create) the category by name.
    final legacy = await h.call('POST', '/api/streams/${s.a}/events',
        as: me, body: Harness.tx(' pay '));
    expect(legacy.json['categoryId'], payId);
    expect(legacy.json['name'], 'Pay');
    final fresh = await h.call('POST', '/api/streams/${s.a}/events',
        as: me, body: Harness.tx('Brand new'));
    expect((await cats(s.a)).map((c) => c['name']), contains('Brand new'));
    expect(fresh.json['categoryId'], isNotNull);
  });

  test('newCategory: plans make their own category, never reuse one', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    me = 'cat2';
    final s = await h.seed(me, 'Plans');
    final ok =
        await h.call('POST', '/api/streams/${s.a}/events', as: me, body: {
      ...Harness.tx('x'),
      'newCategory': {'name': 'Holiday fund', 'color': '#6A62D6'}
    });
    expect(ok.status, 201, reason: '${ok.json}');
    expect(ok.json['name'], 'Holiday fund');
    expect(ok.json['color'], '#6A62D6');
    final taken =
        await h.call('POST', '/api/streams/${s.a}/events', as: me, body: {
      ...Harness.tx('x'),
      'newCategory': {'name': 'holiday FUND'}
    });
    expect(taken.status, 409);
    expect((await evs(s.a)).length, 2, reason: 'nothing written on a 409');
  });

  test('hidden category: out of the balance, own enabled flag kept', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    me = 'cat3';
    final s = await h.seed(me, 'Hide');
    Future<String> closing() async {
      final b = await h.call(
          'GET', '/api/streams/${s.a}/balance?from=2026-01-01&to=2026-01-02',
          as: me);
      return (b.json['points'] as List).last['closingBalance'] as String;
    }

    expect(await closing(), '-10');
    final cid = (await cats(s.a)).single['id'];
    final hid = await h.call('PATCH', '/api/streams/${s.a}/categories/$cid',
        as: me, body: {'hidden': true});
    expect(hid.json['hidden'], true);
    expect(await closing(), '0');
    final ev = (await evs(s.a)).single;
    expect(ev['enabled'], true);
    expect(ev['categoryHidden'], true);
    await h.call('PATCH', '/api/streams/${s.a}/categories/$cid',
        as: me, body: {'hidden': false});
    expect(await closing(), '-10');
  });

  test('delete: the category and its events in ALL the owner\'s streams',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    me = 'catdel';
    final s = await h.seed(me, 'DelA');
    final b = await h.seed(me, 'DelB');
    await h.call('POST', '/api/streams/${b.a}/events',
        as: me, body: Harness.tx('Keep'));
    final t = await h.call('POST', '/api/streams/${s.a}/events',
        as: me, body: Harness.tx('Pay', transferTo: b.a));
    expect(t.status, 201);
    // Both sides of the transfer use the one global "Pay".
    final peer = await h.call(
        'GET', '/api/events/${t.json['transfer']['peerEventId']}',
        as: me);
    final pay = (await cats(b.a)).firstWhere((c) => c['name'] == 'Pay');
    expect(peer.json['categoryId'], pay['id']);
    expect(t.json['categoryId'], pay['id']);
    expect(pay['eventCount'], 4, reason: 'two seeds + both transfer sides');

    final pre = await h.call(
        'GET', '/api/streams/${s.a}/categories/${pay['id']}/delete-preview',
        as: me);
    expect(pre.json, {'events': 4, 'counterparts': 0});

    final del = await h
        .call('DELETE', '/api/streams/${s.a}/categories/${pay['id']}', as: me);
    expect(del.status, 200, reason: '${del.json}');
    expect((del.json['deletedEvents'] as List).length, 4);
    expect(await evs(s.a), isEmpty);
    expect((await evs(b.a)).map((e) => e['name']), ['Keep']);
    expect((await cats(s.a)).map((c) => c['name']), ['Keep']);
    final aStream = await h.call('GET', '/api/streams/${s.a}', as: me);
    expect(aStream.json['eventOrder'], isEmpty);
    final bStream = await h.call('GET', '/api/streams/${b.a}', as: me);
    expect((bStream.json['eventOrder'] as List).length, 1);
  });

  test('delete events only: keeps the category', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    me = 'cat5';
    final s = await h.seed(me, 'DelEv');
    await h.call('POST', '/api/streams/${s.a}/events',
        as: me, body: Harness.tx('Pay'));
    await h.call('POST', '/api/streams/${s.a}/events',
        as: me, body: Harness.tx('Keep'));
    // Another stream of the owner: its Pay goes too (and comes back).
    final s2 = await h.seed(me, 'DelEv 2');
    final pay = (await cats(s.a)).firstWhere((c) => c['name'] == 'Pay');
    expect(pay['eventCount'], 3);
    final r = await h.call(
        'DELETE', '/api/streams/${s.a}/categories/${pay['id']}/events',
        as: me);
    expect(r.status, 200, reason: '${r.json}');
    expect((r.json['deletedEvents'] as List).length, 3);
    expect(await evs(s2.a), isEmpty);
    final after = await cats(s.a);
    expect(after.map((c) => [c['name'], c['eventCount']]), [
      ['Pay', 0],
      ['Keep', 1]
    ]);
    expect((await evs(s.a)).map((e) => e['name']), ['Keep']);

    // Undo (the trim batch undo) brings them back, same ids, in the list.
    final batch = r.json['batchId'] as String;
    final u = await h.call('POST', '/api/streams/${s.a}/events/trim/undo',
        as: me, body: {'batchId': batch});
    expect(u.status, 200, reason: '${u.json}');
    final back = await evs(s.a);
    expect(back.map((e) => e['name']).toList()..sort(), ['Keep', 'Pay', 'Pay']);
    expect({...back.where((e) => e['name'] == 'Pay').map((e) => e['id']), s2.t},
        (r.json['deletedEvents'] as List).toSet());
    expect((await cats(s.a)).first['eventCount'], 3);
    expect((await evs(s2.a)).map((e) => e['id']), [s2.t]);
  });

  test('import maps the name column to categories', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    me = 'cat6';
    final s = await h.seed(me, 'Imp');
    final r = await h.call(
        'POST', '/api/streams/${s.a}/events/import?root=2026-01-01',
        as: me,
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

  test(
      'viewers read categories, cannot change them; editors pick and add '
      'but only the owner renames, hides or deletes', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    me = 'cat7';
    final s = await h.seed(me, 'Share');
    await h.login('view');
    await h.call('POST', '/api/streams/${s.a}/invites',
        as: me, body: {'email': h.email('view')});
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

    // An editor of the shared stream: lists the OWNER's set, may add to it
    // (plans), may not rename / hide / delete (they reach every stream).
    await h.login('${me}ed');
    await h.call('POST', '/api/streams/${s.a}/invites',
        as: me, body: {'email': h.email('${me}ed'), 'role': 'editor'});
    final ed = await cats(s.a, '${me}ed');
    expect(ed.single['id'], cid);
    final add = await h.call('POST', '/api/streams/${s.a}/categories',
        as: '${me}ed', body: {'name': 'Editor made'});
    expect(add.status, 201, reason: '${add.json}');
    expect((await cats(s.a)).map((c) => c['name']), ['Pay', 'Editor made']);
    for (final (m, p, b) in [
      ('PATCH', '/api/streams/${s.a}/categories/$cid', {'hidden': true}),
      ('DELETE', '/api/streams/${s.a}/categories/$cid', null),
      ('DELETE', '/api/streams/${s.a}/categories/$cid/events', null),
    ]) {
      expect((await h.call(m, p, as: '${me}ed', body: b)).status, 403,
          reason: 'editor $m $p');
    }
  });
}
