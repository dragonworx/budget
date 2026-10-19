// DB-backed: runs against TEST_DATABASE_URL (default budget_test).
import 'dart:convert';
import 'dart:io';

import 'package:budget_server/api/accounts.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/domain/models.dart';
import 'package:budget_server/api/projects.dart';
import 'package:budget_server/repo/account_repo.dart';
import 'package:budget_server/repo/currency_scale_backfill.dart';
import 'package:budget_server/repo/project_repo.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';
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
    final project = await ProjectRepo(c)
        .create('currency scale test', ownerId: await testOwnerId(c));
    try {
      final account = await AccountRepo(c).create(
        projectId: project.id,
        name: 'A',
        currency: 'AUD',
        seedBalance: Decimal.zero,
        seedDate: DateTime.utc(2026, 10, 16),
        lossThreshold: Decimal.zero,
      );
      expect(account.currencyScale, 100);
      expect(account.toJson()['currencyScale'], 100);
      final api = buildAccountsApi(c);
      Future<Response> patch(Object v) => api.call(Request(
            'PATCH',
            Uri.parse('http://x/${account.id}'),
            body: jsonEncode({'currencyScale': v}),
          ));
      final ok = await patch(1000);
      expect(ok.statusCode, 200);
      expect(jsonDecode(await ok.readAsString())['currencyScale'], 1000);
      expect((await AccountRepo(c).get(account.id))!.currencyScale, 1000);
      expect((await patch(42)).statusCode, 400);
      // Other edits keep the scale.
      await api.call(Request('PATCH', Uri.parse('http://x/${account.id}'),
          body: jsonEncode({'name': 'B'})));
      expect((await AccountRepo(c).get(account.id))!.currencyScale, 1000);
    } finally {
      await ProjectRepo(c).delete(project.id);
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
    final project = await ProjectRepo(c)
        .create('currency backfill test', ownerId: await testOwnerId(c));
    try {
      final repo = AccountRepo(c);
      final a = await repo.create(
        projectId: project.id,
        name: 'A',
        currency: 'AUD',
        seedBalance: Decimal.fromInt(3500),
        seedDate: DateTime.utc(2026, 10, 1),
        lossThreshold: Decimal.zero,
      );
      // Weekly +2000 income for a year pushes the peak past $100k.
      await c.execute(
        Sql.named('''
          INSERT INTO transactions (id, account_id, name, direction, amount,
            start_date, recurrence_mode, interval, unit, end_mode)
          VALUES (gen_random_uuid(), @a, 'Pay', 'credit', 2000, '2026-10-02',
            'every', 1, 'weeks', 'never')
        '''),
        parameters: {'a': a.id},
      );
      final b = await repo.create(
        projectId: project.id,
        name: 'B',
        currency: 'AUD',
        seedBalance: Decimal.fromInt(-650),
        seedDate: DateTime.utc(2026, 10, 1),
        lossThreshold: Decimal.zero,
      );
      await backfillCurrencyScales(c);
      expect((await repo.get(a.id))!.currencyScale, 100000);
      expect((await repo.get(b.id))!.currencyScale, 100);

      final api = buildProjectsApi(c);
      Future<Map<String, dynamic>> create(Map<String, Object?> body) async {
        final res = await api.call(Request(
            'POST', Uri.parse('http://x/${project.id}/accounts'),
            body: jsonEncode(
                {'currency': 'AUD', 'seedDate': '2026-10-01', ...body})));
        expect(res.statusCode, 201);
        return jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      }

      // No explicit scale: Hundreds, whatever the seed balance.
      expect(Account.defaultCurrencyScale, 100);
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
      await ProjectRepo(c).delete(project.id);
    }
  });
}
