// Migration 030 (sync events, spec 015) on a scratch database at the 029
// schema: the kind check gains 'sync', the anonymous `amount >= 0` check is
// replaced by `events_amount_nonneg` (a negative amount only on a sync),
// `events_sync_rules` rejects a sync transfer / repeat / loan / end, the
// partial index exists, existing rows are untouched, and re-running is a
// no-op. DB-backed (TEST_DATABASE_URL, default local budget_test);
// skipped without Postgres.
import 'dart:io';

import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

const _scratch = 'budget_mig030_test';
const _o = '00000000-0000-0000-0000-0000000030a1';
const _s1 = '00000000-0000-0000-0000-0000000030b1';
const _s2 = '00000000-0000-0000-0000-0000000030b2';

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
      print('migration_030_test: no test DB ($e)');
      admin = null;
      db = null;
      return;
    }
    old = Directory.systemTemp.createTempSync('mig029');
    for (final f in Directory('migrations').listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name.compareTo('030') < 0) f.copySync('${old.path}/$name');
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

  Future<List<String>> checks(Connection c) async => [
        for (final r in await c
            .execute("SELECT pg_get_constraintdef(oid) FROM pg_constraint "
                "WHERE conrelid = 'events'::regclass AND contype = 'c' "
                "AND pg_get_constraintdef(oid) ~ 'amount >= '"))
          r[0] as String
      ];

  test('030 allows signed sync rows with their rules', () async {
    if (db == null) return markTestSkipped('no test DB');
    final c = db!;
    await applyMigrations(c, migrationsDir: old.path);
    // Before: the anonymous amount check (whatever its name).
    expect((await checks(c)).single, 'CHECK ((amount >= (0)::numeric))');
    await c.execute("INSERT INTO users (id, email) VALUES ('$_o', 'o@x.io')");
    for (final s in [_s1, _s2]) {
      await c.execute("INSERT INTO streams (id, name, seed_balance, seed_date, "
          "owner_id) VALUES ('$s', 'S$s', 0, '2026-01-01', '$_o')");
    }
    var n = 0;
    Future<String> ev(
        {String stream = _s1,
        String kind = 'standard',
        String amount = '10',
        String direction = 'debit',
        String extraCols = '',
        String extraVals = '',
        String mode = "'once', NULL, NULL"}) async {
      final id = '00000000-0000-0000-0000-${(++n).toString().padLeft(12, '0')}';
      await c.execute(
          'INSERT INTO events (id, stream_id, name, direction, amount, '
          'start_date, recurrence_mode, interval, unit, end_mode, kind'
          '$extraCols) '
          "VALUES ('$id', '$stream', 'E$n', '$direction', $amount, "
          "'2026-01-01', $mode, 'never', '$kind'$extraVals)");
      return id;
    }

    final std = await ev();
    final loan = await ev(
        stream: _s2,
        kind: 'loan',
        extraCols: ', loan',
        extraVals: ", '{\"v\":1,\"mode\":\"simple\"}'::jsonb");
    Future<Object?> snap(String id) async =>
        (await c.execute("SELECT to_jsonb(e.*) FROM events e WHERE id = '$id'"))
            .first[0];
    final beforeStd = await snap(std), beforeLoan = await snap(loan);

    await applyMigrations(c, migrationsDir: 'migrations');
    // Idempotent: the SQL runs again cleanly.
    await c.execute(File('migrations/030_sync_events.sql').readAsStringSync(),
        queryMode: QueryMode.simple);

    expect(await checks(c),
        ["CHECK (((amount >= (0)::numeric) OR (kind = 'sync'::text)))"]);
    expect(await snap(std), beforeStd);
    expect(await snap(loan), beforeLoan);

    // A sync: signed, zero allowed.
    await ev(kind: 'sync', amount: '-120.50', direction: 'credit');
    await ev(kind: 'sync', amount: '0', direction: 'credit');
    await ev(kind: 'sync', amount: '99', direction: 'credit');

    Future<void> rejects(Future<Object?> Function() f, String name) async {
      try {
        await f();
        fail('expected $name to reject');
      } on ServerException catch (e) {
        expect(e.constraintName, name);
      }
    }

    // Negative only on a sync.
    await rejects(() => ev(amount: '-1'), 'events_amount_nonneg');
    await rejects(
        () => ev(
            kind: 'loan',
            amount: '-1',
            extraCols: ', loan',
            extraVals: ", '{\"v\":1}'::jsonb"),
        'events_amount_nonneg');
    // Sync rules.
    await rejects(
        () => ev(kind: 'sync', direction: 'debit'), 'events_sync_rules');
    await rejects(
        () => ev(
            kind: 'sync',
            direction: 'credit',
            mode: "'every', 1, 'weeks'",
            extraCols: ', freq_rule',
            extraVals: ", 'weekly'"),
        'events_sync_rules');
    await rejects(
        () => ev(
            kind: 'sync',
            direction: 'credit',
            extraCols: ', loan',
            extraVals: ", '{\"v\":1}'::jsonb"),
        'events_loan_shape');
    await rejects(
        () => ev(
            kind: 'sync',
            direction: 'credit',
            extraCols: ', transfer_id',
            extraVals: ", gen_random_uuid()"),
        'events_sync_rules');
    await rejects(
        () => ev(
            kind: 'sync',
            direction: 'credit',
            extraCols: ', offset_stream_ids',
            extraVals: ", ARRAY['$_s2']::uuid[]"),
        'events_offset_only_loans');
    await rejects(() => ev(kind: 'bogus'), 'events_kind_check');

    final idx = await c.execute("SELECT indexdef FROM pg_indexes "
        "WHERE indexname = 'events_sync_by_stream'");
    expect(idx.single[0], contains("WHERE (kind = 'sync'::text)"));
  });
}
