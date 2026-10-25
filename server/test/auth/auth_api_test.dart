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
      rateLimitAuthPerMinute: 0, // many logins from one test IP
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
    expect((await call(h, 'GET', '/api/streams')).status, 401);
    expect((await call(h, 'GET', '/health')).status, 200);
    final cfg = await call(h, 'GET', '/api/auth/config');
    expect(cfg.json, {
      'googleClientId': clientId,
      'googleUxMode': 'auto',
      'devBypass': false,
      'user': null,
    });
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
    expect((await call(h, 'GET', '/api/streams', cookie: c)).status, 200);
    final out = await call(h, 'POST', '/api/auth/logout',
        cookie: c, headers: {'origin': origin});
    expect(out.headers['set-cookie'], contains('Max-Age=0'));
    expect((await call(h, 'GET', '/api/streams', cookie: c)).status, 401);
    // Bearer works with the same token.
    final b = await googleLogin(h, 'b@ok.authtest.example');
    final tok = b.split('=').last;
    expect(
        (await call(h, 'GET', '/api/streams',
                headers: {'authorization': 'Bearer $tok'}))
            .status,
        200);
  });

  test('Admin-UI allowlist lets a brand-new user in (first login works)',
      () async {
    if (conn == null) return markTestSkipped('no test DB');
    await conn!.execute(
        "DELETE FROM allowed_emails WHERE pattern LIKE '%authtest.example'");
    final h = handler();
    final admin = await googleLogin(h, 'admin@authtest.example');
    Future<int> signIn(String email) async =>
        (await call(h, 'POST', '/api/auth/google', headers: {
          'origin': origin
        }, body: {
          'credential':
              key.sign(goodClaims(clientId, DateTime.now(), email: email))
        }))
            .status;
    expect(await signIn('wife@authtest.example'), 403);
    final add = await call(h, 'POST', '/api/admin/allowlist',
        cookie: admin,
        headers: {'origin': origin},
        body: {'pattern': '  Wife@AuthTest.example '});
    expect(add.status, 201, reason: '${add.json}');
    final r = await call(h, 'POST', '/api/auth/google', headers: {
      'origin': origin
    }, body: {
      'credential': key.sign(
          goodClaims(clientId, DateTime.now(), email: 'wife@authtest.example'))
    });
    expect(r.status, 200, reason: '${r.json}');
    expect(r.json['user']['isAdmin'], false);
    final c = cookieOf(r.headers);
    final streams = await call(h, 'GET', '/api/streams', cookie: c);
    expect(streams.status, 200);
    expect((await call(h, 'GET', '/api/auth/me', cookie: c)).status, 200);
    expect((await call(h, 'GET', '/api/invites/mine', cookie: c)).status,
        anyOf(200, 404));
    await conn!.execute(
        "DELETE FROM allowed_emails WHERE pattern LIKE '%authtest.example'");
  });

  test('GIS redirect login_uri: session + 303 into the app; errors visible',
      () async {
    if (conn == null) return markTestSkipped('no test DB');
    final h = handler(allow: ['@ok.authtest.example']);
    Future<({int status, dynamic json, Map<String, String> headers})> post(
        String email,
        {String csrf = 'tok123',
        String? cookieCsrf = 'tok123',
        String? origin = 'https://accounts.google.com'}) async {
      final cred = key.sign(goodClaims(clientId, DateTime.now(), email: email));
      final res = await h(Request(
          'POST', Uri.parse('http://x/api/auth/google/redirect'),
          body: 'credential=$cred&g_csrf_token=$csrf',
          headers: {
            'content-type': 'application/x-www-form-urlencoded',
            if (origin != null) 'origin': origin,
            if (cookieCsrf != null) 'cookie': 'g_csrf_token=$cookieCsrf',
          }));
      return (status: res.statusCode, json: null, headers: res.headers);
    }

    final ok = await post('r@ok.authtest.example');
    expect(ok.status, 303);
    expect(ok.headers['location'], '/#/');
    final c = cookieOf(ok.headers);
    expect((await call(h, 'GET', '/api/auth/me', cookie: c)).status, 200);

    final denied = await post('nope@authtest.example');
    expect(denied.status, 303);
    final loc = Uri.parse(denied.headers['location']!.replaceFirst('/#', ''));
    expect(loc.path, '/sign-in');
    expect(loc.queryParameters['error'], contains('nope@authtest.example'));
    expect(denied.headers['set-cookie'], isNull);

    final mismatch = await post('r@ok.authtest.example', cookieCsrf: 'other');
    expect(mismatch.headers['location'], contains('error='));
    expect(mismatch.headers['set-cookie'], isNull);
    // No cookie: only accepted straight from Google.
    final forged = await post('r@ok.authtest.example',
        cookieCsrf: null, origin: 'https://evil.example');
    expect(forged.headers['location'], contains('error='));
    final noCookie = await post('r@ok.authtest.example', cookieCsrf: null);
    expect(noCookie.headers['location'], '/#/');
  });

  test('every resource is scoped to its owner (404 for others)', () async {
    if (conn == null) return markTestSkipped('no test DB');
    final h = handler(allow: ['@authtest.example']);
    final alice = await googleLogin(h, 'alice@authtest.example');
    final bob = await googleLogin(h, 'bob@authtest.example');
    final a = await call(h, 'POST', '/api/streams',
        cookie: alice, body: {'name': 'Acc', 'seedDate': '2026-01-01'});
    expect(a.status, 201, reason: '${a.json}');
    final aid = a.json['id'];
    final t =
        await call(h, 'POST', '/api/streams/$aid/events', cookie: alice, body: {
      'name': 'Pay',
      'direction': 'credit',
      'amount': '10',
      'startDate': '2026-01-01',
      'recurrenceMode': 'once',
      'endMode': 'never'
    });
    expect(t.status, 201, reason: '${t.json}');
    final tid = t.json['id'];

    final bobList = await call(h, 'GET', '/api/streams', cookie: bob);
    expect((bobList.json['streams'] as List).map((x) => x['id']),
        isNot(contains(aid)));
    for (final (m, path) in [
      ('GET', '/api/streams/$aid'),
      ('PATCH', '/api/streams/$aid'),
      ('GET', '/api/streams/$aid/events'),
      ('GET', '/api/streams/$aid/balance'),
      ('GET', '/api/streams/$aid/insights'),
      ('GET', '/api/streams/$aid/scenarios'),
      ('DELETE', '/api/streams/$aid'),
      ('GET', '/api/events/$tid'),
      ('DELETE', '/api/events/$tid'),
      ('GET', '/api/streams/not-a-uuid'),
    ]) {
      final r =
          await call(h, m, path, cookie: bob, headers: {'origin': origin});
      expect(r.status, 404, reason: '$m $path');
    }
    expect(
        (await call(h, 'GET', '/api/streams/$aid/insights', cookie: alice))
            .status,
        200);

    // Transfers into someone else's stream are refused.
    final ba = await call(h, 'POST', '/api/streams',
        cookie: bob, body: {'name': 'B', 'seedDate': '2026-01-01'});
    final xfer = await call(h, 'POST', '/api/streams/${ba.json['id']}/events',
        cookie: bob,
        body: {
          'name': 'Steal',
          'direction': 'debit',
          'amount': '10',
          'startDate': '2026-01-01',
          'recurrenceMode': 'once',
          'endMode': 'never',
          'transferToStreamId': aid
        });
    expect(xfer.status, 404);
  });

  test('CORS is limited to allowed origins; CSRF blocks foreign origins',
      () async {
    if (conn == null) return markTestSkipped('no test DB');
    final h = handler(devBypass: true);
    final ok =
        await call(h, 'OPTIONS', '/api/streams', headers: {'origin': origin});
    expect(ok.headers['access-control-allow-origin'], origin);
    expect(ok.headers['access-control-allow-credentials'], 'true');
    final no = await call(h, 'OPTIONS', '/api/streams',
        headers: {'origin': 'https://evil.example'});
    expect(no.headers['access-control-allow-origin'], isNull);
    final evil = await call(h, 'POST', '/api/auth/dev-login',
        headers: {'origin': 'https://evil.example'});
    expect(evil.status, 403);
    final noHeader = await call(h, 'POST', '/api/auth/logout');
    expect(noHeader.status, 403);
  });
}
