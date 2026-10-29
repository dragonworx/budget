// Migration 024 (categories) backfill on a scratch database at the 023
// schema: one category per distinct (stream, trimmed lower-case name),
// named after the first event in list order, coloured with its colour or
// the client's positional palette colour; every event gets one; versions
// untouched; names stay in sync through the triggers. DB-backed
// (TEST_DATABASE_URL, default local budget_test); skipped without Postgres.
import 'dart:io';

import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

const _scratch = 'budget_mig024_test';
const _owner = '00000000-0000-0000-0000-0000000024a1';
const _s1 = '00000000-0000-0000-0000-0000000024b1';
const _s2 = '00000000-0000-0000-0000-0000000024b2';

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
      print('migration_024_test: no test DB ($e)');
      admin = null;
      db = null;
      return;
    }
    old = Directory.systemTemp.createTempSync('mig023');
    for (final f in Directory('migrations').listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name.compareTo('024') < 0) f.copySync('${old.path}/$name');
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

  test('024 backfills one category per distinct name, every event in one',
      () async {
    if (db == null) return markTestSkipped('no test DB');
    final c = db!;
    await applyMigrations(c, migrationsDir: old.path);
    await c
        .execute("INSERT INTO users (id, email) VALUES ('$_owner', 'm@x.io')");
    for (final s in [_s1, _s2]) {
      await c.execute("INSERT INTO streams (id, name, seed_balance, seed_date, "
          "owner_id) VALUES ('$s', 'S$s', 0, '2026-01-01', '$_owner')");
    }
    var n = 0;
    Future<String> ev(String stream, String name,
        {String? color, String? transfer, String dir = 'debit'}) async {
      final id = '00000000-0000-0000-0000-${(++n).toString().padLeft(12, '0')}';
      await c.execute(
        Sql.named('INSERT INTO events (id, stream_id, name, direction, amount, '
            'start_date, recurrence_mode, end_mode, color, transfer_id, '
            'created_at) VALUES (@id::uuid, @s::uuid, @n, @d, 10, '
            "'2026-01-01', 'once', 'never', @c, @t::uuid, "
            "now() + make_interval(secs => @i))"),
        parameters: {
          'id': id,
          's': stream,
          'n': name,
          'd': dir,
          'c': color,
          't': transfer,
          'i': n,
        },
      );
      return id;
    }

    final wages = await ev(_s1, 'Wages', dir: 'credit');
    final rent = await ev(_s1, 'Rent');
    final groceries = await ev(_s1, 'Groceries', color: '#5B7A2A');
    final groceries2 = await ev(_s1, ' groceries ');
    final blank = await ev(_s1, '  ');
    const tid = '00000000-0000-0000-0000-0000000024c1';
    final save1 = await ev(_s1, 'Save', transfer: tid);
    final save2 = await ev(_s2, 'Save', transfer: tid, dir: 'credit');
    final other = await ev(_s2, 'Rent', color: '#B8488E');
    // The list order puts Rent before Wages in stream 1.
    await c.execute("UPDATE streams SET event_order = "
        "ARRAY['$rent', '$wages']::uuid[] WHERE id = '$_s1'");

    final before =
        await c.execute('SELECT id::text, version FROM events ORDER BY id');
    final countBefore =
        (await c.execute('SELECT count(*) FROM events')).first[0];

    await applyMigrations(c, migrationsDir: 'migrations');

    final after =
        await c.execute('SELECT id::text, version FROM events ORDER BY id');
    expect([
      for (final r in after) r.toList()
    ], [
      for (final r in before) r.toList()
    ], reason: 'the backfill is not an edit');
    expect(
        (await c.execute('SELECT count(*) FROM events')).first[0], countBefore);
    expect(
        (await c.execute(
                'SELECT count(*) FROM events WHERE category_id IS NULL'))
            .first[0],
        0);

    final cats = {
      for (final r in await c
          .execute('SELECT stream_id::text, name, color FROM categories'))
        '${r[0] == _s1 ? 1 : 2}:${r[1]}': r[2]
    };
    expect(cats, {
      // Positional palette: Rent slot 0 (blue), Wages slot 1 (purple),
      // then created order: Groceries (own colour), Untitled slot 4, Save 5.
      '1:Rent': '#3D6FD8',
      '1:Wages': '#9250C8',
      '1:Groceries': '#5B7A2A',
      '1:Untitled': '#B8488E',
      '1:Save': '#5B7A2A',
      '2:Save': '#3D6FD8',
      '2:Rent': '#B8488E',
    });
    Future<String> catOf(String id) async =>
        (await c.execute('SELECT c.name FROM events e JOIN categories c '
                "ON c.id = e.category_id WHERE e.id = '$id'"))
            .first[0] as String;
    expect(await catOf(groceries2), 'Groceries');
    expect(await catOf(groceries), 'Groceries');
    expect(await catOf(blank), 'Untitled');
    expect(await catOf(save1), 'Save');
    expect(await catOf(save2), 'Save');
    expect(await catOf(other), 'Rent');
    // Names follow the category.
    expect(
        (await c.execute("SELECT name FROM events WHERE id = '$groceries2'"))
            .first[0],
        'Groceries');

    // Rename follows to the events; the unique rule holds.
    await c.execute("UPDATE categories SET name = 'Food' "
        "WHERE stream_id = '$_s1' AND name = 'Groceries'");
    expect(
        (await c.execute("SELECT count(*) FROM events WHERE name = 'Food'"))
            .first[0],
        2);
    await expectLater(
        c.execute("INSERT INTO categories (stream_id, name, color) "
            "VALUES ('$_s1', 'food', '#3D6FD8')"),
        throwsA(isA<ServerException>()));
    // A second run is a no-op.
    await applyMigrations(c, migrationsDir: 'migrations');
    expect((await c.execute('SELECT count(*) FROM categories')).first[0], 7);
  });
}
