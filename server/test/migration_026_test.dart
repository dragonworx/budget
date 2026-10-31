// Migration 026 (loan events) on a scratch database at the 025 schema:
// new columns and defaults, each CHECK rejects bad rows, one loan per
// stream, existing rows untouched, the legacy-frequency trigger keeps
// 'once' for a loan, and re-running is a no-op. DB-backed
// (TEST_DATABASE_URL, default local budget_test); skipped without Postgres.
import 'dart:io';

import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

const _scratch = 'budget_mig026_test';
const _o = '00000000-0000-0000-0000-0000000026a1';
const _s1 = '00000000-0000-0000-0000-0000000026b1';
const _s2 = '00000000-0000-0000-0000-0000000026b2';

void main() {
  Connection? admin;
  Connection? db;
  late Directory old;
  final base = Uri.parse(Platform.environment['TEST_DATABASE_URL'] ??
      'postgres://budget:budget@127.0.0.1:5432/budget_test');

  setUpAll(() async {
    try {
      admin = await openConnection(
          Config(databaseUrl: base.toString(), host: '', port: 0));
      await admin!.execute('DROP DATABASE IF EXISTS $_scratch');
      await admin!.execute('CREATE DATABASE $_scratch');
      db = await openConnection(Config(
          databaseUrl: base.replace(path: '/$_scratch').toString(),
          host: '',
          port: 0));
    } catch (e) {
      // ignore: avoid_print
      print('migration_026_test: no test DB ($e)');
      admin = null;
      db = null;
      return;
    }
    old = Directory.systemTemp.createTempSync('mig025');
    for (final f in Directory('migrations').listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name.compareTo('026') < 0) f.copySync('${old.path}/$name');
    }
  });

  tearDownAll(() async {
    await db?.close();
    if (admin != null) {
      await admin!.execute('DROP DATABASE IF EXISTS $_scratch');
      await admin!.close();
      old.deleteSync(recursive: true);
    }
  });

  test('026 adds kind/loan with checks and one loan per stream', () async {
    if (db == null) return markTestSkipped('no test DB');
    final c = db!;
    await applyMigrations(c, migrationsDir: old.path);
    await c.execute("INSERT INTO users (id, email) VALUES ('$_o', 'l@x.io')");
    for (final s in [_s1, _s2]) {
      await c.execute("INSERT INTO streams (id, name, seed_balance, seed_date, "
          "owner_id) VALUES ('$s', 'S$s', 0, '2026-01-01', '$_o')");
    }
    var n = 0;
    Future<String> ev(String stream,
        {String extraCols = '',
        String extraVals = '',
        String mode = 'once',
        String direction = 'debit',
        String amount = '10'}) async {
      final id = '00000000-0000-0000-0000-${(++n).toString().padLeft(12, '0')}';
      await c.execute(
          'INSERT INTO events (id, stream_id, name, direction, amount, '
          'start_date, recurrence_mode, interval, unit, end_mode$extraCols) '
          "VALUES ('$id', '$stream', 'E$n', '$direction', $amount, "
          "'2026-01-01', '$mode', ${mode == 'once' ? 'NULL' : '1'}, "
          "${mode == 'once' ? 'NULL' : "'months'"}, 'never'$extraVals)");
      return id;
    }

    final before = await ev(_s1, mode: 'every');
    final beforeRow =
        (await c.execute("SELECT to_jsonb(e.*) - 'kind' - 'loan' FROM events e "
                "WHERE id = '$before'"))
            .first[0];

    await applyMigrations(c, migrationsDir: 'migrations');
    // Idempotent: the SQL runs again cleanly.
    await c.execute(File('migrations/026_loan_events.sql').readAsStringSync(),
        queryMode: QueryMode.simple);

    final cols = await c
        .execute("SELECT column_name, data_type, column_default, is_nullable "
            "FROM information_schema.columns WHERE table_name = 'events' "
            "AND column_name IN ('kind', 'loan') ORDER BY column_name");
    expect(cols.map((r) => [r[0], r[1], r[3]]).toList(), [
      ['kind', 'text', 'NO'],
      ['loan', 'jsonb', 'YES'],
    ]);
    expect(cols.first[2].toString(), contains("'standard'"));

    // Existing rows: standard, no loan, otherwise untouched.
    final row =
        (await c.execute("SELECT kind, loan FROM events WHERE id = '$before'"))
            .first;
    expect(row, ['standard', null]);
    expect(
        (await c.execute("SELECT to_jsonb(e.*) - 'kind' - 'loan' FROM events "
                "e WHERE id = '$before'"))
            .first[0],
        beforeRow);

    const loan = '\'{"v":1,"mode":"simple"}\'::jsonb';
    // A loan insert that only sets recurrence_mode = 'once': the legacy
    // trigger derives freq_rule 'once' and the rules accept it.
    final l1 =
        await ev(_s1, extraCols: ', kind, loan', extraVals: ", 'loan', $loan");
    expect(
        (await c.execute("SELECT freq_rule, kind FROM events WHERE id = '$l1'"))
            .first,
        ['once', 'loan']);

    Future<void> bad(Future<Object?> Function() f, String constraint) async {
      await expectLater(
          f,
          throwsA(isA<ServerException>().having(
              (e) => e.message + (e.constraintName ?? ''),
              'msg',
              contains(constraint))));
    }

    await bad(() => ev(_s2, extraCols: ', kind', extraVals: ", 'mortgage'"),
        'events_kind_check');
    await bad(() => ev(_s2, extraCols: ', kind', extraVals: ", 'loan'"),
        'events_loan_shape');
    await bad(() => ev(_s2, extraCols: ', loan', extraVals: ', $loan'),
        'events_loan_shape');
    await bad(
        () => ev(_s2,
            extraCols: ', kind, loan',
            extraVals: ", 'loan', $loan",
            mode: 'every'),
        'events_loan_rules');
    await bad(
        () => ev(_s2,
            extraCols: ', kind, loan',
            extraVals: ", 'loan', $loan",
            direction: 'credit'),
        'events_loan_rules');
    await bad(
        () => ev(_s2,
            extraCols: ', kind, loan',
            extraVals: ", 'loan', $loan",
            amount: '0'),
        'events_loan_rules');
    await bad(
        () => ev(_s2,
            extraCols: ', kind, loan',
            extraVals: ", 'loan', '{\"v\":2}'::jsonb"),
        'events_loan_rules');
    await bad(
        () => ev(_s2,
            extraCols: ', kind, loan, transfer_id',
            extraVals: ", 'loan', $loan, gen_random_uuid()"),
        'events_loan_rules');
    // One loan per stream; another stream may have its own.
    await bad(
        () => ev(_s1, extraCols: ', kind, loan', extraVals: ", 'loan', $loan"),
        'events_one_loan_per_stream');
    await ev(_s2, extraCols: ', kind, loan', extraVals: ", 'loan', $loan");
    // Turning the loan into a repeating rule is rejected too.
    await bad(
        () => c.execute("UPDATE events SET recurrence_mode = 'every', "
            "interval = 1, unit = 'months' WHERE id = '$l1'"),
        'events_loan_rules');
    expect(
        (await c.execute("SELECT count(*) FROM events WHERE kind = 'loan'"))
            .first[0],
        2);
  });
}
