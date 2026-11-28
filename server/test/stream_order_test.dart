// Per-user home-list order: PATCH /api/streams/reorder, list order,
// independent viewer order, and prune on delete / revoked share.
import 'package:test/test.dart';

import 'authz/harness.dart';

List<String> _ids(Res r) =>
    (r.json['streams'] as List).map((s) => s['id'] as String).toList();

void main() {
  final h = Harness('streamorder.authtest.example');
  setUpAll(() => h.open());
  tearDownAll(() => h.close());

  test('list follows create order; reorder persists for that user only',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final tag = DateTime.now().microsecondsSinceEpoch.toString();
    Future<String> create(String who, String name) async {
      final r = await h.call('POST', '/api/streams', as: who, body: {
        'name': '$name $tag',
        'seedDate': '2026-01-01',
        'seedBalance': '0',
      });
      expect(r.status, 201, reason: '${r.json}');
      return r.json['id'] as String;
    }

    final a = await create('own', 'Alpha');
    final b = await create('own', 'Beta');
    final c = await create('own', 'Gamma');

    final listed = await h.call('GET', '/api/streams', as: 'own');
    expect(listed.status, 200);
    expect(_ids(listed), [a, b, c]);

    final reordered =
        await h.call('PATCH', '/api/streams/reorder', as: 'own', body: {
      'ids': [c, a, b],
    });
    expect(reordered.status, 200, reason: '${reordered.json}');
    expect(_ids(reordered), [c, a, b]);

    final again = await h.call('GET', '/api/streams', as: 'own');
    expect(_ids(again), [c, a, b]);

    // A shared stream can be placed anywhere in the viewer's list
    // without changing the owner's order.
    await h.login('vi');
    final vOwn = await create('vi', 'Viewer own');
    final inv = await h.call('POST', '/api/streams/$b/invites',
        as: 'own', body: {'email': h.email('vi'), 'role': 'viewer'});
    expect(inv.status, 201, reason: '${inv.json}');

    final vList = await h.call('GET', '/api/streams', as: 'vi');
    expect(_ids(vList), [vOwn, b]);
    expect(
        (vList.json['streams'] as List)
            .firstWhere((s) => s['id'] == b)['shared'],
        isTrue);

    final vReorder =
        await h.call('PATCH', '/api/streams/reorder', as: 'vi', body: {
      'ids': [b, vOwn],
    });
    expect(vReorder.status, 200, reason: '${vReorder.json}');
    expect(_ids(vReorder), [b, vOwn]);
    expect(_ids(await h.call('GET', '/api/streams', as: 'own')), [c, a, b]);

    // Missing ids are appended in current order; unknown / bad ids 400.
    final partial =
        await h.call('PATCH', '/api/streams/reorder', as: 'own', body: {
      'ids': [a],
    });
    expect(partial.status, 200, reason: '${partial.json}');
    expect(_ids(partial), [a, c, b]);

    expect(
        (await h.call('PATCH', '/api/streams/reorder', as: 'own', body: {
          'ids': [a, a],
        }))
            .status,
        400);
    expect(
        (await h.call('PATCH', '/api/streams/reorder', as: 'own', body: {
          'ids': ['not-a-uuid'],
        }))
            .status,
        400);
    expect(
        (await h.call('PATCH', '/api/streams/reorder', as: 'own', body: {
          'ids': ['00000000-0000-0000-0000-000000000036'],
        }))
            .status,
        400);
    expect(
        (await h.call('PATCH', '/api/streams/reorder', as: 'own', body: {
          'ids': 'nope',
        }))
            .status,
        400);
    // The viewer cannot put the owner's unshared stream in their order.
    expect(
        (await h.call('PATCH', '/api/streams/reorder', as: 'vi', body: {
          'ids': [a, b],
        }))
            .status,
        400);
  });

  test('delete and revoked share drop the id from the user order', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final tag = DateTime.now().microsecondsSinceEpoch.toString();
    Future<String> create(String who, String name) async {
      final r = await h.call('POST', '/api/streams', as: who, body: {
        'name': '$name $tag',
        'seedDate': '2026-01-01',
      });
      expect(r.status, 201, reason: '${r.json}');
      return r.json['id'] as String;
    }

    final keep = await create('own2', 'Keep');
    final gone = await create('own2', 'Gone');
    await h.login('ed');
    final inv = await h.call('POST', '/api/streams/$gone/invites',
        as: 'own2', body: {'email': h.email('ed'), 'role': 'editor'});
    expect(inv.status, 201, reason: '${inv.json}');
    expect(_ids(await h.call('GET', '/api/streams', as: 'ed')), [gone]);

    final shares = await h.call('GET', '/api/streams/$gone/shares', as: 'own2');
    expect(shares.status, 200, reason: '${shares.json}');
    final eid = (shares.json['shares'] as List)
        .firstWhere((s) => s['email'] == h.email('ed'))['userId'] as String;
    expect(
        (await h.call('DELETE', '/api/streams/$gone/shares/$eid', as: 'own2'))
            .status,
        200);
    expect(_ids(await h.call('GET', '/api/streams', as: 'ed')), isEmpty);

    // Re-share, then delete the stream: pruned for both.
    final inv2 = await h.call('POST', '/api/streams/$gone/invites',
        as: 'own2', body: {'email': h.email('ed'), 'role': 'editor'});
    expect(inv2.status, 201, reason: '${inv2.json}');
    expect(
        (await h.call('DELETE', '/api/streams/$gone', as: 'own2')).status, 200);
    expect(_ids(await h.call('GET', '/api/streams', as: 'own2')), [keep]);
    expect(_ids(await h.call('GET', '/api/streams', as: 'ed')), isEmpty);
  });
}
