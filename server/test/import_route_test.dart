// DB-backed: runs against TEST_DATABASE_URL (default: local budget_test DB,
// never the dev DB). Skipped when Postgres is unreachable.
import 'dart:convert';
import 'dart:io';

import 'package:budget_server/api/pools.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/repo/pool_repo.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  Connection? conn;
  setUpAll(() async {
    final url = Platform.environment['TEST_DATABASE_URL'] ??
        'postgres://budget:budget@127.0.0.1:5432/budget_test';
    try {
      conn = await openConnection(Config(databaseUrl: url, host: '', port: 0));
      await applyMigrations(conn!, migrationsDir: 'migrations');
    } catch (_) {
      conn = null;
    }
  });
  tearDownAll(() async => conn?.close());

  test('import resolves day offsets from ?root and requires it', () async {
    final c = conn;
    if (c == null) {
      markTestSkipped('no test database');
      return;
    }
    final owner = await testOwnerId(c);
    final pool = (await PoolRepo(c).create(
            ownerId: owner,
            name: 'Import offsets',
            seedBalance: Decimal.zero,
            seedDate: DateTime.utc(2026, 10, 1),
            lossThreshold: Decimal.zero))
        .id;
    try {
      final h = buildPoolsApi(c).call;
      Future<({int status, dynamic json})> post(String q, String body) async {
        final res = await h(Request(
            'POST', Uri.parse('http://x/$pool/transactions/import$q'),
            body: body));
        return (
          status: res.statusCode,
          json: jsonDecode(await res.readAsString())
        );
      }

      const paste = '''[
        {"name":"Bonus","direction":"credit","amount":"500","startOffset":0,
         "recurrence":{"mode":"once"}},
        {"name":"Phone","direction":"debit","amount":"40","startOffset":1,
         "recurrence":{"mode":"every","interval":1,"unit":"months"},
         "end":{"mode":"until_offset","endOffset":91},"skippedOffsets":[32]}
      ]''';
      final noRoot = await post('?dryRun=true', paste);
      expect(noRoot.status, 400);
      expect(noRoot.json['details'].single['field'], 'root');
      expect((await post('?root=2026-02-30', paste)).status, 400);

      final dry = await post('?dryRun=true&root=2026-12-31', paste);
      expect(dry.status, 200);
      final items = dry.json['items'] as List;
      expect(items[0]['startDate'], '2026-12-31');
      expect(items[1]['startDate'], '2027-01-01');
      expect(items[1]['endDate'], '2027-04-01');
      expect(items[1]['skippedDates'], ['2027-02-01']);

      final absolute = await post(
          '?root=2026-12-31',
          '[{"direction":"debit","amount":1,"startDate":"2026-12-31",'
              '"recurrence":{"mode":"once"}}]');
      expect(absolute.status, 400);
      expect(absolute.json['details'].single['text'],
          contains('[0].startDate: absolute dates are not accepted'));

      final done = await post('?root=2026-12-31', paste);
      expect(done.status, 201);
      expect(done.json['created'], 2);
      final rows = await c.execute(
          Sql.named('SELECT name, start_date, end_date FROM transactions '
              'WHERE pool_id = @p::uuid ORDER BY name'),
          parameters: {'p': pool});
      String day(Object? d) =>
          (d as DateTime).toIso8601String().substring(0, 10);
      expect(
          rows.map(
              (r) => '${r[0]} ${day(r[1])} ${r[2] == null ? '-' : day(r[2])}'),
          ['Bonus 2026-12-31 -', 'Phone 2027-01-01 2027-04-01']);
    } finally {
      await PoolRepo(c).delete(pool);
    }
  });
}
