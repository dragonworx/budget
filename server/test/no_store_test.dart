import 'package:budget_server/api/router.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  final handler = const Pipeline()
      .addMiddleware(noStoreApi())
      .addHandler((Request r) => Response.ok('{}'));

  test('API responses (incl. after deletes) are never cacheable', () async {
    for (final path in [
      '/api/pools',
      '/api/pools/x/transactions',
      '/health'
    ]) {
      final res = await handler(Request('GET', Uri.parse('http://h$path')));
      expect(res.headers['cache-control'], contains('no-store'), reason: path);
      expect(res.headers['pragma'], 'no-cache');
    }
    final del =
        await handler(Request('DELETE', Uri.parse('http://h/api/pools/a')));
    expect(del.headers['cache-control'], contains('no-store'));
  });

  test('non-API paths are left alone', () async {
    final res =
        await handler(Request('GET', Uri.parse('http://h/main.dart.js')));
    expect(res.headers['cache-control'], isNull);
  });
}
