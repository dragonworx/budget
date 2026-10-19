// DB-backed end-to-end auth + ownership tests through buildHandler, against
// TEST_DATABASE_URL (default local budget_test). Skipped if Postgres is down.
import 'dart:convert';
import 'dart:io';

import 'package:budget_server/api/router.dart';
import 'package:budget_server/auth/google_verifier.dart';
import 'package:budget_server/auth/jwks_cache.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'test_keys.dart';

const origin = 'https://dev.example.test';
const clientId = 'cid.apps.googleusercontent.com';

void main() {
  Connection? conn;
  final key = TestKey('kid-1');
  setUpAll(() async {
    final url = Platform.environment['TEST_DATABASE_URL'] ??
        'postgres://budget:budget@127.0.0.1:5432/budget_test';
    try {
      conn = await openConnection(Config(databaseUrl: url, host: '', port: 0));
      await applyMigrations(conn!, migrationsDir: 'migrations');
      await conn!
          .execute("DELETE FROM users WHERE email LIKE '%@authtest.example'");
    } catch (_) {
      conn = null;
    }
  });
  tearDownAll(() async {
    await conn
        ?.execute("DELETE FROM users WHERE email LIKE '%@authtest.example'");
    await conn?.close();
  });

  Handler handler({bool devBypass = false, List<String> allow = const []}) {
    final config = Config(
      databaseUrl: '',
      host: '',
      port: 0,
      publicOrigin: origin,
      googleClientId: clientId,
      adminEmails: const ['admin@authtest.example'],
      allowlist: allow,
      devBypass: devBypass,
      sessionSecret: 'test-secret-test-secret-test-secret',
    );
    return buildHandler(conn!, config,
        verifier: GoogleIdTokenVerifier(
            clientId: clientId,
            jwks: JwksCache(
                () async => (jwksJson([key]), const Duration(hours: 1)))));
  }

  Future<({int status, dynamic json, Map<String, String> headers})> call(
      Handler h, String method, String path,
      {Object? body,
      String? cookie,
      Map<String, String> headers = const {}}) async {
    final res = await h(Request(method, Uri.parse('http://x$path'),
        body: body == null ? null : jsonEncode(body),
        headers: {
          if (body != null) 'content-type': 'application/json',
          if (cookie != null) 'cookie': cookie,
          ...headers,
        }));
    final text = await res.readAsString();
    Object? json;
    try {
      json = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {}
    return (status: res.statusCode, json: json, headers: res.headers);
  }

  String cookieOf(Map<String, String> h) => h['set-cookie']!.split(';').first;

  Future<String> googleLogin(Handler h, String email) async {
    final r = await call(h, 'POST', '/api/auth/google', body: {
      'credential': key.sign(goodClaims(clientId, DateTime.now(), email: email))
    });
    expect(r.status, 200, reason: '${r.json}');
    return cookieOf(r.headers);
  }

  test('unauthenticated API calls get 401; health and auth config are public',
      () async {
    if (conn == null) return markTestSkipped('no test DB');
    final h = handler();
    expect((await call(h, 'GET', '/api/projects')).status, 401);
    expect((await call(h, 'GET', '/health')).status, 200);
    final cfg = await call(h, 'GET', '/api/auth/config');
    expect(cfg.json,
        {'googleClientId': clientId, 'devBypass': false, 'user': null});
    expect((await call(h, 'GET', '/api/auth/me')).status, 401);
  });

  test('dev-login only exists when AUTH_DEV_BYPASS is on', () async {
    if (conn == null) return markTestSkipped('no test DB');
    expect(
        (await call(handler(), 'POST', '/api/auth/dev-login',
                headers: {'origin': origin}))
            .status,
        404);
    final h = handler(devBypass: true);
    final r = await call(h, 'POST', '/api/auth/dev-login',
        headers: {'origin': origin});
    expect(r.status, 200);
    expect(r.json['user']['email'], 'admin@authtest.example');
    expect(r.json['user']['isAdmin'], true);
    final sc = r.headers['set-cookie']!;
    expect(sc, contains('HttpOnly'));
    expect(sc, contains('SameSite=Lax'));
    expect(sc, contains('Secure'));
    final me =
        await call(h, 'GET', '/api/auth/me', cookie: cookieOf(r.headers));
    expect(me.json['user']['email'], 'admin@authtest.example');
    final g = await call(h, 'GET', '/api/auth/dev-login?redirect=/p/1');
    expect(g.status, 302);
    expect(g.headers['location'], '/p/1');
    final evil =
        await call(h, 'GET', '/api/auth/dev-login?redirect=//evil.com');
    expect(evil.headers['location'], '/');
  });

  test('Google sign-in: allowlist, admin, invalid token, logout', () async {
    if (conn == null) return markTestSkipped('no test DB');
    final h = handler(allow: ['@ok.authtest.example']);
    final bad = await call(h, 'POST', '/api/auth/google',
        body: {'credential': 'not.a.token'});
    expect(bad.status, 401);
    final denied = await call(h, 'POST', '/api/auth/google', body: {
      'credential': key.sign(
          goodClaims(clientId, DateTime.now(), email: 'x@authtest.example'))
    });
    expect(denied.status, 403);
    final admin = await googleLogin(h, 'Admin@authtest.example');
    final me = await call(h, 'GET', '/api/auth/me', cookie: admin);
    expect(me.json['user']['isAdmin'], true);
    expect(me.json['user']['name'], 'Test Person');
    final c = await googleLogin(h, 'u@ok.authtest.example');
    expect((await call(h, 'GET', '/api/projects', cookie: c)).status, 200);
    final out = await call(h, 'POST', '/api/auth/logout',
        cookie: c, headers: {'origin': origin});
    expect(out.headers['set-cookie'], contains('Max-Age=0'));
    expect((await call(h, 'GET', '/api/projects', cookie: c)).status, 401);
    // Bearer works with the same token.
    final b = await googleLogin(h, 'b@ok.authtest.example');
    final tok = b.split('=').last;
    expect(
        (await call(h, 'GET', '/api/projects',
                headers: {'authorization': 'Bearer $tok'}))
            .status,
        200);
  });

  test('every resource is scoped to its owner (404 for others)', () async {
    if (conn == null) return markTestSkipped('no test DB');
    final h = handler(allow: ['@authtest.example']);
    final alice = await googleLogin(h, 'alice@authtest.example');
    final bob = await googleLogin(h, 'bob@authtest.example');
    final p = await call(h, 'POST', '/api/projects',
        cookie: alice, body: {'name': 'Alice P'});
    expect(p.status, 201);
    final pid = p.json['id'];
    // Same name for another owner is fine now.
    expect(
        (await call(h, 'POST', '/api/projects',
                cookie: bob, body: {'name': 'Alice P'}))
            .status,
        201);
    final a = await call(h, 'POST', '/api/projects/$pid/accounts',
        cookie: alice,
        body: {'name': 'Acc', 'currency': 'AUD', 'seedDate': '2026-01-01'});
    expect(a.status, 201, reason: '${a.json}');
    final aid = a.json['id'];
    final t = await call(h, 'POST', '/api/accounts/$aid/transactions',
        cookie: alice,
        body: {
          'name': 'Pay',
          'direction': 'credit',
          'amount': '10',
          'startDate': '2026-01-01',
          'recurrenceMode': 'once',
          'endMode': 'never'
        });
    expect(t.status, 201, reason: '${t.json}');
    final tid = t.json['id'];

    final bobList = await call(h, 'GET', '/api/projects', cookie: bob);
    expect((bobList.json['projects'] as List).map((x) => x['id']),
        isNot(contains(pid)));
    for (final (m, path) in [
      ('GET', '/api/projects/$pid'),
      ('GET', '/api/projects/$pid/accounts'),
      ('PATCH', '/api/projects/$pid'),
      ('DELETE', '/api/projects/$pid'),
      ('GET', '/api/accounts/$aid'),
      ('GET', '/api/accounts/$aid/transactions'),
      ('GET', '/api/accounts/$aid/balance'),
      ('GET', '/api/accounts/$aid/insights'),
      ('GET', '/api/accounts/$aid/scenarios'),
      ('DELETE', '/api/accounts/$aid'),
      ('GET', '/api/transactions/$tid'),
      ('DELETE', '/api/transactions/$tid'),
      ('GET', '/api/accounts/not-a-uuid'),
    ]) {
      final r =
          await call(h, m, path, cookie: bob, headers: {'origin': origin});
      expect(r.status, 404, reason: '$m $path');
    }
    expect(
        (await call(h, 'GET', '/api/accounts/$aid/insights', cookie: alice))
            .status,
        200);

    // Transfers into someone else's account are refused.
    final bp = await call(h, 'POST', '/api/projects',
        cookie: bob, body: {'name': 'Bob P'});
    final ba = await call(h, 'POST', '/api/projects/${bp.json['id']}/accounts',
        cookie: bob,
        body: {'name': 'B', 'currency': 'AUD', 'seedDate': '2026-01-01'});
    final xfer = await call(
        h, 'POST', '/api/accounts/${ba.json['id']}/transactions',
        cookie: bob,
        body: {
          'name': 'Steal',
          'direction': 'debit',
          'amount': '10',
          'startDate': '2026-01-01',
          'recurrenceMode': 'once',
          'endMode': 'never',
          'transferToAccountId': aid
        });
    expect(xfer.status, 404);
  });

  test('CORS is limited to allowed origins; CSRF blocks foreign origins',
      () async {
    if (conn == null) return markTestSkipped('no test DB');
    final h = handler(devBypass: true);
    final ok =
        await call(h, 'OPTIONS', '/api/projects', headers: {'origin': origin});
    expect(ok.headers['access-control-allow-origin'], origin);
    expect(ok.headers['access-control-allow-credentials'], 'true');
    final no = await call(h, 'OPTIONS', '/api/projects',
        headers: {'origin': 'https://evil.example'});
    expect(no.headers['access-control-allow-origin'], isNull);
    final evil = await call(h, 'POST', '/api/auth/dev-login',
        headers: {'origin': 'https://evil.example'});
    expect(evil.status, 403);
    final noHeader = await call(h, 'POST', '/api/auth/logout');
    expect(noHeader.status, 403);
  });
}
