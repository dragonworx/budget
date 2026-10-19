import 'package:test/test.dart';

import 'harness.dart';

void main() {
  final h = Harness('share.authtest.example');
  setUpAll(() => h.open());
  tearDownAll(() => h.close());

  test('project roles: viewer reads, editor writes, owner manages', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('owner', 'Roles');
    await h.login('ed');
    await h.login('vi');
    final inv = await h.call('POST', '/api/projects/${s.p}/invites',
        as: 'owner', body: {'email': h.email('ed'), 'role': 'editor'});
    expect(inv.status, 201);
    expect(inv.json['status'], 'added');
    await h.call('POST', '/api/projects/${s.p}/invites',
        as: 'owner', body: {'email': h.email('vi')});
    final dup = await h.call('POST', '/api/projects/${s.p}/invites',
        as: 'owner', body: {'email': h.email('vi')});
    expect(dup.status, 409);

    final list = await h.call('GET', '/api/projects', as: 'vi');
    final proj =
        (list.json['projects'] as List).firstWhere((p) => p['id'] == s.p);
    expect(proj['role'], 'viewer');
    expect(proj['shared'], true);
    expect(proj['owner']['email'], h.email('owner'));

    expect(
        (await h.call('GET', '/api/accounts/${s.a}/transactions', as: 'vi'))
            .status,
        200);
    expect(
        (await h.call('POST', '/api/accounts/${s.a}/transactions',
                as: 'vi', body: Harness.tx('x')))
            .status,
        403);
    expect(
        (await h.call('PATCH', '/api/transactions/${s.t}',
                as: 'vi', body: {'name': 'n'}))
            .status,
        403);
    expect(
        (await h.call('PATCH', '/api/transactions/${s.t}',
                as: 'ed', body: {'name': 'edited'}))
            .status,
        200);
    expect(
        (await h.call('PATCH', '/api/projects/${s.p}',
                as: 'ed', body: {'name': 'nope'}))
            .status,
        403);
    expect(
        (await h.call('DELETE', '/api/projects/${s.p}', as: 'ed')).status, 403);
    expect(
        (await h.call('POST', '/api/projects/${s.p}/invites',
                as: 'ed', body: {'email': h.email('z')}))
            .status,
        403);

    // Members list; owner sees invites.
    final m = await h.call('GET', '/api/projects/${s.p}/members', as: 'vi');
    expect((m.json['members'] as List).map((x) => x['role']),
        containsAll(['owner', 'editor', 'viewer']));
    expect(m.json.containsKey('invites'), isFalse);

    // Change role, revoke, leave.
    final vid = await h.userId('vi');
    expect(
        (await h.call('PATCH', '/api/projects/${s.p}/members/$vid',
                as: 'owner', body: {'role': 'editor'}))
            .status,
        200);
    expect(
        (await h.call('POST', '/api/accounts/${s.a}/transactions',
                as: 'vi', body: Harness.tx('now ok')))
            .status,
        201);
    final oid = await h.userId('owner');
    expect(
        (await h.call('DELETE', '/api/projects/${s.p}/members/$oid',
                as: 'owner'))
            .status,
        404);
    expect(
        (await h.call('DELETE', '/api/projects/${s.p}/members/$vid',
                as: 'owner'))
            .status,
        200);
    expect((await h.call('GET', '/api/projects/${s.p}', as: 'vi')).status, 404);
    expect(
        (await h.call('POST', '/api/projects/${s.p}/leave', as: 'ed')).status,
        200);
    expect((await h.call('GET', '/api/projects/${s.p}', as: 'ed')).status, 404);
    expect(
        (await h.call('POST', '/api/projects/${s.p}/leave', as: 'owner'))
            .status,
        409);
  });

  test('pending invite for a not-yet-user: link, preview, accept, auto-accept',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('own2', 'Invites');
    final inv = await h.call('POST', '/api/projects/${s.p}/invites',
        as: 'own2', body: {'email': h.email('newbie'), 'role': 'editor'});
    expect(inv.status, 201);
    expect(inv.json['status'], 'invited');
    expect(inv.json['inviteUrl'], '$origin/invite/${inv.json['token']}');
    final members =
        await h.call('GET', '/api/projects/${s.p}/members', as: 'own2');
    expect(
        (members.json['invites'] as List).single['email'], h.email('newbie'));

    // Rotating the link invalidates the old token.
    final rot =
        await h.call('POST', '/api/invites/${inv.json['id']}/link', as: 'own2');
    expect(rot.status, 200);
    final pre = await h.call('POST', '/api/invites/preview',
        as: 'other', body: {'token': rot.json['token']});
    expect(pre.json['invite']['projectName'], 'Invites');
    expect(pre.json['emailMatches'], false);
    expect(
        (await h.call('POST', '/api/invites/preview',
                as: 'other', body: {'token': inv.json['token']}))
            .status,
        404);
    expect(
        (await h.call('POST', '/api/invites/accept',
                as: 'other', body: {'token': rot.json['token']}))
            .status,
        403);
    // newbie's sign-in (inside h.call) auto-accepted the invite already.
    final acc = await h.call('POST', '/api/invites/accept',
        as: 'newbie', body: {'token': rot.json['token']});
    expect(acc.status, 410);
    expect(
        (await h.call('GET', '/api/projects/${s.p}', as: 'newbie'))
            .json['role'],
        'editor');

    // Explicit accept path + revoke.
    final i2 = await h.call('POST', '/api/projects/${s.p}/invites',
        as: 'own2', body: {'email': h.email('late')});
    final del =
        await h.call('DELETE', '/api/invites/${i2.json['id']}', as: 'newbie');
    expect(del.status, 403);
    expect(
        (await h.call('DELETE', '/api/invites/${i2.json['id']}', as: 'own2'))
            .status,
        200);
    await h.login('late');
    expect(
        (await h.call('GET', '/api/projects/${s.p}', as: 'late')).status, 404);
  });

  test('account-level share: limited project view, only that account',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('own3', 'AcctShare');
    final other = await h.call('POST', '/api/projects/${s.p}/accounts',
        as: 'own3',
        body: {'name': 'Secret', 'seedDate': '2026-01-01'});
    await h.login('friend');
    final r = await h.call('POST', '/api/accounts/${s.a}/invites',
        as: 'own3', body: {'email': h.email('friend'), 'role': 'editor'});
    expect(r.json['status'], 'added');
    final list = await h.call('GET', '/api/projects', as: 'friend');
    final proj =
        (list.json['projects'] as List).firstWhere((p) => p['id'] == s.p);
    expect(proj['access'], 'account');
    expect(proj['sharedAccountIds'], [s.a]);
    final accts =
        await h.call('GET', '/api/projects/${s.p}/accounts', as: 'friend');
    expect((accts.json['accounts'] as List).map((a) => a['id']), [s.a]);
    expect((accts.json['accounts'] as List).single['role'], 'editor');
    expect(
        (await h.call('GET', '/api/accounts/${other.json['id']}', as: 'friend'))
            .status,
        404);
    expect(
        (await h.call('POST', '/api/accounts/${s.a}/transactions',
                as: 'friend', body: Harness.tx('ok')))
            .status,
        201);
    // Structural changes need project membership.
    expect(
        (await h.call('DELETE', '/api/accounts/${s.a}', as: 'friend')).status,
        404);
    expect(
        (await h.call('POST', '/api/projects/${s.p}/accounts',
                as: 'friend', body: {'name': 'x', 'seedDate': '2026-01-01'}))
            .status,
        404);
    final fid = await h.userId('friend');
    expect(
        (await h.call('PATCH', '/api/accounts/${s.a}/shares/$fid',
                as: 'own3', body: {'role': 'viewer'}))
            .status,
        200);
    expect(
        (await h.call('POST', '/api/accounts/${s.a}/transactions',
                as: 'friend', body: Harness.tx('no')))
            .status,
        403);
    expect(
        (await h.call('POST', '/api/accounts/${s.a}/leave', as: 'friend'))
            .status,
        200);
    expect((await h.call('GET', '/api/accounts/${s.a}', as: 'friend')).status,
        404);
  });

  test('transfers across differently shared projects do not leak names',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final mine = await h.seed('xa', 'Private Stuff');
    final shared = await h.seed('xa', 'Shared Stuff');
    await h.login('xb');
    await h.call('POST', '/api/projects/${shared.p}/invites',
        as: 'xa', body: {'email': h.email('xb'), 'role': 'editor'});
    // Owner links Shared -> Private.
    final t = await h.call('POST', '/api/accounts/${shared.a}/transactions',
        as: 'xa', body: Harness.tx('Move', transferTo: mine.a));
    expect(t.status, 201, reason: '${t.json}');
    expect(t.json['transfer']['peerProjectName'], 'Private Stuff');
    final seen =
        await h.call('GET', '/api/accounts/${shared.a}/transactions', as: 'xb');
    final link = (seen.json['transactions'] as List)
        .firstWhere((x) => x['id'] == t.json['id'])['transfer'];
    expect(link['peerReadable'], false);
    expect(link['peerAccountName'], isNull);
    expect(link['peerProjectName'], isNull);
    expect(link['peerProjectId'], isNull);
    // xb cannot edit/delete the linked row (it would change the private side)
    expect(
        (await h.call('DELETE', '/api/transactions/${t.json['id']}', as: 'xb'))
            .status,
        403);
    // ... nor create a transfer into an account they can't edit.
    expect(
        (await h.call('POST', '/api/accounts/${shared.a}/transactions',
                as: 'xb', body: Harness.tx('Steal', transferTo: mine.a)))
            .status,
        404);
  });

  test('optimistic concurrency: stale version -> 409 with current row',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('vv', 'Versions');
    final t0 = await h.call('GET', '/api/transactions/${s.t}', as: 'vv');
    final v = t0.json['version'] as int;
    final ok = await h.call('PATCH', '/api/transactions/${s.t}',
        as: 'vv', body: {'name': 'one', 'version': v});
    expect(ok.status, 200);
    expect(ok.json['version'], v + 1);
    final stale = await h.call('PATCH', '/api/transactions/${s.t}',
        as: 'vv', body: {'name': 'two', 'version': v});
    expect(stale.status, 409);
    expect(stale.json['details']['current']['name'], 'one');
    expect(stale.json['details']['current']['version'], v + 1);
    // If-Match header works too; no version = last write wins.
    final a = await h.call('GET', '/api/accounts/${s.a}', as: 'vv');
    expect(
        (await h.call('PATCH', '/api/accounts/${s.a}',
                as: 'vv',
                body: {'name': 'Renamed'},
                headers: {'if-match': '"${a.json['version'] + 5}"'}))
            .status,
        409);
    expect(
        (await h.call('PATCH', '/api/accounts/${s.a}',
                as: 'vv', body: {'name': 'Renamed'}))
            .status,
        200);
    final p = await h.call('PATCH', '/api/projects/${s.p}',
        as: 'vv', body: {'name': 'Versions 2', 'version': 99});
    expect(p.status, 409);
  });

  test('every mutation is audited', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('au', 'Audited');
    await h.call('PATCH', '/api/transactions/${s.t}',
        as: 'au', body: {'name': 'x'});
    await h.call('DELETE', '/api/transactions/${s.t}', as: 'au');
    final rows = await h.conn!
        .execute("SELECT action, entity_id, account_id::text FROM audit_log "
            "WHERE project_id = '${s.p}' ORDER BY id");
    expect(rows.map((r) => r[0]), [
      'project.created',
      'account.created',
      'transaction.created',
      'transaction.updated',
      'transaction.deleted',
    ]);
    expect(rows[2][1], s.t);
    expect(rows[2][2], s.a);
    final by = await h.conn!
        .execute("SELECT updated_by::text FROM accounts WHERE id = '${s.a}'");
    expect(by.first[0], await h.userId('au'));
  });

  test('admin API: users, allowlist CRUD, disable', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    await h.login('admin');
    await h.login('victim');
    expect((await h.call('GET', '/api/admin/users', as: 'victim')).status, 403);
    final users = await h.call('GET', '/api/admin/users', as: 'admin');
    expect(users.status, 200);
    final victim = (users.json['users'] as List)
        .firstWhere((u) => u['email'] == h.email('victim'));
    expect(
        (await h.call('PATCH', '/api/admin/users/${victim['id']}',
                as: 'admin', body: {'disabled': true}))
            .status,
        200);
    expect((await h.call('GET', '/api/projects', as: 'victim')).status, 401);
    final aid = await h.userId('admin');
    expect(
        (await h.call('PATCH', '/api/admin/users/$aid',
                as: 'admin', body: {'disabled': true}))
            .status,
        400);

    final pat = '@x.${h.domain}';
    expect(
        (await h.call('POST', '/api/admin/allowlist',
                as: 'admin', body: {'pattern': pat}))
            .status,
        201);
    expect(
        (await h.call('POST', '/api/admin/allowlist',
                as: 'admin', body: {'pattern': 'not valid'}))
            .status,
        400);
    final al = await h.call('GET', '/api/admin/allowlist', as: 'admin');
    expect(
        (al.json['entries'] as List).map((e) => e['pattern']), contains(pat));
    expect(
        (await h.call(
                'DELETE', '/api/admin/allowlist/${Uri.encodeComponent(pat)}',
                as: 'admin'))
            .status,
        200);
  });
}
