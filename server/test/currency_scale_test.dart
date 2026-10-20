// DB-backed: runs against TEST_DATABASE_URL (default budget_test).
import 'dart:convert';
import 'dart:io';

import 'package:budget_server/api/pools.dart';
import 'package:budget_server/auth/middleware.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/domain/models.dart';
import 'package:budget_server/repo/pool_repo.dart';
import 'package:budget_server/repo/currency_scale_backfill.dart';
import 'package:budget_server/repo/user_repo.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart' hide Pool;
import 'package:shelf/shelf.dart';
import 'helpers.dart';
import 'package:test/test.dart';

void main() {
  test('parseCurrencyScale validates', () {
    expect(parseCurrencyScale({}), isNull);
    expect(parseCurrencyScale({'currencyScale': 1000}), 1000);
    expect(parseCurrencyScale({'currencyScale': '10'}), 10);
    expect(
        () => parseCurrencyScale({'currencyScale': 50}), throwsFormatException);
  });

  test('autoCurrencyScale fits the span in 9 units', () {
    expect(autoCurrencyScale(0), 1);
    expect(autoCurrencyScale(9), 1);
    expect(autoCurrencyScale(10), 10);
    expect(autoCurrencyScale(800), 100);
    expect(autoCurrencyScale(3500), 1000);
    expect(autoCurrencyScale(-42000), 10000);
    expect(autoCurrencyScale(5e9), 1000000);
  });

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

  test('currency scale defaults, persists and validates via API', () async {
    final c = conn;
    if (c == null) {
      markTestSkipped('no test database');
      return;
    }
    final owner = await testOwnerId(c, 'currency-scale-test@example.com');
    await deleteOwnedPools(c, owner);
    try {
      final pool = await PoolRepo(c).create(
        ownerId: owner,
        name: 'A',
        seedBalance: Decimal.zero,
        seedDate: DateTime.utc(2026, 10, 16),
        lossThreshold: Decimal.zero,
      );
      expect(pool.currencyScale, 100);
      expect(pool.toJson()['currencyScale'], 100);
      final api = buildPoolsApi(c);
      Future<Response> patch(Object v) => api.call(Request(
            'PATCH',
            Uri.parse('http://x/${pool.id}'),
            body: jsonEncode({'currencyScale': v}),
          ));
      final ok = await patch(1000);
      expect(ok.statusCode, 200);
      expect(jsonDecode(await ok.readAsString())['currencyScale'], 1000);
      expect((await PoolRepo(c).get(pool.id))!.currencyScale, 1000);
      expect((await patch(42)).statusCode, 400);
      // Other edits keep the scale.
      await api.call(Request('PATCH', Uri.parse('http://x/${pool.id}'),
          body: jsonEncode({'name': 'B'})));
      expect((await PoolRepo(c).get(pool.id))!.currencyScale, 1000);
    } finally {
      await deleteOwnedPools(c, owner);
    }
  });

  test(
      'backfill picks scale from projected balances; create defaults to '
      'Hundreds', () async {
    final c = conn;
    if (c == null) {
      markTestSkipped('no test database');
      return;
    }
    final owner = await testOwnerId(c, 'currency-backfill-test@example.com');
    await deleteOwnedPools(c, owner);
    try {
      final repo = PoolRepo(c);
      final a = await repo.create(
        ownerId: owner,
        name: 'A',
        seedBalance: Decimal.fromInt(3500),
        seedDate: DateTime.utc(2026, 10, 1),
        lossThreshold: Decimal.zero,
      );
      // Weekly +2000 income for a year pushes the peak past $100k.
      await c.execute(
        Sql.named('''
          INSERT INTO transactions (id, pool_id, name, direction, amount,
            start_date, recurrence_mode, interval, unit, end_mode)
          VALUES (gen_random_uuid(), @a, 'Pay', 'credit', 2000, '2026-10-02',
            'every', 1, 'weeks', 'never')
        '''),
        parameters: {'a': a.id},
      );
      final b = await repo.create(
        ownerId: owner,
        name: 'B',
        seedBalance: Decimal.fromInt(-650),
        seedDate: DateTime.utc(2026, 10, 1),
        lossThreshold: Decimal.zero,
      );
      await backfillCurrencyScales(c);
      expect((await repo.get(a.id))!.currencyScale, 100000);
      expect((await repo.get(b.id))!.currencyScale, 100);

      final api = buildPoolsApi(c);
      final user =
          (await UserRepo(c).byEmail('currency-backfill-test@example.com'))!;
      Future<Map<String, dynamic>> create(Map<String, Object?> body) async {
        final res = await api.call(Request('POST', Uri.parse('http://x/'),
            context: {'auth': AuthContext(user, 't')}, body: jsonEncode(
                // An older client's currency field is ignored, even invalid.
                {'currency': 'TOOLONG', 'seedDate': '2026-10-01', ...body})));
        expect(res.statusCode, 201);
        final json =
            jsonDecode(await res.readAsString()) as Map<String, dynamic>;
        expect(json.containsKey('currency'), isFalse);
        return json;
      }

      // No explicit scale: Hundreds, whatever the seed balance.
      expect(Pool.defaultCurrencyScale, 100);
      expect(
          (await create(
              {'name': 'C', 'seedBalance': '25000'}))['currencyScale'],
          100);
      expect((await create({'name': 'Z'}))['currencyScale'], 100);
      expect(
          (await create({
            'name': 'D',
            'seedBalance': '25000',
            'currencyScale': 10
          }))['currencyScale'],
          10);
    } finally {
      await deleteOwnedPools(c, owner);
    }
  });
}
