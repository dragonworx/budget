// Data migration 029 (bare variable names): the pure rewrite and rename
// rules, then a scratch database at the 028 state with `$name` formulas
// in every stored location and names the new grammar can't reference.
// DB part: TEST_DATABASE_URL (default local budget_test); skipped without
// Postgres.
import 'dart:convert';
import 'dart:io';

import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/repo/bare_variable_names.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

const _scratch = 'budget_mig029_test';
const _o = '00000000-0000-0000-0000-0000000029a1';
const _o2 = '00000000-0000-0000-0000-0000000029a2';
const _s1 = '00000000-0000-0000-0000-0000000029b1';
const _s2 = '00000000-0000-0000-0000-0000000029b2';
const _e1 = '00000000-0000-0000-0000-0000000029c1';
const _sc = '00000000-0000-0000-0000-0000000029d1';

void main() {
  group('legacyToBare', () {
    test('drops the \$ and keeps everything else', () {
      expect(legacyToBare(r'$rent * 12 / 52'), 'rent * 12 / 52');
      expect(legacyToBare(r'-$Rent+($weeks)'), '-Rent+(weeks)');
      expect(legacyToBare('  \$a\u00a0×\u00a0\$b  '), '  a\u00a0×\u00a0b  ');
      expect(legacyToBare(r'1200'), '1200');
      expect(legacyToBare(''), '');
    });
    test('a name that is a prefix of another', () {
      const ren = {'rent': 'home'};
      expect(legacyToBare(r'$rent + $rental + $rent_2 + $RENT', ren),
          'home + rental + rent_2 + home');
    });
    test('adjacent punctuation and neighbours', () {
      expect(legacyToBare(r'$a$b'), 'a b');
      expect(legacyToBare(r'2$x'), '2 x');
      expect(legacyToBare(r'2.$x'), '2. x');
      expect(legacyToBare(r'($a)$b'), '(a) b');
      expect(legacyToBare(r'$a*$b/$c-$d+$e'), 'a*b/c-d+e');
      expect(legacyToBare(r'$a,$b;$c%'), 'a,b;c%');
      expect(legacyToBare(r'$a😀'), 'a😀');
    });
    test('currency and lone signs stay', () {
      expect(legacyToBare(r'$5 + $.5 + $'), r'$5 + $.5 + $');
      expect(legacyToBare(r'$ 5'), r'$ 5');
      expect(legacyToBare(r'A$1,250'), r'A$1,250');
    });
    test('idempotent', () {
      for (final t in [r'$a$b', r'2$x', r'$rent + $rental', 'x * 2']) {
        final once = legacyToBare(t, const {'_x': 'v_x'});
        expect(legacyToBare(once, const {'_x': 'v_x'}), once);
      }
    });
    test('renamed underscore names', () {
      expect(legacyToBare(r'$_tmp + $_tmp2', const {'_tmp': 'v_tmp'}),
          'v_tmp + _tmp2');
    });
  });

  group('bareNameFor', () {
    test('deterministic, unique, at most 40 characters', () {
      expect(bareNameFor('_tmp', {}), 'v_tmp');
      expect(bareNameFor('_', {}), 'v_');
      expect(bareNameFor('__x', {}), 'v__x');
      expect(bareNameFor('round', {}), 'round_var');
      expect(bareNameFor('MAX', {}), 'MAX_var');
      expect(bareNameFor('_tmp', {'v_tmp'}), 'v_tmp_2');
      expect(bareNameFor('_tmp', {'v_tmp', 'v_tmp_2'}), 'v_tmp_3');
      expect(bareNameFor('_tmp', {'V_TMP'.toLowerCase()}), 'v_tmp_2');
      final long = '_${'a' * 39}';
      expect(bareNameFor(long, {}), 'v_${'a' * 38}');
      expect(bareNameFor(long, {'v_${'a' * 38}'}), 'v_${'a' * 36}_2');
      for (final n in ['_tmp', 'round', long]) {
        expect(isBareName(bareNameFor(n, {})), isTrue, reason: n);
      }
    });
  });

  Connection? admin;
  Connection? db;
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
      print('migration_029_test: no test DB ($e)');
      admin = null;
      db = null;
    }
  });

  tearDownAll(() async {
    await db?.close();
    if (admin != null) {
      await admin!.execute('DROP DATABASE IF EXISTS $_scratch');
      await admin!.close();
    }
  });

  test('029 rewrites every stored formula and renames invalid names', () async {
    if (db == null) return markTestSkipped('no test DB');
    final c = db!;
    await applyMigrations(c, migrationsDir: 'migrations');
    // Back to the 028 state: 029 not applied, the old name rule.
    await c.execute("DELETE FROM schema_migrations "
        "WHERE id = '029_bare_variable_names'");
    await c
        .execute('ALTER TABLE variables DROP CONSTRAINT variables_name_check');
    await c.execute('ALTER TABLE variables ADD CONSTRAINT '
        r"variables_name_check CHECK (name ~ '^[A-Za-z_][A-Za-z0-9_]{0,39}$')");

    await c.execute("INSERT INTO users (id, email) VALUES ('$_o', 'o@x.io'), "
        "('$_o2', 'o2@x.io')");
    await c.execute("INSERT INTO streams (id, name, seed_balance, seed_date, "
        "owner_id, seed_balance_expr, loss_threshold_expr, expr_errors) "
        "VALUES ('$_s1', 'S', 2400, '2026-01-01', '$_o', '2\$rent', "
        "'(\$round)', '{\"seed\": {\"message\": \"There is no variable \$gone\"}}'), "
        "('$_s2', 'S2', 3, '2026-01-01', '$_o2', '\$_tmp', NULL, NULL)");
    Future<String> v(String owner, String name, String expr) async =>
        (await c.execute(
                Sql.named('INSERT INTO variables (owner_id, name, unit, expr, '
                    "value) VALUES (@o, @n, 'number', @e, 1) "
                    'RETURNING id::text'),
                parameters: {'o': owner, 'n': name, 'e': expr}))
            .first[0] as String;
    await v(_o, 'rent', '1200');
    await v(_o, 'rental', '5');
    final tmp = await v(_o, '_tmp', '3');
    final round = await v(_o, 'round', '2');
    await v(_o, 'v_tmp', '7');
    final total = await v(_o, 'total', r'$rent+$rental*$_tmp$round');
    await c.execute(
        Sql.named('UPDATE variables SET problem = @p::jsonb '
            'WHERE id = @id::uuid'),
        parameters: {
          'id': total,
          'p': jsonEncode({'message': r'Division by zero: $round is 0'})
        });
    final tmp2 = await v(_o2, '_tmp', '3');
    final loan = {
      'v': 1,
      'name': r'$keep me',
      'termYearsExpr': r'$rent/100',
      'ratePeriods': [
        {'ratePct': 2, 'ratePctExpr': r'$round'},
        {'ratePct': 3},
      ],
    };
    await c.execute(
        Sql.named('INSERT INTO events (id, stream_id, name, direction, amount, '
            'start_date, recurrence_mode, end_mode, kind, amount_expr, '
            'interval_expr, expr_errors, loan) '
            "VALUES ('$_e1', '$_s1', '\$name', 'debit', 2400, '2026-01-01', "
            "'once', 'never', 'loan', @a, @i, @x::jsonb, @l::jsonb)"),
        parameters: {
          'a': r'$rent*2',
          'i': r'$_tmp',
          'x': jsonEncode({
            'count': {'message': r'There is no variable $_tmp'}
          }),
          'l': jsonEncode(loan),
        });
    await c.execute('INSERT INTO occurrence_overrides (event_id, date, amount, '
        "direction, amount_expr) VALUES ('$_e1', '2026-01-01', 10, 'debit', "
        "'\$5+\$rental')");
    await c.execute(
        Sql.named('INSERT INTO scenarios (id, stream_id, name, request) '
            "VALUES ('$_sc', '$_s1', 'Sc', @r::jsonb)"),
        parameters: {
          'r': jsonEncode({
            'note': r'$untouched',
            'exprs': {'amount': r'$rent/2', 'count': r'$_tmp'}
          })
        });

    await applyMigrations(c, migrationsDir: 'migrations');

    Future<List<List<Object?>>> q(String sql) async =>
        [for (final r in await c.execute(sql)) r.toList()];
    final names = {
      for (final r in await q('SELECT id::text, name FROM variables'))
        r[0]: r[1]
    };
    expect(names[tmp], 'v_tmp_2', reason: 'v_tmp is taken');
    expect(names[round], 'round_var');
    expect(names[tmp2], 'v_tmp', reason: 'per owner');
    expect(
        (await q("SELECT expr, problem->>'message' FROM variables "
                "WHERE id = '$total'"))
            .single,
        ['rent+rental*v_tmp_2 round_var', 'Division by zero: round_var is 0']);
    expect(
        (await q("SELECT seed_balance_expr, loss_threshold_expr, "
                "expr_errors->'seed'->>'message' FROM streams "
                "WHERE id = '$_s1'"))
            .single,
        ['2 rent', '(round_var)', 'There is no variable gone']);
    expect(
        (await q("SELECT seed_balance_expr FROM streams WHERE id = '$_s2'"))
            .single,
        ['v_tmp']);
    final ev = (await q("SELECT name, amount_expr, interval_expr, "
            "expr_errors::text, loan::text FROM events WHERE id = '$_e1'"))
        .single;
    expect(ev[0], r'$name');
    expect(ev[1], 'rent*2');
    expect(ev[2], 'v_tmp_2');
    expect(jsonDecode(ev[3] as String), {
      'count': {'message': 'There is no variable v_tmp_2'}
    });
    expect(jsonDecode(ev[4] as String), {
      'v': 1,
      'name': r'$keep me',
      'termYearsExpr': 'rent/100',
      'ratePeriods': [
        {'ratePct': 2, 'ratePctExpr': 'round_var'},
        {'ratePct': 3},
      ],
    });
    expect((await q('SELECT amount_expr FROM occurrence_overrides')).single,
        [r'$5+rental']);
    expect(
        jsonDecode((await q("SELECT request::text FROM scenarios "
                "WHERE id = '$_sc'"))
            .single[0] as String),
        {
          'note': r'$untouched',
          'exprs': {'amount': 'rent/2', 'count': 'v_tmp_2'}
        });
    // The new name rule holds.
    expect(
        () => c.execute("INSERT INTO variables (owner_id, name, unit, expr, "
            "value) VALUES ('$_o', '_bad', 'number', '1', 1)"),
        throwsA(isA<ServerException>()));

    // Idempotent: a second run changes nothing; the migration is recorded.
    final snap = await q('SELECT to_jsonb(x.*)::text FROM (SELECT * FROM '
        'variables ORDER BY id) x UNION ALL SELECT to_jsonb(e.*)::text '
        'FROM events e UNION ALL SELECT to_jsonb(s.*)::text FROM streams s '
        'UNION ALL SELECT request::text FROM scenarios');
    final report = BareMigrationReport();
    await c.runTx((s) => migrateBareVariableNames(s, report: report));
    expect(report.renames, isEmpty);
    expect(report.rows, isEmpty);
    expect(
        await q('SELECT to_jsonb(x.*)::text FROM (SELECT * FROM variables '
            'ORDER BY id) x UNION ALL SELECT to_jsonb(e.*)::text FROM events e '
            'UNION ALL SELECT to_jsonb(s.*)::text FROM streams s '
            'UNION ALL SELECT request::text FROM scenarios'),
        snap);
    expect(
        await q("SELECT 1 FROM schema_migrations "
            "WHERE id = '029_bare_variable_names'"),
        hasLength(1));
  });
}
