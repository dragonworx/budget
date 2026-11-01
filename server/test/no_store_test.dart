import 'package:budget_server/api/router.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  final handler = const Pipeline()
      .addMiddleware(noStoreApi())
      .addHandler((Request r) => Response.ok('{}'));

  test('API responses (incl. after deletes) are never cacheable', () async {
    for (final path in ['/api/streams', '/api/streams/x/events', '/health']) {
      final res = await handler(Request('GET', Uri.parse('http://h$path')));
      expect(res.headers['cache-control'], contains('no-store'), reason: path);
      expect(res.headers['pragma'], 'no-cache');
      expect(res.headers['expires'], '0');
    }
    final del =
        await handler(Request('DELETE', Uri.parse('http://h/api/streams/a')));
    expect(del.headers['cache-control'], contains('no-store'));
  });

  test('API responses may be compressed by the proxy (no no-transform)',
      () async {
    final res = await handler(
        Request('GET', Uri.parse('http://h/api/streams/x/balance')));
    expect(res.headers['cache-control'],
        'no-store, no-cache, must-revalidate, max-age=0');
    expect(res.headers['cache-control'], isNot(contains('no-transform')));
  });

  test('the SSE stream keeps no-transform (never buffered by encode)',
      () async {
    final res = await handler(Request('GET', Uri.parse('http://h/api/live')));
    expect(res.headers['cache-control'], contains('no-store'));
    expect(res.headers['cache-control'], contains('no-transform'));
  });

  test('non-API paths are left alone', () async {
    final res =
        await handler(Request('GET', Uri.parse('http://h/main.dart.js')));
    expect(res.headers['cache-control'], isNull);
  });
}
