// Two API server instances on one database: a change made through server A
// must reach an SSE subscriber on server B (via Postgres LISTEN/NOTIFY).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:budget_server/api/events.dart';
import 'package:budget_server/api/router.dart';
import 'package:budget_server/auth/google_verifier.dart';
import 'package:budget_server/auth/jwks_cache.dart';
import 'package:budget_server/auth/session_store.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/realtime/event_bus.dart';
import 'package:budget_server/realtime/pg_listener.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

import '../auth/test_keys.dart';

const domain = 'rt.authtest.example';
const origin = 'https://dev.example.test';
const clientId = 'cid.apps.googleusercontent.com';
final dbUrl = Platform.environment['TEST_DATABASE_URL'] ??
    'postgres://budget:budget@127.0.0.1:5432/budget_test';

class Instance {
  Instance(this.name);
  final String name;
  late Pool<void> pool;
  late EventBus bus;
  late PgListener listener;
  late SessionStore sessions;
  late HttpServer server;
  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> start(TestKey key, Config config) async {
    pool = openPool(config);
    bus = EventBus();
    sessions = SessionStore(pool,
        secret: config.sessionSecret, cacheTtl: const Duration(minutes: 5));
    listener = PgListener(() => openConnection(config), bus, extraChannels: {
      SessionStore.invalidationChannel: sessions.handleInvalidation,
    })
      ..start();
    await listener.ready.timeout(const Duration(seconds: 10));
    final handler = buildHandler(pool, config,
        bus: bus,
        sessions: sessions,
        eventsSettings: const EventsSettings(
            heartbeat: Duration(milliseconds: 300), maxReplay: 50),
        verifier: GoogleIdTokenVerifier(
            clientId: clientId,
            jwks: JwksCache(
                () async => (jwksJson([key]), const Duration(hours: 1)))));
    server = await shelf_io.serve(handler, '127.0.0.1', 0);
  }

  Future<void> stop() async {
    await listener.stop();
    await server.close(force: true);
    await pool.close();
    await bus.close();
  }
}

class Sse {
  Sse(this._client, this.response) {
    response
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_line, onError: (Object _) {}, onDone: () {
      if (!done.isCompleted) done.complete();
    });
  }
  final HttpClient _client;
  final HttpClientResponse response;
  final events = <({String event, int? id, Map<String, dynamic> data})>[];
  final _waiters = <(
    bool Function(Map<String, dynamic>, String),
    Completer<Map<String, dynamic>>
  )>[];
  final done = Completer<void>();
  String _event = 'message';
  int? _id;
  final _data = StringBuffer();

  void _line(String l) {
    if (l.isEmpty) {
      if (_data.isNotEmpty) {
        final d = jsonDecode(_data.toString()) as Map<String, dynamic>;
        events.add((event: _event, id: _id, data: d));
        for (final w in [..._waiters]) {
          if (w.$1(d, _event)) {
            _waiters.remove(w);
            w.$2.complete(d);
          }
        }
      }
      _event = 'message';
      _id = null;
      _data.clear();
    } else if (l.startsWith('event: ')) {
      _event = l.substring(7);
    } else if (l.startsWith('id: ')) {
      _id = int.parse(l.substring(4));
    } else if (l.startsWith('data: ')) {
      _data.write(l.substring(6));
    }
  }

  Future<Map<String, dynamic>> waitFor(
      bool Function(Map<String, dynamic> d, String event) test,
      {Duration timeout = const Duration(seconds: 8)}) {
    for (final e in events) {
      if (test(e.data, e.event)) return Future.value(e.data);
    }
    final c = Completer<Map<String, dynamic>>();
    _waiters.add((test, c));
    return c.future.timeout(timeout);
  }

  Future<Map<String, dynamic>> waitAction(String action, {String? entityId}) =>
      waitFor((d, e) =>
          e == 'change' &&
          d['action'] == action &&
          (entityId == null || d['entityId'] == entityId));

  bool has(String action, {String? entityId}) => events.any((e) =>
      e.event == 'change' &&
      e.data['action'] == action &&
      (entityId == null || e.data['entityId'] == entityId));

  void close() => _client.close(force: true);
}

