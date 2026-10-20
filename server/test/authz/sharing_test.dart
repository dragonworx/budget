import 'package:test/test.dart';

import 'harness.dart';

void main() {
  final h = Harness('share.authtest.example');
  setUpAll(() => h.open());
  tearDownAll(() => h.close());

  test('account roles: owner manages, editor writes, viewer reads', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('owner', 'Roles');
    final other = await h.call('POST', '/api/accounts',
        as: 'owner', body: {'name': 'Secret', 'seedDate': '2026-01-01'});
    expect(other.status, 201);
    expect(other.json['role'], 'owner');
    await h.login('ed');
    await h.login('vi');
    final inv = await h.call('POST', '/api/accounts/${s.a}/invites',
        as: 'owner', body: {'email': h.email('ed'), 'role': 'editor'});
    expect(inv.status, 201);
    expect(inv.json['status'], 'added');
    await h.call('POST', '/api/accounts/${s.a}/invites',
        as: 'owner', body: {'email': h.email('vi')});
    // Inviting yourself is refused.
    expect(
        (await h.call('POST', '/api/accounts/${s.a}/invites',
                as: 'owner', body: {'email': h.email('owner')}))
            .status,
        409);

    // Lists: mine first, then shared with me (role + owner), nothing else.
    final mine = await h.call('GET', '/api/accounts', as: 'owner');
    expect((mine.json['accounts'] as List).map((a) => a['id']),
        containsAll([s.a, other.json['id']]));
    expect((mine.json['accounts'] as List).every((a) => a['shared'] == false),
        isTrue);
    final list = await h.call('GET', '/api/accounts', as: 'vi');
    final acc = (list.json['accounts'] as List).single;
    expect(acc['id'], s.a);
    expect(acc['role'], 'viewer');
    expect(acc['shared'], true);
    expect(acc['owner']['email'], h.email('owner'));
    expect(list.json['lastAccountId'], isNull);
    expect((await h.call('GET', '/api/accounts/${s.a}', as: 'vi')).json['role'],
        'viewer');
    // Opening an account makes it the landing account.
    expect(
        (await h.call('GET', '/api/accounts', as: 'vi')).json['lastAccountId'],
        s.a);
    expect(
        (await h.call('GET', '/api/accounts/${other.json['id']}', as: 'vi'))
            .status,
        404);
    // POST /opened records it explicitly (cached client views); a stranger's
    // account cannot be recorded.
    expect(
        (await h.call('POST', '/api/accounts/${other.json['id']}/opened',
                as: 'owner'))
            .status,
        200);
    expect(
        (await h.call('GET', '/api/accounts', as: 'owner'))
            .json['lastAccountId'],
        other.json['id']);
    expect(
        (await h.call('POST', '/api/accounts/${s.a}/opened', as: 'owner'))
            .status,
        200);
    expect(
        (await h.call('GET', '/api/accounts', as: 'owner'))
            .json['lastAccountId'],
        s.a);
    expect(
        (await h.call('POST', '/api/accounts/${other.json['id']}/opened',
                as: 'vi'))
            .status,
        404);

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
    // Only the owner deletes the account or shares it.
    expect(
        (await h.call('DELETE', '/api/accounts/${s.a}', as: 'ed')).status, 403);
    expect(
        (await h.call('POST', '/api/accounts/${s.a}/invites',
                as: 'ed', body: {'email': h.email('z')}))
            .status,
        403);

    // Shares list: the owner sees all + invites; others only their own.
    final own = await h.call('GET', '/api/accounts/${s.a}/shares', as: 'owner');
    expect((own.json['shares'] as List).map((x) => x['role']),
        containsAll(['editor', 'viewer']));
    expect(own.json['owner']['email'], h.email('owner'));
    expect(own.json.containsKey('invites'), isTrue);
    final m = await h.call('GET', '/api/accounts/${s.a}/shares', as: 'vi');
    expect((m.json['shares'] as List).single['email'], h.email('vi'));
    expect(m.json.containsKey('invites'), isFalse);

    // Change role, revoke, leave.
    final vid = await h.userId('vi');
    expect(
        (await h.call('PATCH', '/api/accounts/${s.a}/shares/$vid',
                as: 'owner', body: {'role': 'editor'}))
            .status,
        200);
    expect(
        (await h.call('POST', '/api/accounts/${s.a}/transactions',
                as: 'vi', body: Harness.tx('now ok')))
            .status,
        201);
    expect(
        (await h.call('DELETE', '/api/accounts/${s.a}/shares/$vid',
                as: 'owner'))
            .status,
        200);
    expect((await h.call('GET', '/api/accounts/${s.a}', as: 'vi')).status, 404);
    // Revoked: no longer offered as the landing account.
    expect(
        (await h.call('GET', '/api/accounts', as: 'vi')).json['lastAccountId'],
        isNull);
    expect(
        (await h.call('POST', '/api/accounts/${s.a}/leave', as: 'ed')).status,
        200);
    expect((await h.call('GET', '/api/accounts/${s.a}', as: 'ed')).status, 404);
    expect(
        (await h.call('POST', '/api/accounts/${s.a}/leave', as: 'owner'))
            .status,
        409);
    // The owner deletes it.
    expect(
        (await h.call('DELETE', '/api/accounts/${other.json['id']}',
                as: 'owner'))
            .status,
        204);
  });

  test('account names are unique per owner, not site-wide', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final a = await h.call('POST', '/api/accounts',
        as: 'n1', body: {'name': 'Everyday', 'seedDate': '2026-01-01'});
    expect(a.status, 201);
    expect(
        (await h.call('POST', '/api/accounts',
                as: 'n1', body: {'name': 'everyday', 'seedDate': '2026-01-01'}))
            .status,
        409);
    expect(
        (await h.call('POST', '/api/accounts',
                as: 'n2', body: {'name': 'Everyday', 'seedDate': '2026-01-01'}))
            .status,
        201);
    // Old clients' projectId is ignored.
    final legacy = await h.call('POST', '/api/accounts', as: 'n2', body: {
      'name': 'Legacy',
      'seedDate': '2026-01-01',
      'projectId': '00000000-0000-0000-0000-000000000000',
    });
    expect(legacy.status, 201);
    expect(legacy.json['ownerId'], await h.userId('n2'));
    expect(legacy.json.containsKey('projectId'), isFalse);
  });

  test('pending invite for a not-yet-user: link, preview, accept, auto-accept',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('own2', 'Invites');
    final inv = await h.call('POST', '/api/accounts/${s.a}/invites',
        as: 'own2', body: {'email': h.email('newbie'), 'role': 'editor'});
    expect(inv.status, 201);
    expect(inv.json['status'], 'invited');
    expect(inv.json['inviteUrl'], '$origin/invite/${inv.json['token']}');
    final shares =
        await h.call('GET', '/api/accounts/${s.a}/shares', as: 'own2');
    expect((shares.json['invites'] as List).single['email'], h.email('newbie'));

    // Rotating the link invalidates the old token.
    final rot =
        await h.call('POST', '/api/invites/${inv.json['id']}/link', as: 'own2');
    expect(rot.status, 200);
    final pre = await h.call('POST', '/api/invites/preview',
        as: 'other', body: {'token': rot.json['token']});
    expect(pre.json['invite']['accountName'], 'Acc Invites');
    expect(pre.json['invite'].containsKey('projectName'), isFalse);
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
        (await h.call('GET', '/api/accounts/${s.a}', as: 'newbie'))
            .json['role'],
        'editor');
    final nl = await h.call('GET', '/api/accounts', as: 'newbie');
    expect((nl.json['accounts'] as List).single['shared'], true);

    // Revoke before sign-in: no access.
    final i2 = await h.call('POST', '/api/accounts/${s.a}/invites',
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
        (await h.call('GET', '/api/accounts/${s.a}', as: 'late')).status, 404);
  });

  test('transfers across differently shared accounts do not leak names',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final mine = await h.seed('xa', 'Private Stuff');
    final shared = await h.seed('xa', 'Shared Stuff');
    await h.login('xb');
    await h.call('POST', '/api/accounts/${shared.a}/invites',
        as: 'xa', body: {'email': h.email('xb'), 'role': 'editor'});
    // Owner links Shared -> Private.
    final t = await h.call('POST', '/api/accounts/${shared.a}/transactions',
        as: 'xa', body: Harness.tx('Move', transferTo: mine.a));
    expect(t.status, 201, reason: '${t.json}');
    expect(t.json['transfer']['peerAccountName'], 'Acc Private Stuff');
    final seen =
        await h.call('GET', '/api/accounts/${shared.a}/transactions', as: 'xb');
    final link = (seen.json['transactions'] as List)
        .firstWhere((x) => x['id'] == t.json['id'])['transfer'];
    expect(link['peerReadable'], false);
    expect(link['peerAccountName'], isNull);
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
  });

  test('every mutation is audited', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final s = await h.seed('au', 'Audited');
    await h.call('PATCH', '/api/transactions/${s.t}',
        as: 'au', body: {'name': 'x'});
    await h.call('DELETE', '/api/transactions/${s.t}', as: 'au');
    final rows = await h.conn!
        .execute("SELECT action, entity_id, account_id::text FROM audit_log "
            "WHERE account_id = '${s.a}' ORDER BY id");
    expect(rows.map((r) => r[0]), [
      'account.created',
      'transaction.created',
      'transaction.updated',
      'transaction.deleted',
    ]);
    expect(rows[0][1], s.a);
    expect(rows[1][1], s.t);
    expect(rows[1][2], s.a);
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
    expect((await h.call('GET', '/api/accounts', as: 'victim')).status, 401);
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
