import 'dart:convert';
import 'dart:io';

import 'package:budget_server/api/router.dart';
import 'package:budget_server/auth/session_store.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/hardening/cleanup.dart';
import 'package:budget_server/hardening/client_ip.dart';
import 'package:budget_server/hardening/lifecycle.dart';
import 'package:budget_server/hardening/logging.dart';
import 'package:budget_server/hardening/rate_limit.dart';
import 'package:budget_server/repo/user_repo.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  group('client IP', () {
    final r = ClientIpResolver(['127.0.0.1', '::1', '172.16.0.0/12']);
    test('untrusted peer: XFF ignored (no spoofing)', () {
      expect(r.resolve('203.0.113.9', '1.2.3.4'), '203.0.113.9');
    });
    test('trusted proxy: right-most untrusted hop wins', () {
      expect(r.resolve('172.18.0.5', '1.2.3.4, 198.51.100.7'), '198.51.100.7');
      expect(
          r.resolve('172.18.0.5', '198.51.100.7, 172.18.0.9'), '198.51.100.7');
      expect(r.resolve('127.0.0.1', null), '127.0.0.1');
    });
    test('CIDR, IPv6 and IPv4-mapped addresses', () {
      expect(IpRange.parse('172.16.0.0/12').contains('172.31.255.1'), isTrue);
      expect(IpRange.parse('172.16.0.0/12').contains('172.32.0.1'), isFalse);
      expect(IpRange.parse('::1').contains('::1'), isTrue);
      expect(IpRange.parse('127.0.0.1').contains('::ffff:127.0.0.1'), isTrue);
      expect(IpRange.parse('fd00::/8').contains('fd12::1'), isTrue);
      expect(IpRange.parse('10.0.0.0/8').contains('garbage'), isFalse);
    });
  });

  group('rate limiting', () {
    test('token bucket refills over time', () {
      var now = DateTime(2026);
      final l = RateLimiter(3, clock: () => now);
      expect([l.take('k'), l.take('k'), l.take('k')], [null, null, null]);
      expect(l.take('k'), greaterThan(0));
      expect(l.take('other'), isNull);
      now = now.add(const Duration(seconds: 20));
      expect(l.take('k'), isNull);
      expect(RateLimiter(0).take('k'), isNull);
    });

    test('auth per IP, general per session, 429 with Retry-After', () async {
      final h = const Pipeline()
          .addMiddleware(
              requestLogging(Log((_) {}), ClientIpResolver(['127.0.0.1'])))
          .addMiddleware(rateLimitMiddleware(
              auth: RateLimiter(2), general: RateLimiter(3)))
          .addHandler((_) => Response.ok('ok'));
      Future<Response> get(String path, {String? ip, String? cookie}) async =>
          h(Request('GET', Uri.parse('http://x$path'), headers: {
            if (cookie != null) 'cookie': cookie
          }, context: {
            'shelf.io.connection_info': _Conn(ip ?? '203.0.113.1'),
          }));
      expect((await get('/api/auth/config')).statusCode, 200);
      expect((await get('/api/auth/config')).statusCode, 200);
      final limited = await get('/api/auth/config');
      expect(limited.statusCode, 429);
      expect(int.parse(limited.headers['retry-after']!), greaterThan(0));
      expect(
          (await get('/api/auth/config', ip: '203.0.113.2')).statusCode, 200);
      for (var i = 0; i < 3; i++) {
        expect(
            (await get('/api/projects', cookie: 'budget_session=aaa'))
                .statusCode,
            200);
      }
      expect(
          (await get('/api/projects', cookie: 'budget_session=aaa')).statusCode,
          429);
      expect(
          (await get('/api/projects', cookie: 'budget_session=bbb')).statusCode,
          200);
      // Non-API paths are never limited.
      expect((await get('/index.html')).statusCode, 200);
    });
  });

  group('DB-backed', () {
    Connection? conn;
    setUpAll(() async {
      final url = Platform.environment['TEST_DATABASE_URL'] ??
          'postgres://budget:budget@127.0.0.1:5432/budget_test';
      try {
        conn =
            await openConnection(Config(databaseUrl: url, host: '', port: 0));
        await applyMigrations(conn!, migrationsDir: 'migrations');
      } catch (_) {
        conn = null;
      }
    });
    tearDownAll(() async {
      await conn?.execute(
          "DELETE FROM users WHERE email LIKE '%@hard.authtest.example'");
      await conn?.close();
    });

    test('security headers, request id, structured logs without secrets',
        () async {
      if (conn == null) return markTestSkipped('no test DB');
      final lines = <String>[];
      final h = buildHandler(
          conn!,
          Config(
              databaseUrl: '',
              host: '',
              port: 0,
              publicOrigin: 'https://b.example',
              sessionSecret: 'x' * 40),
          log: Log(lines.add));
      final res = await h(Request(
          'GET', Uri.parse('http://x/api/projects?since=SECRET'),
          headers: {
            'cookie': 'budget_session=TOPSECRETTOKEN',
            'authorization': 'Bearer ALSOSECRET',
            'x-request-id': 'req-abc',
          }));
      expect(res.statusCode, 401);
      expect(res.headers['x-request-id'], 'req-abc');
      expect(res.headers['x-content-type-options'], 'nosniff');
      expect(res.headers['x-frame-options'], 'DENY');
      expect(res.headers['content-security-policy'],
          contains("default-src 'none'"));
      expect(res.headers['strict-transport-security'], contains('max-age'));
      final log = lines
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .firstWhere((m) => m['msg'] == 'request');
      expect(log['reqId'], 'req-abc');
      expect(log['path'], '/api/projects');
      expect(log['status'], 401);
      expect(log['ms'], isA<num>());
      final all = lines.join('\n');
      for (final secret in ['TOPSECRETTOKEN', 'ALSOSECRET', 'SECRET']) {
        expect(all, isNot(contains(secret)));
      }
      // Bogus incoming ids are replaced.
      final r2 = await h(Request('GET', Uri.parse('http://x/health'),
          headers: {'x-request-id': 'bad id\nwith newline'}));
      expect(r2.headers['x-request-id'], matches(RegExp(r'^[0-9a-f]{24}$')));
    });

    test('/ready: 200 when healthy, 503 when draining or listener down',
        () async {
      if (conn == null) return markTestSkipped('no test DB');
      final lc = Lifecycle();
      var listenerUp = true;
      final h = buildHandler(conn!, Config(databaseUrl: '', host: '', port: 0),
          log: Log((_) {}),
          lifecycle: lc,
          readiness: () async =>
              {'ok': listenerUp, 'db': true, 'listener': listenerUp});
      Future<Response> ready() async =>
          h(Request('GET', Uri.parse('http://x/ready')));
      expect((await ready()).statusCode, 200);
      listenerUp = false;
      expect((await ready()).statusCode, 503);
      listenerUp = true;
      lc.startDraining();
      final d = await ready();
      expect(d.statusCode, 503);
      expect(await d.readAsString(), contains('draining'));
      expect(await lc.waitIdle(const Duration(milliseconds: 10)), isTrue);
    });

    test('session cache hits, and logout/disable invalidate it', () async {
      if (conn == null) return markTestSkipped('no test DB');
      final store = SessionStore(conn!,
          secret: 's' * 40, cacheTtl: const Duration(minutes: 5));
      final u = await UserRepo(conn!)
          .ensure('c@hard.authtest.example', isAdmin: false);
      final t1 = await store.create(u.id);
      final t2 = await store.create(u.id);
      expect(await store.lookup(t1), isNotNull);
      expect(await store.lookup(t1), isNotNull);
      expect(store.cacheHits, 1);
      await store.delete(t1);
      expect(await store.lookup(t1), isNull);
      expect(await store.lookup(t2), isNotNull); // cached
      await store.deleteAllForUser(u.id);
      expect(await store.lookup(t2), isNull);
      // Remote invalidation payloads (from NOTIFY) are applied too.
      final t3 = await store.create(u.id);
      await store.lookup(t3);
      await conn!.execute(
          Sql.named('DELETE FROM sessions WHERE user_id = @u::uuid'),
          parameters: {'u': u.id});
      expect(await store.lookup(t3), isNotNull); // still cached
      store.handleInvalidation(jsonEncode({'userId': u.id}));
      expect(await store.lookup(t3), isNull);
    });

    test('cleanup deletes expired sessions and stale invites only', () async {
      if (conn == null) return markTestSkipped('no test DB');
      final u = await UserRepo(conn!)
          .ensure('cl@hard.authtest.example', isAdmin: false);
      final store = SessionStore(conn!, secret: 's' * 40);
      final live = await store.create(u.id);
      final dead = await store.create(u.id);
      await conn!.execute(
          Sql.named(
              "UPDATE sessions SET expires_at = now() - interval '1 day' WHERE id_hash = @h"),
          parameters: {'h': TypedValue(Type.byteArray, store.hash(dead))});
      final p = await conn!.execute(
          Sql.named(
              "INSERT INTO projects (id, name, owner_id) VALUES (gen_random_uuid(), 'cleanup', @u::uuid) RETURNING id::text"),
          parameters: {'u': u.id});
      Future<void> invite(String email, String expires,
              {bool accepted = false}) =>
          conn!.execute(Sql.named('''
            INSERT INTO invites (id, token_hash, email, project_id, role, invited_by, expires_at, accepted_at)
            VALUES (gen_random_uuid(), gen_random_uuid()::text::bytea, @e, @p::uuid, 'viewer', @u::uuid,
                    now() + @x::interval, CASE WHEN @acc THEN now() END)'''),
              parameters: {
                'e': email,
                'p': p.first[0],
                'u': u.id,
                'x': expires,
                'acc': accepted
              });
      await invite('old@hard.authtest.example', '-40 days');
      await invite('recent@hard.authtest.example', '-1 day');
      await invite('acc@hard.authtest.example', '-40 days', accepted: true);
      final job = CleanupJob(conn!, store, Log((_) {}));
      final r = await job.runOnce();
      expect(r, isNotNull);
      expect(r!.$1, greaterThanOrEqualTo(1));
      expect(await store.lookup(live), isNotNull);
      expect(await store.lookup(dead), isNull);
      final left = await conn!.execute(
          Sql.named(
              "SELECT email FROM invites WHERE project_id = @p::uuid ORDER BY email"),
          parameters: {'p': p.first[0]});
      expect(left.map((x) => x[0]),
          ['acc@hard.authtest.example', 'recent@hard.authtest.example']);
    });
  });
}

class _Conn implements HttpConnectionInfo {
  _Conn(String ip) : remoteAddress = InternetAddress(ip);
  @override
  final InternetAddress remoteAddress;
  @override
  int get localPort => 8080;
  @override
  int get remotePort => 5555;
}
