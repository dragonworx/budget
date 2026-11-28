// Migration 031 (hierarchical categories + per-user favourites) on a
// scratch database at the 030 schema: parent_id / sort_order are added,
// existing rows keep their id, name and event links, mapped children nest
// under new or reused parents, Sync stays top-level, re-running is a
// no-op. DB-backed (TEST_DATABASE_URL, default local budget_test);
// skipped without Postgres.
import 'dart:io';

import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

const _scratch = 'budget_mig031_test';
const _o = '00000000-0000-0000-0000-0000000031a1';
const _o2 = '00000000-0000-0000-0000-0000000031a2';
const _s1 = '00000000-0000-0000-0000-0000000031b1';

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
      print('migration_031_test: no test DB ($e)');
      admin = null;
      db = null;
      return;
    }
    old = Directory.systemTemp.createTempSync('mig030');
    for (final f in Directory('migrations').listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name.compareTo('031') < 0) f.copySync('${old.path}/$name');
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

  test('031 nests mapped categories and keeps every existing row', () async {
    if (db == null) return markTestSkipped('no test DB');
    final c = db!;
    await applyMigrations(c, migrationsDir: old.path);
    await c.execute("INSERT INTO users (id, email) VALUES "
        "('$_o', 'o@x.io'), ('$_o2', 'p@x.io')");
    await c.execute("INSERT INTO streams (id, name, seed_balance, seed_date, "
        "owner_id) VALUES ('$_s1', 'Everyday', 0, '2026-01-01', '$_o')");

    Future<String> cat(String id, String name, {String owner = _o}) async {
      await c.execute("INSERT INTO categories (id, owner_id, name, color) "
          "VALUES ('$id', '$owner', '$name', '#3D6FD8')");
      return id;
    }

    const rent = '00000000-0000-0000-0000-0000000031c1';
    const power = '00000000-0000-0000-0000-0000000031c2';
    const groc = '00000000-0000-0000-0000-0000000031c3';
    const ins = '00000000-0000-0000-0000-0000000031c4';
    const salary = '00000000-0000-0000-0000-0000000031c5';
    const stream = '00000000-0000-0000-0000-0000000031c6';
    const childc = '00000000-0000-0000-0000-0000000031c7';
    const sync = '00000000-0000-0000-0000-0000000031c8';
    const mort = '00000000-0000-0000-0000-0000000031c9';
    const repay = '00000000-0000-0000-0000-0000000031ca';
    const o2rent = '00000000-0000-0000-0000-0000000031cb';
    const o2sav = '00000000-0000-0000-0000-0000000031cc';
    const o2top = '00000000-0000-0000-0000-0000000031cd';

    await cat(rent, 'Rent');
    await cat(power, 'Power');
    await cat(groc, 'Groceries');
    await cat(ins, 'Insurance');
    await cat(salary, 'Salary');
    await cat(stream, 'Streaming');
    await cat(childc, 'Childcare');
    await cat(sync, 'Sync');
    await cat(mort, 'Mortgage');
    await cat(repay, 'Mortgage repayment');
    // Second owner: only Rent (gets Housing) and Savings + Top up savings
    // (reuses existing Savings as the parent).
    await cat(o2rent, 'Rent', owner: _o2);
    await cat(o2sav, 'Savings', owner: _o2);
    await cat(o2top, 'Top up savings', owner: _o2);

    await c.execute("INSERT INTO events (id, stream_id, name, direction, "
        "amount, start_date, recurrence_mode, end_mode, category_id) VALUES "
        "('00000000-0000-0000-0000-0000000031e1', '$_s1', 'Rent', 'debit', 10, "
        "'2026-01-01', 'once', 'never', '$rent')");

    Future<Object?> snap(String id) async => (await c.execute(
            "SELECT id::text, name, color, hidden FROM categories WHERE id = '$id'"))
        .first
        .toList();
    final before = {
      for (final id in [
        rent,
        power,
        groc,
        ins,
        salary,
        stream,
        childc,
        sync,
        mort,
        repay
      ])
        id: await snap(id)
    };
    final evBefore =
        (await c.execute("SELECT category_id::text, name FROM events "
                "WHERE id = '00000000-0000-0000-0000-0000000031e1'"))
            .first
            .toList();

    await applyMigrationsThrough(c, through: '031');
    // Idempotent: the SQL runs again cleanly.
    await c.execute(
        File('migrations/031_category_hierarchy.sql').readAsStringSync(),
        queryMode: QueryMode.simple);

    for (final e in before.entries) {
      expect(await snap(e.key), e.value, reason: e.key);
    }
    expect(
        (await c.execute("SELECT category_id::text, name FROM events "
                "WHERE id = '00000000-0000-0000-0000-0000000031e1'"))
            .first
            .toList(),
        evBefore);

    Future<String?> parentOf(String id) async {
      final r = await c.execute("SELECT p.name FROM categories c "
          "LEFT JOIN categories p ON p.id = c.parent_id WHERE c.id = '$id'");
      return r.first[0] as String?;
    }

    expect(await parentOf(rent), 'Housing');
    expect(await parentOf(mort), 'Housing');
    expect(await parentOf(repay), 'Housing');
    expect(await parentOf(power), 'Utilities');
    expect(await parentOf(groc), 'Shopping');
    expect(await parentOf(salary), 'Income');
    expect(await parentOf(ins), isNull,
        reason: 'existing Insurance stays top-level');
    expect(await parentOf(stream), isNull);
    expect(await parentOf(childc), isNull);
    expect(await parentOf(sync), isNull);

    // New parents exist; Insurance was reused, not duplicated.
    final names = [
      for (final r in await c.execute(
          "SELECT name FROM categories WHERE owner_id = '$_o' ORDER BY lower(name)"))
        r[0] as String
    ];
    expect(names.where((n) => n == 'Insurance').length, 1);
    expect(names, containsAll(['Housing', 'Utilities', 'Shopping', 'Income']));
    // No empty parents for groups this owner had no children in.
    expect(names, isNot(contains('Transport')));
    expect(names, isNot(contains('Health')));
    expect(names, isNot(contains('Giving')));
    expect(names, isNot(contains('Savings')));

    expect(await parentOf(o2rent), 'Housing');
    expect(await parentOf(o2top), 'Savings');
    expect(
        (await c.execute("SELECT count(*) FROM categories "
                "WHERE owner_id = '$_o2' AND lower(name) = 'savings'"))
            .first[0],
        1,
        reason: 'existing Savings reused as parent');

    final fav = await c.execute("SELECT to_regclass('category_favorites')");
    expect(fav.first[0], isNotNull);

    // Depth 2 is the max: a child cannot itself be a parent.
    try {
      await c.execute("UPDATE categories SET parent_id = '$power' "
          "WHERE id = '$groc'");
      fail('expected max depth to reject nesting under a child');
    } on ServerException catch (e) {
      expect(e.constraintName, 'categories_max_depth');
    }

    // Sync stays top-level.
    try {
      final housing = (await c.execute("SELECT id::text FROM categories "
              "WHERE owner_id = '$_o' AND name = 'Housing'"))
          .first[0] as String;
      await c.execute("UPDATE categories SET parent_id = '$housing' "
          "WHERE id = '$sync'");
      fail('expected Sync nest to reject');
    } on ServerException catch (e) {
      expect(e.constraintName, 'categories_sync_top_level');
    }
  });
}
