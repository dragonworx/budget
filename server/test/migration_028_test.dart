// Migration 028 (variables, spec 010) on a scratch database at the 027
// schema: the tables, columns and constraints, existing rows untouched,
// the version trigger, the variable_refs shape checks and override FK,
// deleting a user cascades cleanly, and re-running is a no-op.
// DB-backed (TEST_DATABASE_URL, default local budget_test); skipped
// without Postgres.
import 'dart:io';

import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

const _scratch = 'budget_mig028_test';
const _o = '00000000-0000-0000-0000-0000000028a1';
const _s1 = '00000000-0000-0000-0000-0000000028b1';
const _e1 = '00000000-0000-0000-0000-0000000028c1';
const _s2 = '00000000-0000-0000-0000-0000000028b2';
const _e2 = '00000000-0000-0000-0000-0000000028c2';

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
      print('migration_028_test: no test DB ($e)');
      admin = null;
      db = null;
      return;
    }
    old = Directory.systemTemp.createTempSync('mig027');
    for (final f in Directory('migrations').listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name.compareTo('028') < 0) f.copySync('${old.path}/$name');
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

  test('028 adds variables, expr columns and variable_refs', () async {
    if (db == null) return markTestSkipped('no test DB');
    final c = db!;
    await applyMigrations(c, migrationsDir: old.path);
    await c.execute("INSERT INTO users (id, email) VALUES ('$_o', 'o@x.io')");
    await c.execute("INSERT INTO streams (id, name, seed_balance, seed_date, "
        "owner_id) VALUES ('$_s1', 'S', 12.5, '2026-01-01', '$_o')");
    await c
        .execute('INSERT INTO events (id, stream_id, name, direction, amount, '
            'start_date, recurrence_mode, end_mode) '
            "VALUES ('$_e1', '$_s1', 'E', 'debit', 10, '2026-01-01', 'once', "
            "'never')");
    await c.execute('INSERT INTO occurrence_overrides (event_id, date, amount, '
        "direction) VALUES ('$_e1', '2026-01-01', 11, 'debit')");
    Future<Object?> snap(String t, String where) async =>
        (await c.execute('SELECT to_jsonb(x.*) FROM $t x WHERE $where'))
            .first[0];
    final before = [
      await snap('streams', "id = '$_s1'"),
      await snap('events', "id = '$_e1'"),
      await snap('occurrence_overrides', "event_id = '$_e1'"),
    ];

    await applyMigrations(c, migrationsDir: 'migrations');
    // Idempotent: the SQL runs again cleanly.
    await c.execute(File('migrations/028_variables.sql').readAsStringSync(),
        queryMode: QueryMode.simple);

    // Existing rows: the new columns are NULL, everything else as before.
    final after = [
      await snap('streams', "id = '$_s1'"),
      await snap('events', "id = '$_e1'"),
      await snap('occurrence_overrides', "event_id = '$_e1'"),
    ];
    const added = {
      'seed_balance_expr', 'loss_threshold_expr', 'expr_errors', //
      'amount_expr', 'interval_expr', 'count_expr', 'expr_error',
    };
    for (var i = 0; i < 3; i++) {
      final a = Map<String, dynamic>.from(after[i] as Map);
      for (final k in added.intersection(a.keys.toSet())) {
        expect(a.remove(k), isNull, reason: k);
      }
      expect(a, before[i]);
    }

    Future<void> bad(Future<Object?> Function() f, String constraint) async {
      await expectLater(
          f,
          throwsA(isA<ServerException>().having(
              (e) => e.message + (e.constraintName ?? ''),
              'msg',
              contains(constraint))));
    }

    Future<String> variable(String name,
        {String unit = 'number', String expr = '1'}) async {
      final r = await c.execute(
          Sql.named('INSERT INTO variables (owner_id, name, unit, expr, value) '
              "VALUES ('$_o', @n, @u, @e, 1) RETURNING id::text"),
          parameters: {'n': name, 'u': unit, 'e': expr});
      return r.first[0] as String;
    }

    final rent = await variable('rent', unit: 'money');
    await bad(() => variable('Rent'), 'variables_owner_name_uq');
    await bad(() => variable('1x'), 'variables_name_check');
    await bad(() => variable('a' * 41), 'variables_name_check');
    await bad(() => variable('ok', unit: 'pct'), 'variables_unit_check');
    await bad(() => variable('ok', expr: ''), 'variables_expr_len');
    await bad(() => variable('ok', expr: 'x' * 501), 'variables_expr_len');
    await bad(
        () => c.execute("UPDATE variables SET description = '${'d' * 201}' "
            "WHERE id = '$rent'"),
        'variables_desc_len');
    await bad(
        () => c.execute("UPDATE variables SET display_decimals = 7 "
            "WHERE id = '$rent'"),
        'variables_decimals');
    await bad(
        () => c.execute("UPDATE events SET amount_expr = '${'1' * 501}' "
            "WHERE id = '$_e1'"),
        'events_amount_expr_len');

    // The version trigger: a real change bumps, audit columns do not.
    await c.execute("UPDATE variables SET value = 2 WHERE id = '$rent'");
    await c.execute("UPDATE variables SET updated_by = '$_o' "
        "WHERE id = '$rent'");
    expect(
        (await c.execute("SELECT version FROM variables WHERE id = '$rent'"))
            .first[0],
        2);

    // variable_refs: exactly one owner kind, event under a stream, override
    // under an event (and an existing override), no duplicates.
    final weekly = await variable('weekly', expr: r'$rent / 4');
    Future<void> ref(String cols, String vals) =>
        c.execute('INSERT INTO variable_refs (variable_id, field$cols) '
            "VALUES ('$rent', 'f'$vals)");
    await ref(', from_variable_id', ", '$weekly'");
    await ref(', stream_id', ", '$_s1'");
    await ref(', stream_id, event_id', ", '$_s1', '$_e1'");
    await ref(', stream_id, event_id, override_date',
        ", '$_s1', '$_e1', '2026-01-01'");
    await bad(() => ref(', stream_id', ", '$_s1'"), 'variable_refs_uq');
    await bad(() => ref('', ''), 'variable_refs_check');
    await bad(() => ref(', from_variable_id, stream_id', ", '$weekly', '$_s1'"),
        'variable_refs_check');
    await bad(() => ref(', from_variable_id, event_id', ", '$weekly', '$_e1'"),
        'variable_refs_check');
    await bad(
        () => ref(', stream_id, event_id, override_date',
            ", '$_s1', '$_e1', '2026-02-01'"),
        'variable_refs_event_id_override_date_fkey');
    // A referenced variable can't be deleted (no cascade on variable_id).
    await bad(() => c.execute("DELETE FROM variables WHERE id = '$rent'"),
        'variable_refs_variable_id_fkey');
    // Removing the override drops its ref; deleting the referencing
    // variable drops its refs.
    await c.execute("DELETE FROM occurrence_overrides WHERE event_id = '$_e1'");
    await c.execute("DELETE FROM variables WHERE id = '$weekly'");
    expect((await c.execute('SELECT count(*) FROM variable_refs')).first[0], 2);

    // Deleting the user cascades through streams, events, variables, refs,
    // whatever order Postgres runs the cascades in: a second stream created
    // after the variables (later cascade) holds a referencing event too.
    await c.execute("INSERT INTO streams (id, name, seed_balance, seed_date, "
        "owner_id) VALUES ('$_s2', 'S2', 0, '2026-01-01', '$_o')");
    await c
        .execute('INSERT INTO events (id, stream_id, name, direction, amount, '
            'start_date, recurrence_mode, end_mode) '
            "VALUES ('$_e2', '$_s2', 'E2', 'debit', 1, '2026-01-01', 'once', "
            "'never')");
    await ref(', stream_id, event_id', ", '$_s2', '$_e2'");
    await c.execute("DELETE FROM users WHERE id = '$_o'");
    for (final t in ['variables', 'variable_refs', 'streams', 'events']) {
      expect((await c.execute('SELECT count(*) FROM $t')).first[0], 0,
          reason: t);
    }
  });
}
