// Categories (migration 035: one set per stream) over the full
// API pipeline: CRUD, unique
// names, rename follows everywhere, hidden leaves the balance, delete with
// transfer counterparts, delete-events-only, categoryId / newCategory /
// legacy-name event writes, import mapping, Move to… path remap, editor
// write / viewer read-only. DB-backed
// (TEST_DATABASE_URL, default local budget_test); skipped without Postgres.
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'authz/harness.dart';

void main() {
  final h = Harness('categories.authtest.example');
  setUpAll(() => h.open());
  tearDownAll(() => h.close());

  // Each test has its own owner (categories are per stream).
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
    // Another stream of the same owner has its own copy, not the same ids.
    final mine2 = await h.seed(me, 'Mine 2');
    expect((await cats(mine2.a)).map((c) => c['id']).toSet(),
        isNot((await cats(s.a)).map((c) => c['id']).toSet()));
    expect(
        (await h.call('POST', '/api/streams/${mine2.a}/events',
                as: me, body: {...Harness.tx('x'), 'categoryId': payId}))
            .status,
        400);
    final pay2 = (await cats(mine2.a)).firstWhere((c) => c['name'] == 'Pay');
    final there = await h.call('POST', '/api/streams/${mine2.a}/events',
        as: me, body: {...Harness.tx('x'), 'categoryId': pay2['id']});
    expect(there.status, 201, reason: '${there.json}');
    expect(there.json['name'], 'Pay');
    // Unknown / another stream's category ids are a 400.
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

  test('delete: the category and its events in this stream', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    me = 'catdel';
    final s = await h.seed(me, 'DelA');
    final b = await h.seed(me, 'DelB');
    await h.call('POST', '/api/streams/${b.a}/events',
        as: me, body: Harness.tx('Keep'));
    final t = await h.call('POST', '/api/streams/${s.a}/events',
        as: me, body: Harness.tx('Pay', transferTo: b.a));
    expect(t.status, 201);
    // Each stream has its own Pay; transfer legs use the same path, different ids.
    final peer = await h.call(
        'GET', '/api/events/${t.json['transfer']['peerEventId']}',
        as: me);
    final payA = (await cats(s.a)).firstWhere((c) => c['name'] == 'Pay');
    final payB = (await cats(b.a)).firstWhere((c) => c['name'] == 'Pay');
    expect(payA['id'], isNot(payB['id']));
    expect(payA['streamId'], s.a);
    expect(payB['streamId'], b.a);
    expect(t.json['categoryId'], payA['id']);
    expect(peer.json['categoryId'], payB['id']);
    // A: seed Pay + transfer side. B: seed Pay + transfer side + Keep.
    expect(payA['eventCount'], 2);
    expect(payB['eventCount'], 2);

    final pre = await h.call(
        'GET', '/api/streams/${s.a}/categories/${payA['id']}/delete-preview',
        as: me);
    // This stream's two Pays, plus the transfer counterpart on B.
    expect(pre.json, {'events': 2, 'counterparts': 1, 'children': 0});

    final del = await h
        .call('DELETE', '/api/streams/${s.a}/categories/${payA['id']}', as: me);
    expect(del.status, 200, reason: '${del.json}');
    expect((del.json['deletedEvents'] as List).length, 3);
    expect(await evs(s.a), isEmpty);
    // B's seed Pay and Keep stay; its transfer leg was the counterpart.
    expect((await evs(b.a)).map((e) => e['name']).toList()..sort(),
        ['Keep', 'Pay']);
    expect((await cats(s.a)).map((c) => c['name']), isEmpty);
    expect((await cats(b.a)).map((c) => c['name']).toList()..sort(),
        ['Keep', 'Pay']);
    final aStream = await h.call('GET', '/api/streams/${s.a}', as: me);
    expect(aStream.json['eventOrder'], isEmpty);
    final bStream = await h.call('GET', '/api/streams/${b.a}', as: me);
    expect((bStream.json['eventOrder'] as List).length, 2);
  });

  test('delete events only: keeps the category', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    me = 'cat5';
    final s = await h.seed(me, 'DelEv');
    await h.call('POST', '/api/streams/${s.a}/events',
        as: me, body: Harness.tx('Pay'));
    await h.call('POST', '/api/streams/${s.a}/events',
        as: me, body: Harness.tx('Keep'));
    // Another stream of the owner keeps its own Pay.
    final s2 = await h.seed(me, 'DelEv 2');
    final pay = (await cats(s.a)).firstWhere((c) => c['name'] == 'Pay');
    final pay2 = (await cats(s2.a)).firstWhere((c) => c['name'] == 'Pay');
    expect(pay['id'], isNot(pay2['id']));
    expect(pay['eventCount'], 2);
    expect(pay2['eventCount'], 1);
    final r = await h.call(
        'DELETE', '/api/streams/${s.a}/categories/${pay['id']}/events',
        as: me);
    expect(r.status, 200, reason: '${r.json}');
    expect((r.json['deletedEvents'] as List).length, 2);
    expect((await evs(s2.a)).map((e) => e['id']), [s2.t]);
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
    expect(back.where((e) => e['name'] == 'Pay').map((e) => e['id']).toSet(),
        (r.json['deletedEvents'] as List).toSet());
    expect(
        (await cats(s.a)).firstWhere((c) => c['name'] == 'Pay')['eventCount'],
        2);
    expect((await evs(s2.a)).map((e) => e['id']), [s2.t]);
    expect(
        (await cats(s2.a)).firstWhere((c) => c['name'] == 'Pay')['eventCount'],
        1);
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
      'viewers read categories, cannot change them; editors may edit '
      'this stream\'s categories', () async {
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

    // An editor of the shared stream may add, rename, hide and delete
    // this stream's categories only.
    await h.login('${me}ed');
    await h.call('POST', '/api/streams/${s.a}/invites',
        as: me, body: {'email': h.email('${me}ed'), 'role': 'editor'});
    final ed = await cats(s.a, '${me}ed');
    expect(ed.single['id'], cid);
    final add = await h.call('POST', '/api/streams/${s.a}/categories',
        as: '${me}ed', body: {'name': 'Editor made'});
    expect(add.status, 201, reason: '${add.json}');
    expect((await cats(s.a)).map((c) => c['name']), ['Pay', 'Editor made']);
    final hid = await h.call('PATCH', '/api/streams/${s.a}/categories/$cid',
        as: '${me}ed', body: {'hidden': true});
    expect(hid.status, 200, reason: '${hid.json}');
    expect(hid.json['hidden'], true);
    final evDel = await h.call(
        'DELETE', '/api/streams/${s.a}/categories/$cid/events',
        as: '${me}ed');
    expect(evDel.status, 200, reason: '${evDel.json}');
    final made =
        (await cats(s.a)).firstWhere((c) => c['name'] == 'Editor made');
    final del = await h.call(
        'DELETE', '/api/streams/${s.a}/categories/${made['id']}',
        as: '${me}ed');
    expect(del.status, 200, reason: '${del.json}');
    expect((await cats(s.a)).map((c) => c['name']), ['Pay']);
  });

  test('hierarchy: nest, max depth 2, unique names, recursive delete',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    me = 'cathier';
    final s = await h.seed(me, 'Hier');
    final parent = await h.call('POST', '/api/streams/${s.a}/categories',
        as: me, body: {'name': 'Utilities'});
    expect(parent.status, 201, reason: '${parent.json}');
    expect(parent.json['parentId'], isNull);
    expect(parent.json['depth'], 0);
    final power = await h.call('POST', '/api/streams/${s.a}/categories',
        as: me, body: {'name': 'Power', 'parentId': parent.json['id']});
    expect(power.status, 201, reason: '${power.json}');
    expect(power.json['parentId'], parent.json['id']);
    expect(power.json['depth'], 1);

    // A grandchild is rejected.
    final deep = await h.call('POST', '/api/streams/${s.a}/categories',
        as: me, body: {'name': 'Peak Power', 'parentId': power.json['id']});
    expect(deep.status, 400, reason: '${deep.json}');
    expect(deep.json['details']['code'], 'max_depth');

    // Owner-wide unique names still hold across the tree.
    final dup = await h.call('POST', '/api/streams/${s.a}/categories',
        as: me, body: {'name': 'power'});
    expect(dup.status, 409);

    // Events may not be filed on a folder.
    final ev = await h.call('POST', '/api/streams/${s.a}/events',
        as: me,
        body: {...Harness.tx('ignored'), 'categoryId': parent.json['id']});
    expect(ev.status, 400, reason: '${ev.json}');
    expect(ev.json['details']['code'], 'category_not_a_leaf');
    final ev2 = await h.call('POST', '/api/streams/${s.a}/events',
        as: me,
        body: {...Harness.tx('ignored'), 'categoryId': power.json['id']});
    expect(ev2.status, 201, reason: '${ev2.json}');
    final list = await cats(s.a);
    final u = list.firstWhere((c) => c['name'] == 'Utilities');
    expect(u['eventCount'], 0);
    expect(u['eventCountSubtree'], 1);
    expect(list.firstWhere((c) => c['name'] == 'Power')['eventCount'], 1);

    // Deleting the parent removes the child and events filed on it.
    // (Nesting is capped at 2 levels, so this is the deepest legal tree.)
    final pre = await h.call('GET',
        '/api/streams/${s.a}/categories/${parent.json['id']}/delete-preview',
        as: me);
    expect(pre.json, {'events': 1, 'counterparts': 0, 'children': 1});
    final del = await h.call(
        'DELETE', '/api/streams/${s.a}/categories/${parent.json['id']}',
        as: me);
    expect(del.status, 200, reason: '${del.json}');
    expect((del.json['deletedEvents'] as List).length, 1);
    expect(
        (await cats(s.a)).map((c) => c['name']), isNot(contains('Utilities')));
    expect((await cats(s.a)).map((c) => c['name']), isNot(contains('Power')));
    expect(
        (await evs(s.a)).map((e) => e['id']), isNot(contains(ev2.json['id'])));
    expect((await evs(s.a)).map((e) => e['name']), contains('Pay'));
  });

  test('delete folder: subtree events, counterparts, favourites, authz',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    me = 'catrec';
    final s = await h.seed(me, 'RecA');
    final b = await h.seed(me, 'RecB');
    final housing = await h.call('POST', '/api/streams/${s.a}/categories',
        as: me, body: {'name': 'Housing'});
    expect(housing.status, 201, reason: '${housing.json}');
    final rent = await h.call('POST', '/api/streams/${s.a}/categories',
        as: me, body: {'name': 'Rent', 'parentId': housing.json['id']});
    final rates = await h.call('POST', '/api/streams/${s.a}/categories',
        as: me, body: {'name': 'Rates', 'parentId': housing.json['id']});
    expect(rent.status, 201, reason: '${rent.json}');
    expect(rates.status, 201, reason: '${rates.json}');

    final tr =
        await h.call('POST', '/api/streams/${s.a}/events', as: me, body: {
      ...Harness.tx('ignored', transferTo: b.a),
      'categoryId': rent.json['id'],
    });
    expect(tr.status, 201, reason: '${tr.json}');
    final r1 =
        await h.call('POST', '/api/streams/${s.a}/events', as: me, body: {
      ...Harness.tx('ignored'),
      'categoryId': rates.json['id'],
      'amount': '20',
    });
    final r2 =
        await h.call('POST', '/api/streams/${s.a}/events', as: me, body: {
      ...Harness.tx('ignored'),
      'categoryId': rates.json['id'],
      'amount': '15',
    });
    expect(r1.status, 201, reason: '${r1.json}');
    expect(r2.status, 201, reason: '${r2.json}');

    final star = await h.call(
        'PUT', '/api/streams/${s.a}/categories/${rent.json['id']}/favorite',
        as: me);
    expect(star.status, 200, reason: '${star.json}');

    final folderPre = await h.call('GET',
        '/api/streams/${s.a}/categories/${housing.json['id']}/delete-preview',
        as: me);
    // Rent transfer + two Rates events in this stream; one counterpart on B.
    expect(folderPre.json, {'events': 3, 'counterparts': 1, 'children': 2});

    await h.login('catrecview');
    await h.call('POST', '/api/streams/${s.a}/invites',
        as: me, body: {'email': h.email('catrecview')});
    final asView = await h.call(
        'DELETE', '/api/streams/${s.a}/categories/${housing.json['id']}',
        as: 'catrecview');
    expect(asView.status, 403, reason: '${asView.json}');

    await h.login('catreced');
    await h.call('POST', '/api/streams/${s.a}/invites',
        as: me, body: {'email': h.email('catreced'), 'role': 'editor'});
    final recDel = await h.call(
        'DELETE', '/api/streams/${s.a}/categories/${housing.json['id']}',
        as: 'catreced');
    expect(recDel.status, 200, reason: '${recDel.json}');
    // 3 events in this stream + the transfer counterpart.
    expect((recDel.json['deletedEvents'] as List).length, 4);
    final names = [for (final c in await cats(s.a)) c['name']];
    expect(names, isNot(contains('Housing')));
    expect(names, isNot(contains('Rent')));
    expect(names, isNot(contains('Rates')));
    expect(names, contains('Pay'));
    expect((await evs(s.a)).map((e) => e['name']), ['Pay']);
    // B's seed Pay stays; its transfer leg was the counterpart.
    expect((await evs(b.a)).map((e) => e['name']).toList(), ['Pay']);
    final favs =
        await h.call('GET', '/api/streams/${s.a}/category-favorites', as: me);
    expect(favs.json['favorites'], isEmpty);
    final audit = await h.conn!.execute(
        Sql.named("SELECT action FROM audit_log "
            "WHERE stream_id = @a::uuid AND action = 'category.deleted' "
            "AND entity_id = @c"),
        parameters: {'a': s.a, 'c': housing.json['id']});
    expect(audit.length, 1);
  });

  test('Sync cannot be nested; favourites are per user', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    me = 'catfav';
    final s = await h.seed(me, 'Favs');
    final parent = await h.call('POST', '/api/streams/${s.a}/categories',
        as: me, body: {'name': 'Shopping'});
    final sync = await h.call('POST', '/api/streams/${s.a}/categories',
        as: me, body: {'name': 'Sync'});
    expect(sync.status, 201);
    final nestSync = await h.call(
        'PATCH', '/api/streams/${s.a}/categories/${sync.json['id']}',
        as: me, body: {'parentId': parent.json['id']});
    expect(nestSync.status, 400, reason: '${nestSync.json}');
    expect(nestSync.json['details']['code'], 'sync_nested');
    final underSync = await h.call('POST', '/api/streams/${s.a}/categories',
        as: me, body: {'name': 'Coles', 'parentId': sync.json['id']});
    expect(underSync.status, 400, reason: '${underSync.json}');

    final coles = await h.call('POST', '/api/streams/${s.a}/categories',
        as: me, body: {'name': 'Coles', 'parentId': parent.json['id']});
    expect(coles.status, 201, reason: '${coles.json}');

    final star = await h.call(
        'PUT', '/api/streams/${s.a}/categories/${coles.json['id']}/favorite',
        as: me);
    expect(star.status, 200, reason: '${star.json}');
    expect([for (final f in star.json['favorites'] as List) f['categoryId']],
        [coles.json['id']]);

    // A viewer can star for themselves; the owner's list is unchanged.
    await h.login('favview');
    await h.call('POST', '/api/streams/${s.a}/invites',
        as: me, body: {'email': h.email('favview')});
    final folderStar = await h.call(
        'PUT', '/api/streams/${s.a}/categories/${parent.json['id']}/favorite',
        as: 'favview');
    expect(folderStar.status, 400, reason: '${folderStar.json}');
    expect(folderStar.json['details']['code'], 'category_not_a_leaf');
    final vStar = await h.call(
        'PUT', '/api/streams/${s.a}/categories/${coles.json['id']}/favorite',
        as: 'favview');
    expect(vStar.status, 200, reason: '${vStar.json}');
    expect([for (final f in vStar.json['favorites'] as List) f['categoryId']],
        [coles.json['id']]);
    final mine =
        await h.call('GET', '/api/streams/${s.a}/category-favorites', as: me);
    expect([for (final f in mine.json['favorites'] as List) f['categoryId']],
        [coles.json['id']]);

    final unstar = await h.call(
        'DELETE', '/api/streams/${s.a}/categories/${coles.json['id']}/favorite',
        as: me);
    expect(unstar.status, 200);
    expect(unstar.json['favorites'], isEmpty);

    // Reorder siblings.
    final fuel = await h.call('POST', '/api/streams/${s.a}/categories',
        as: me, body: {'name': 'Fuel', 'parentId': parent.json['id']});
    expect(fuel.status, 201);
    final re = await h
        .call('POST', '/api/streams/${s.a}/categories/reorder', as: me, body: {
      'parentId': parent.json['id'],
      'ids': [fuel.json['id'], coles.json['id']],
    });
    expect(re.status, 200, reason: '${re.json}');
    final kids = [
      for (final c in re.json['categories'] as List)
        if (c['parentId'] == parent.json['id']) c
    ]..sort((a, b) => (a['sortOrder'] as num).compareTo(b['sortOrder'] as num));
    expect([for (final c in kids) c['name']], ['Fuel', 'Coles']);

    // Editors may add a child, reparent and reorder (this stream only).
    await h.login('${me}ed');
    await h.call('POST', '/api/streams/${s.a}/invites',
        as: me, body: {'email': h.email('${me}ed'), 'role': 'editor'});
    final added = await h.call('POST', '/api/streams/${s.a}/categories',
        as: '${me}ed',
        body: {'name': 'Woolies', 'parentId': parent.json['id']});
    expect(added.status, 201, reason: '${added.json}');
    final lifted = await h.call(
        'PATCH', '/api/streams/${s.a}/categories/${coles.json['id']}',
        as: '${me}ed', body: {'parentId': null});
    expect(lifted.status, 200, reason: '${lifted.json}');
    expect(lifted.json['parentId'], isNull);
    expect(
        (await h.call('POST', '/api/streams/${s.a}/categories/reorder',
                as: '${me}ed',
                body: {
              'parentId': parent.json['id'],
              'ids': [fuel.json['id'], added.json['id']]
            }))
            .status,
        200);
  });

  test('adding a child moves parent events when asked; nest is blocked',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    me = 'catleaf';
    final s = await h.seed(me, 'Leaf');
    final ins = await h.call('POST', '/api/streams/${s.a}/categories',
        as: me, body: {'name': 'Insurance'});
    expect(ins.status, 201);
    final ev = await h.call('POST', '/api/streams/${s.a}/events',
        as: me, body: {...Harness.tx('ignored'), 'categoryId': ins.json['id']});
    expect(ev.status, 201, reason: '${ev.json}');

    final blocked = await h.call('POST', '/api/streams/${s.a}/categories',
        as: me, body: {'name': 'Car insurance', 'parentId': ins.json['id']});
    expect(blocked.status, 400, reason: '${blocked.json}');
    expect(blocked.json['details']['code'], 'category_has_events');

    final child =
        await h.call('POST', '/api/streams/${s.a}/categories', as: me, body: {
      'name': 'Car insurance',
      'parentId': ins.json['id'],
      'moveParentEvents': true,
    });
    expect(child.status, 201, reason: '${child.json}');
    expect(child.json['parentId'], ins.json['id']);

    final after = await cats(s.a);
    expect(after.firstWhere((c) => c['name'] == 'Insurance')['eventCount'], 0);
    expect(
        after.firstWhere((c) => c['name'] == 'Car insurance')['eventCount'], 1);

    // Nesting a leaf under a category that still has events is blocked.
    final other = await h.call('POST', '/api/streams/${s.a}/categories',
        as: me, body: {'name': 'Streaming'});
    final ev2 = await h.call('POST', '/api/streams/${s.a}/events',
        as: me,
        body: {...Harness.tx('ignored'), 'categoryId': other.json['id']});
    expect(ev2.status, 201);
    final nest = await h.call(
        'PATCH', '/api/streams/${s.a}/categories/${child.json['id']}',
        as: me, body: {'parentId': other.json['id']});
    expect(nest.status, 400, reason: '${nest.json}');
    expect(nest.json['details']['code'], 'category_has_events');
  });

  test('Move to… remaps the category by full path in the target stream',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    me = 'catmove';
    final a = await h.seed(me, 'MoveA');
    final b = await h.seed(me, 'MoveB');
    final housing = await h.call('POST', '/api/streams/${a.a}/categories',
        as: me, body: {'name': 'Housing', 'color': '#9250C8'});
    expect(housing.status, 201, reason: '${housing.json}');
    final rent = await h.call('POST', '/api/streams/${a.a}/categories',
        as: me,
        body: {
          'name': 'Rent',
          'color': '#5B7A2A',
          'parentId': housing.json['id']
        });
    expect(rent.status, 201, reason: '${rent.json}');
    final ev = await h.call('POST', '/api/streams/${a.a}/events',
        as: me,
        body: {...Harness.tx('ignored'), 'categoryId': rent.json['id']});
    expect(ev.status, 201, reason: '${ev.json}');
    final moved = await h.call('POST', '/api/events/${ev.json['id']}/move',
        as: me, body: {'streamId': b.a});
    expect(moved.status, 200, reason: '${moved.json}');
    expect(moved.json['categoryId'], isNot(rent.json['id']));
    final destCats = await cats(b.a);
    final dest =
        destCats.firstWhere((c) => c['id'] == moved.json['categoryId']);
    expect(dest['name'], 'Rent');
    expect(dest['color'], '#5B7A2A');
    expect(dest['streamId'], b.a);
    expect(dest['parentId'], isNotNull);
    final parent = destCats.firstWhere((c) => c['id'] == dest['parentId']);
    expect(parent['name'], 'Housing');
    expect(parent['color'], '#9250C8');
    expect(parent['id'], isNot(housing.json['id']));
    // Source stream still has its own Housing / Rent.
    final src = (await cats(a.a)).firstWhere((c) => c['id'] == rent.json['id']);
    expect(src['name'], 'Rent');
    expect(src['color'], '#5B7A2A');
    expect(src['parentId'], housing.json['id']);
  });

  test('editor may rename a category; viewer may not', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    me = 'catauthz';
    final s = await h.seed(me, 'AuthzCats');
    await h.login('cateditor');
    await h.login('catviewer');
    await h.call('POST', '/api/streams/${s.a}/invites',
        as: me, body: {'email': h.email('cateditor'), 'role': 'editor'});
    await h.call('POST', '/api/streams/${s.a}/invites',
        as: me, body: {'email': h.email('catviewer')});
    final pay = (await cats(s.a)).firstWhere((c) => c['name'] == 'Pay');
    final denied = await h.call(
        'PATCH', '/api/streams/${s.a}/categories/${pay['id']}',
        as: 'catviewer', body: {'name': 'Salary'});
    expect(denied.status, 403);
    final ok = await h.call(
        'PATCH', '/api/streams/${s.a}/categories/${pay['id']}',
        as: 'cateditor', body: {'name': 'Salary'});
    expect(ok.status, 200, reason: '${ok.json}');
    expect(ok.json['name'], 'Salary');
    expect((await cats(s.a, 'catviewer')).map((c) => c['name']),
        contains('Salary'));
  });
}
