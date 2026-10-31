// Migration 027 (loan offset links) on a scratch database at the 026
// schema: the new column and its default, existing rows untouched, the
// two CHECKs (offset only on a loan, at most one id), the GIN index, and
// re-running is a no-op. DB-backed (TEST_DATABASE_URL, default local
// budget_test); skipped without Postgres.
import 'dart:io';

import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

const _scratch = 'budget_mig027_test';
const _o = '00000000-0000-0000-0000-0000000027a1';
const _s1 = '00000000-0000-0000-0000-0000000027b1';
const _s2 = '00000000-0000-0000-0000-0000000027b2';
const _s3 = '00000000-0000-0000-0000-0000000027b3';

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
      print('migration_027_test: no test DB ($e)');
      admin = null;
      db = null;
      return;
    }
    old = Directory.systemTemp.createTempSync('mig026');
    for (final f in Directory('migrations').listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name.compareTo('027') < 0) f.copySync('${old.path}/$name');
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

  test('027 adds offset_stream_ids with checks and a GIN index', () async {
    if (db == null) return markTestSkipped('no test DB');
    final c = db!;
    await applyMigrations(c, migrationsDir: old.path);
    await c.execute("INSERT INTO users (id, email) VALUES ('$_o', 'o@x.io')");
    for (final s in [_s1, _s2, _s3]) {
      await c.execute("INSERT INTO streams (id, name, seed_balance, seed_date, "
          "owner_id) VALUES ('$s', 'S$s', 0, '2026-01-01', '$_o')");
    }
    var n = 0;
    Future<String> ev(String stream,
        {bool loan = false, String? offsets}) async {
      final id = '00000000-0000-0000-0000-${(++n).toString().padLeft(12, '0')}';
      final extraCols = [
        if (loan) 'kind, loan',
        if (offsets != null) 'offset_stream_ids',
      ].map((x) => ', $x').join();
      final extraVals = [
        if (loan) "'loan', '{\"v\":1,\"mode\":\"simple\"}'::jsonb",
        if (offsets != null) offsets,
      ].map((x) => ', $x').join();
      await c.execute(
          'INSERT INTO events (id, stream_id, name, direction, amount, '
          'start_date, recurrence_mode, end_mode$extraCols) '
          "VALUES ('$id', '$stream', 'E$n', 'debit', 10, '2026-01-01', "
          "'once', 'never'$extraVals)");
      return id;
    }

    final std = await ev(_s1);
    final loan = await ev(_s2, loan: true);
    Future<Object?> snap(String id) async => (await c
            .execute("SELECT to_jsonb(e.*) - 'offset_stream_ids' FROM events e "
                "WHERE id = '$id'"))
        .first[0];
    final beforeStd = await snap(std), beforeLoan = await snap(loan);

    await applyMigrations(c, migrationsDir: 'migrations');
    // Idempotent: the SQL runs again cleanly.
    await c.execute(File('migrations/027_loan_offsets.sql').readAsStringSync(),
        queryMode: QueryMode.simple);

    final col = (await c
            .execute("SELECT data_type, udt_name, is_nullable, column_default "
                "FROM information_schema.columns WHERE table_name = 'events' "
                "AND column_name = 'offset_stream_ids'"))
        .single;
    expect(col.sublist(0, 3), ['ARRAY', '_uuid', 'NO']);
    expect(col[3].toString(), contains("'{}'"));

    // Existing rows: empty list, otherwise untouched.
    for (final (id, before) in [(std, beforeStd), (loan, beforeLoan)]) {
      expect(
          (await c.execute("SELECT cardinality(offset_stream_ids) FROM events "
                  "WHERE id = '$id'"))
              .first[0],
          0);
      expect(await snap(id), before);
    }

    final idx = await c.execute("SELECT indexdef FROM pg_indexes "
        "WHERE indexname = 'events_offset_stream_ids_gin'");
    expect(idx.single[0].toString(), contains('gin'));

    Future<void> bad(Future<Object?> Function() f, String constraint) async {
      await expectLater(
          f,
          throwsA(isA<ServerException>().having(
              (e) => e.message + (e.constraintName ?? ''),
              'msg',
              contains(constraint))));
    }

    // Only a loan may carry an offset; at most one.
    await bad(() => ev(_s1, offsets: "ARRAY['$_s3']::uuid[]"),
        'events_offset_only_loans');
    await bad(
        () => c.execute("UPDATE events SET offset_stream_ids = "
            "ARRAY['$_s1', '$_s3']::uuid[] WHERE id = '$loan'"),
        'events_offset_max_one');
    await c.execute("UPDATE events SET offset_stream_ids = "
        "ARRAY['$_s3']::uuid[] WHERE id = '$loan'");
    expect(
        (await c.execute("SELECT id::text FROM events "
                "WHERE offset_stream_ids @> ARRAY['$_s3'::uuid]"))
            .single[0],
        loan);
    // A loan with an offset can't become standard while linked.
    await bad(
        () => c.execute("UPDATE events SET kind = 'standard', loan = NULL "
            "WHERE id = '$loan'"),
        'events_offset_only_loans');
  });
}
