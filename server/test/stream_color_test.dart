import 'package:test/test.dart';

import 'authz/harness.dart';

void main() {
  final h = Harness('streamcolor.authtest.example');
  setUpAll(() => h.open());
  tearDownAll(() => h.close());

  test('create assigns a distinct palette colour when none is sent', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final tag = DateTime.now().microsecondsSinceEpoch.toString();
    final a = await h.call('POST', '/api/streams', as: 'own', body: {
      'name': 'Color A $tag',
      'seedDate': '2026-01-01',
      'seedBalance': '0',
    });
    expect(a.status, 201, reason: '${a.json}');
    expect(a.json['color'], '#3D6FD8');

    final b = await h.call('POST', '/api/streams', as: 'own', body: {
      'name': 'Color B $tag',
      'seedDate': '2026-01-01',
    });
    expect(b.status, 201, reason: '${b.json}');
    expect(b.json['color'], isNot(a.json['color']));
    expect(b.json['color'], matches(r'^#[0-9A-F]{6}$'));
  });

  test('create stores a sent colour; patch updates it; list includes it',
      () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final tag = DateTime.now().microsecondsSinceEpoch.toString();
    final created = await h.call('POST', '/api/streams', as: 'own', body: {
      'name': 'Picked $tag',
      'seedDate': '2026-01-01',
      'color': '#b8488e',
    });
    expect(created.status, 201, reason: '${created.json}');
    expect(created.json['color'], '#B8488E');
    final id = created.json['id'] as String;

    final patched = await h.call('PATCH', '/api/streams/$id', as: 'own', body: {
      'color': '#5B7A2A',
    });
    expect(patched.status, 200, reason: '${patched.json}');
    expect(patched.json['color'], '#5B7A2A');

    final listed = await h.call('GET', '/api/streams', as: 'own');
    expect(listed.status, 200);
    final row = (listed.json['streams'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((s) => s['id'] == id);
    expect(row['color'], '#5B7A2A');
  });

  test('invalid colour is rejected', () async {
    if (!h.ok) return markTestSkipped('no test DB');
    final r = await h.call('POST', '/api/streams', as: 'own', body: {
      'name': 'Bad color',
      'seedDate': '2026-01-01',
      'color': 'red',
    });
    expect(r.status, 400);
  });
}
