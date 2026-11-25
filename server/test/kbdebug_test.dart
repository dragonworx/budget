import 'dart:convert';
import 'dart:io';

import 'package:budget_server/api/kbdebug.dart';
import 'package:budget_server/hardening/logging.dart';
import 'package:budget_server/hardening/rate_limit.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late KbDebugStore store;
  late Handler h;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('kbdebug');
    store = KbDebugStore(File('${dir.path}/kbdebug.jsonl'));
    h = kbdebugHandler(
      log: Log((_) {}),
      store: store,
      limiter: RateLimiter(8),
    );
  });

  tearDown(() {
    store.clear();
    dir.deleteSync(recursive: true);
  });

  Future<Response> call(String method, {String? body, int? length}) async {
    return h(Request(
      method,
      Uri.parse('http://x/api/kbdebug'),
      body: body,
      headers: {
        'content-type': 'application/json',
        if (length != null) 'content-length': '$length',
      },
    ));
  }

  test('POST then GET round-trip, unauthenticated', () async {
    final res = await call('POST',
        body: jsonEncode({
          'build': '20261125000000',
          'kb': 'a',
          'log': 'prime via=touchend-capture||handoff',
        }));
    expect(res.statusCode, 200);
    final got = await call('GET');
    expect(got.statusCode, 200);
    final map = jsonDecode(await got.readAsString()) as Map;
    expect(map['ok'], isTrue);
    final entries = map['entries'] as List;
    expect(entries, hasLength(1));
    expect(entries.first['build'], '20261125000000');
    expect(entries.first['log'], contains('touchend-capture'));
  });

  test('rejects oversized and non-object bodies', () async {
    final huge = jsonEncode({'log': 'x' * (kbdebugMaxBody + 10)});
    expect((await call('POST', body: huge)).statusCode, 413);
    expect((await call('POST', body: '[]')).statusCode, 400);
    expect((await call('POST', body: 'not-json')).statusCode, 400);
  });

  test('POST clear empties the store', () async {
    await call('POST', body: jsonEncode({'build': '1', 'log': 'keep-me'}));
    expect(
        ((jsonDecode(await (await call('GET')).readAsString())
            as Map)['entries'] as List),
        hasLength(1));
    final cleared = await call('POST', body: jsonEncode({'clear': true}));
    expect(cleared.statusCode, 200);
    final map = jsonDecode(await cleared.readAsString()) as Map;
    expect(map['cleared'], isTrue);
    final got = jsonDecode(await (await call('GET')).readAsString()) as Map;
    expect(got['entries'], isEmpty);
  });

  test('rate-limits a chatty client', () async {
    h = kbdebugHandler(
      log: Log((_) {}),
      store: store,
      limiter: RateLimiter(2),
    );
    expect((await call('GET')).statusCode, 200);
    expect((await call('GET')).statusCode, 200);
    final limited = await call('GET');
    expect(limited.statusCode, 429);
    expect(limited.headers['retry-after'], isNotNull);
  });
}
