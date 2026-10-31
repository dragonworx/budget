// DB-backed: prints the non-loan /balance p95 (7 events, 20 years). Tagged
// perf; skipped when Postgres is unreachable.
@Tags(['perf'])
library;

import 'dart:io';

import 'package:budget_server/api/streams.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/repo/user_repo.dart';
import 'package:postgres/postgres.dart' hide Pool;
import 'package:test/test.dart';

import 'helpers.dart';
import 'perf_nonloan.dart';

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

  test('non-loan 7-event 20-year /balance p95', () async {
    final c = conn;
    if (c == null) return markTestSkipped('no test database');
    const email = 'perf-nonloan-test@example.com';
    final owner = await testOwnerId(c, email);
    final user = (await UserRepo(c).byEmail(email))!;
    try {
      final ms =
          await nonLoanBalanceP95(c, owner, user, buildStreamsApi(c).call);
      print('perf p95: non-loan 7-event 20y /balance ${ms}ms');
    } finally {
      await deleteOwnedStreams(c, owner);
    }
  });
}
