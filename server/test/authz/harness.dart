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

import '../auth/test_keys.dart';

const origin = 'https://dev.example.test';
const clientId = 'cid.apps.googleusercontent.com';

typedef Res = ({int status, dynamic json, Map<String, String> headers});

/// DB-backed API harness (TEST_DATABASE_URL, default local budget_test).
/// Users are `<name>@<domain>` and removed in [close].
class Harness {
  Harness(this.domain);
  final String domain;
  Connection? conn;
  late Handler h;
  final key = TestKey('kid-h');
  final _cookies = <String, String>{};

  bool get ok => conn != null;

  Future<void> open({List<String> admins = const []}) async {
    final url = Platform.environment['TEST_DATABASE_URL'] ??
        'postgres://budget:budget@127.0.0.1:5432/budget_test';
    try {
      conn = await openConnection(Config(databaseUrl: url, host: '', port: 0));
      await applyMigrations(conn!, migrationsDir: 'migrations');
      await _cleanup();
    } catch (e) {
      // ignore: avoid_print
      print('harness: no test DB ($e)');
      conn = null;
      return;
    }
    final config = Config(
      databaseUrl: '',
      host: '',
      port: 0,
      publicOrigin: origin,
      googleClientId: clientId,
      adminEmails: admins.isEmpty ? ['admin@$domain'] : admins,
      allowlist: ['@$domain'],
      sessionSecret: 'test-secret-test-secret-test-secret',
      rateLimitAuthPerMinute: 0, // many logins from one test IP
    );
    h = buildHandler(conn!, config,
        verifier: GoogleIdTokenVerifier(
            clientId: clientId,
            jwks: JwksCache(
                () async => (jwksJson([key]), const Duration(hours: 1)))));
  }

  Future<void> _cleanup() async {
    await conn!.execute(Sql.named('DELETE FROM invites WHERE email LIKE @d'),
        parameters: {'d': '%@$domain'});
    await conn!.execute(Sql.named('DELETE FROM users WHERE email LIKE @d'),
        parameters: {'d': '%@$domain'});
    await conn!.execute(
        Sql.named("DELETE FROM allowed_emails WHERE pattern LIKE @d"),
        parameters: {'d': '%$domain'});
  }

  Future<void> close() async {
    if (conn == null) return;
    await _cleanup();
    await conn!.close();
  }

  String email(String who) => '$who@$domain';

  Future<Res> call(String method, String path,
      {String? as,
      Object? body,
      Map<String, String> headers = const {}}) async {
    final res = await h(Request(method, Uri.parse('http://x$path'),
        body: body == null ? null : jsonEncode(body),
        headers: {
          'origin': origin,
          if (body != null) 'content-type': 'application/json',
          if (as != null) 'cookie': _cookies[as] ?? await login(as),
          ...headers,
        }));
    final text = await res.readAsString();
    Object? json;
    try {
      json = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {}
    return (status: res.statusCode, json: json, headers: res.headers);
  }

  Future<String> login(String who) async {
    final res = await h(Request('POST', Uri.parse('http://x/api/auth/google'),
        body: jsonEncode({
          'credential':
              key.sign(goodClaims(clientId, DateTime.now(), email: email(who)))
        }),
        headers: {'content-type': 'application/json', 'origin': origin}));
    expect(res.statusCode, 200, reason: await res.readAsString());
    return _cookies[who] = res.headers['set-cookie']!.split(';').first;
  }

  Future<String> userId(String who) async {
    final r = await call('GET', '/api/auth/me', as: who);
    return r.json['user']['id'] as String;
  }

  /// Project with one account and one transaction, owned by [who].
  Future<({String p, String a, String t})> seed(String who, String name) async {
    final p =
        await call('POST', '/api/projects', as: who, body: {'name': name});
    expect(p.status, 201, reason: '${p.json}');
    final a = await call('POST', '/api/projects/${p.json['id']}/accounts',
        as: who,
        body: {
          'name': 'Acc $name',
          'currency': 'AUD',
          'seedDate': '2026-01-01'
        });
    expect(a.status, 201, reason: '${a.json}');
    final t = await call('POST', '/api/accounts/${a.json['id']}/transactions',
        as: who, body: tx('Pay'));
    expect(t.status, 201, reason: '${t.json}');
    return (
      p: p.json['id'] as String,
      a: a.json['id'] as String,
      t: t.json['id'] as String
    );
  }

  static Map<String, Object?> tx(String name, {String? transferTo}) => {
        'name': name,
        'direction': 'debit',
        'amount': '10',
        'startDate': '2026-01-01',
        'recurrenceMode': 'once',
        'endMode': 'never',
        if (transferTo != null) 'transferToAccountId': transferTo,
      };
}