void main() {
  final key = TestKey('rt');
  final a = Instance('A'), b = Instance('B');
  Connection? admin;
  final cookies = <String, String>{};

  setUpAll(() async {
    try {
      admin =
          await openConnection(Config(databaseUrl: dbUrl, host: '', port: 0));
      await applyMigrations(admin!, migrationsDir: 'migrations');
      await admin!.execute(Sql.named('DELETE FROM users WHERE email LIKE @d'),
          parameters: {'d': '%@$domain'});
    } catch (_) {
      admin = null;
      return;
    }
    final config = Config(
      databaseUrl: dbUrl,
      host: '',
      port: 0,
      publicOrigin: origin,
      googleClientId: clientId,
      allowlist: const ['@$domain'],
      sessionSecret: 'test-secret-test-secret-test-secret',
      rateLimitAuthPerMinute: 0, // many logins from one test IP
      dbPoolSize: 4,
    );
    await a.start(key, config);
    await b.start(key, config);
  });
  tearDownAll(() async {
    if (admin == null) return;
    await a.stop();
    await b.stop();
    await admin!.execute(Sql.named('DELETE FROM users WHERE email LIKE @d'),
        parameters: {'d': '%@$domain'});
    await admin!.close();
  });

  final http = HttpClient();
  Future<String> login(String who) async {
    final req = await http.postUrl(Uri.parse('${a.base}/api/auth/google'));
    req.headers.set('origin', origin);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'credential':
          key.sign(goodClaims(clientId, DateTime.now(), email: '$who@$domain'))
    }));
    final res = await req.close();
    await res.drain<void>();
    expect(res.statusCode, 200);
    return cookies[who] = res.cookies
        .firstWhere((c) => c.name == 'budget_session')
        .toString()
        .split(';')
        .first;
  }

  Future<({int status, dynamic json})> call(
      Instance i, String method, String path, String who,
      {Object? body, String? clientTag}) async {
    final req = await http.openUrl(method, Uri.parse('${i.base}$path'));
    req.headers.set('origin', origin);
    if (who.isNotEmpty) {
      req.headers.set('cookie', cookies[who] ?? await login(who));
    }
    if (clientTag != null) req.headers.set('x-client-id', clientTag);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    return (
      status: res.statusCode,
      json: text.isEmpty ? null : jsonDecode(text)
    );
  }

  Future<Sse> subscribe(Instance i, String who, {int? since}) async {
    final c = HttpClient();
    final req = await c.getUrl(Uri.parse('${i.base}/api/events'));
    req.headers.set('cookie', cookies[who] ?? await login(who));
    if (since != null) req.headers.set('last-event-id', '$since');
    final res = await req.close();
    expect(res.statusCode, 200);
    expect(res.headers.contentType?.mimeType, 'text/event-stream');
    final s = Sse(c, res);
    await s.waitFor((d, e) => e == 'ready' || e == 'resync');
    return s;
  }

  Future<String> userId(String who) async =>
      (await call(a, 'GET', '/api/auth/me', who)).json['user']['id'] as String;

  Map<String, Object?> tx(String n) => {
        'name': n,
        'direction': 'debit',
        'amount': '5',
        'startDate': '2026-01-01',
        'recurrenceMode': 'once',
        'endMode': 'never',
      };

  test('a change on A reaches a subscriber on B; outsiders get nothing',
      () async {
    if (admin == null) return markTestSkipped('no test DB');
    final ownerB = await subscribe(b, 'owner');
    final outsider = await subscribe(b, 'outsider');
    final acc = await call(a, 'POST', '/api/pools', 'owner',
        body: {'name': 'A1', 'seedDate': '2026-01-01'}, clientTag: 'tab-1');
    final aid = acc.json['id'] as String;
    final ev = await ownerB.waitAction('pool.created', entityId: aid);
    expect(ev.containsKey('projectId'), isFalse);
    expect(ev['poolId'], aid);
    expect(ev['clientId'], 'tab-1');
    expect(ev['actorId'], await userId('owner'));
    expect(ev['id'], isA<int>());
    final t = await call(a, 'POST', '/api/pools/$aid/transactions', 'owner',
        body: tx('x'));
    await ownerB.waitAction('transaction.created', entityId: t.json['id']);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(outsider.events.where((e) => e.event == 'change'), isEmpty);
    ownerB.close();
    outsider.close();
  });

  test('pool share grant, role change and revocation stop delivery',
      () async {
    if (admin == null) return markTestSkipped('no test DB');
    final acc = await call(a, 'POST', '/api/pools', 'own2',
        body: {'name': 'A', 'seedDate': '2026-01-01'});
    final aid = acc.json['id'] as String;
    await login('guest');
    final gid = await userId('guest');
    final guest = await subscribe(b, 'guest');
    await call(a, 'POST', '/api/pools/$aid/invites', 'own2',
        body: {'email': 'guest@$domain', 'role': 'viewer'});
    final added = await guest.waitAction('pool_share.added');
    expect(added['subjectUserId'], gid);
    final t1 = await call(a, 'POST', '/api/pools/$aid/transactions', 'own2',
        body: tx('seen'));
    await guest.waitAction('transaction.created', entityId: t1.json['id']);
    await call(a, 'PATCH', '/api/pools/$aid/shares/$gid', 'own2',
        body: {'role': 'editor'});
    final changed = await guest.waitAction('pool_share.changed');
    expect(changed['detail']['role'], 'editor');
    await call(a, 'DELETE', '/api/pools/$aid/shares/$gid', 'own2');
    await guest.waitAction('pool_share.revoked');
    final t2 = await call(a, 'POST', '/api/pools/$aid/transactions', 'own2',
        body: tx('hidden'));
    // Owner on A sees it; the revoked guest must not.
    final ownerA = await subscribe(a, 'own2', since: (added['id'] as int) - 1);
    await ownerA.waitAction('transaction.created', entityId: t2.json['id']);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(guest.has('transaction.created', entityId: t2.json['id']), isFalse);
    guest.close();
    ownerA.close();
  });

  test('catch-up via Last-Event-ID, resync when too far behind or ahead',
      () async {
    if (admin == null) return markTestSkipped('no test DB');
    final first = await subscribe(b, 'own3');
    final cursor = first.events.firstWhere((e) => e.event == 'ready').id!;
    first.close();
    final acc = await call(a, 'POST', '/api/pools', 'own3',
        body: {'name': 'Late', 'seedDate': '2026-01-01'});
    final again = await subscribe(b, 'own3', since: cursor);
    final ev =
        await again.waitAction('pool.created', entityId: acc.json['id']);
    expect(ev['id'], greaterThan(cursor));
    // Replay precedes 'ready'.
    final kinds = again.events.map((e) => e.event).toList();
    expect(kinds.indexOf('change'), lessThan(kinds.indexOf('ready')));
    again.close();

    final ahead = await subscribe(b, 'own3', since: 1 << 40);
    expect(ahead.events.first.event, 'resync');
    ahead.close();
    // More than maxReplay (50) missed events -> resync.
    final behind = await subscribe(b, 'own3', since: 0);
    final max =
        (await admin!.execute('SELECT max(id) FROM audit_log')).first[0] as int;
    if (max > 50) expect(behind.events.first.event, 'resync');
    behind.close();
  });

  test('failed mutations roll back their audit row; no event fires', () async {
    if (admin == null) return markTestSkipped('no test DB');
    final acc = await call(a, 'POST', '/api/pools', 'own4',
        body: {'name': 'RT4', 'seedDate': '2026-01-01'});
    final aid = acc.json['id'] as String;
    final sub = await subscribe(b, 'own4');
    Future<Object?> count() async => (await admin!.execute(
            Sql.named('SELECT count(*) FROM audit_log '
                'WHERE user_id = (SELECT id FROM users WHERE email = @e)'),
            parameters: {'e': 'own4@$domain'}))
        .first[0];
    final before = await count();
    final conflict = await call(a, 'PATCH', '/api/pools/$aid', 'own4',
        body: {'name': 'nope', 'version': 999});
    expect(conflict.status, 409);
    final bad = await call(a, 'POST', '/api/pools', 'own4',
        body: {'name': 'x', 'seedDate': 'not-a-date'});
    expect(bad.status, 400);
    expect(await count(), before);
    final ok = await call(a, 'PATCH', '/api/pools/$aid', 'own4',
        body: {'name': 'RT4b'});
    final ev = await sub.waitAction('pool.updated', entityId: aid);
    expect(ev['detail']['version'], ok.json['version']);
    expect(sub.events.where((e) => e.event == 'change').length, 1);
    sub.close();
  });

  test('listener reconnect: events after a dropped LISTEN still arrive',
      () async {
    if (admin == null) return markTestSkipped('no test DB');
    final acc = await call(a, 'POST', '/api/pools', 'own5',
        body: {'name': 'RT5', 'seedDate': '2026-01-01'});
    final aid = acc.json['id'] as String;
    final sub = await subscribe(b, 'own5');
    await b.listener.dropConnection();
    // Written while B's listener is down; recovered by the gap catch-up.
    final r = await call(a, 'PATCH', '/api/pools/$aid', 'own5',
        body: {'name': 'RT5b'});
    expect(r.status, 200);
    await sub.waitAction('pool.updated', entityId: aid);
    sub.close();
  });

  test('shutdown: SSE clients get a reconnect event and the stream closes',
      () async {
    if (admin == null) return markTestSkipped('no test DB');
    final sub = await subscribe(b, 'restarter');
    b.bus.shutdown('server shutting down');
    final ev = await sub.waitFor((d, e) => e == 'reconnect');
    expect(ev['reason'], 'server shutting down');
    expect(ev['lastEventId'], isA<int>());
    await sub.done.future.timeout(const Duration(seconds: 3));
    sub.close();
  });

  test(
      'logout on A ends the stream on B (session cache invalidated via NOTIFY)',
      () async {
    if (admin == null) return markTestSkipped('no test DB');
    final sub = await subscribe(b, 'leaver');
    await call(a, 'POST', '/api/auth/logout', 'leaver');
    final bye = await sub.waitFor((d, e) => e == 'goodbye');
    expect(bye['reason'], 'session ended');
    await sub.done.future.timeout(const Duration(seconds: 3));
    sub.close();
  });
}
