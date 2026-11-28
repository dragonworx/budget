// Migration 035 (per-stream categories) on a scratch database at the 034
// schema: each stream gets a full copy of its owner's tree (new ids,
// parent_id remapped), events and favourites are repointed at the copy in
// that event's stream, transfer legs that shared one row each get their
// own stream's copy of the same path, and the name trigger maps by stream
// afterwards. DB-backed (TEST_DATABASE_URL, default local budget_test);
// skipped without Postgres.
import 'dart:io';

import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

const _scratch = 'budget_mig035_test';
const _o1 = '00000000-0000-0000-0000-0000000035a1';
const _o2 = '00000000-0000-0000-0000-0000000035a2';
const _sA = '00000000-0000-0000-0000-0000000035b1';
const _sB = '00000000-0000-0000-0000-0000000035b2';
const _sC = '00000000-0000-0000-0000-0000000035b3';
const _income = '00000000-0000-0000-0000-0000000035c1';
const _wages = '00000000-0000-0000-0000-0000000035c2';
const _housing = '00000000-0000-0000-0000-0000000035c3';
const _rent = '00000000-0000-0000-0000-0000000035c4';
const _o2housing = '00000000-0000-0000-0000-0000000035c5';
const _o2rent = '00000000-0000-0000-0000-0000000035c6';
const _xfer = '00000000-0000-0000-0000-0000000035d0';

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
      print('migration_035_test: no test DB ($e)');
      admin = null;
      db = null;
      return;
    }
    old = Directory.systemTemp.createTempSync('mig034');
    for (final f in Directory('migrations').listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name.compareTo('035') < 0) f.copySync('${old.path}/$name');
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

  test('035 copies each owner tree into every stream and remaps events',
      () async {
    if (db == null) return markTestSkipped('no test DB');
    final c = db!;
    await applyMigrations(c, migrationsDir: old.path);

    await c.execute("INSERT INTO users (id, email) VALUES "
        "('$_o1', 'a@x.io'), ('$_o2', 'b@x.io')");
    await c.execute("INSERT INTO streams (id, name, seed_balance, seed_date, "
        "owner_id) VALUES "
        "('$_sA', 'Everyday', 0, '2026-01-01', '$_o1'), "
        "('$_sB', 'Savings', 0, '2026-01-01', '$_o1'), "
        "('$_sC', 'Shared', 0, '2026-01-01', '$_o2')");

    Future<void> cat(String id, String owner, String name, String color,
        {String? parent, int sort = 0, bool hidden = false}) async {
      await c.execute("INSERT INTO categories (id, owner_id, name, color, "
          "hidden, parent_id, sort_order) VALUES ("
          "'$id', '$owner', '$name', '$color', $hidden, "
          "${parent == null ? 'NULL' : "'$parent'"}, $sort)");
    }

    await cat(_income, _o1, 'Income', '#3D6FD8', sort: 0);
    await cat(_wages, _o1, 'Wages', '#2B8AA8', parent: _income, sort: 0);
    await cat(_housing, _o1, 'Housing', '#9250C8', sort: 1);
    await cat(_rent, _o1, 'Rent', '#5B7A2A', parent: _housing, sort: 0);
    await cat(_o2housing, _o2, 'Housing', '#B36A12', sort: 0);
    await cat(_o2rent, _o2, 'Rent', '#B8488E', parent: _o2housing, sort: 0);

    Future<String> ev(String id, String stream, String category,
        {String? transferId, String direction = 'debit'}) async {
      await c.execute("INSERT INTO events (id, stream_id, name, direction, "
          "amount, start_date, recurrence_mode, end_mode, category_id, "
          "transfer_id) VALUES ('$id', '$stream', 'tmp', '$direction', 10, "
          "'2026-01-01', 'once', 'never', '$category', "
          "${transferId == null ? 'NULL' : "'$transferId'"})");
      return id;
    }

    const eARent = '00000000-0000-0000-0000-0000000035e1';
    const eBRent = '00000000-0000-0000-0000-0000000035e2';
    const eAXfer = '00000000-0000-0000-0000-0000000035e3';
    const eBXfer = '00000000-0000-0000-0000-0000000035e4';
    const eCRent = '00000000-0000-0000-0000-0000000035e5';
    await ev(eARent, _sA, _rent);
    await ev(eBRent, _sB, _rent);
    await ev(eAXfer, _sA, _wages, transferId: _xfer, direction: 'debit');
    await ev(eBXfer, _sB, _wages, transferId: _xfer, direction: 'credit');
    await ev(eCRent, _sC, _o2rent);

    await c.execute("INSERT INTO category_favorites "
        "(user_id, category_id, sort_order) VALUES ('$_o1', '$_rent', 0)");

    expect((await c.execute('SELECT count(*) FROM categories')).first[0], 6);
    expect((await c.execute('SELECT count(*) FROM events')).first[0], 5);

    await applyMigrations(c, migrationsDir: 'migrations');

    expect((await c.execute('SELECT count(*) FROM events')).first[0], 5);
    // Owner 1: 4 cats x 2 streams; owner 2: 2 cats x 1 stream.
    expect((await c.execute('SELECT count(*) FROM categories')).first[0], 10);
    expect(
        (await c.execute("SELECT count(*) FROM information_schema.columns "
                "WHERE table_name = 'categories' AND column_name = 'owner_id'"))
            .first[0],
        0);
    expect(
        (await c.execute('SELECT count(*) FROM events e JOIN categories c '
                'ON c.id = e.category_id WHERE c.stream_id <> e.stream_id'))
            .first[0],
        0);

    Future<List<Object?>> path(String eventId) async {
      final rows = await c.execute("SELECT c.id::text, c.stream_id::text, "
          "c.name, c.color, c.hidden, c.sort_order, p.name "
          "FROM events e "
          "JOIN categories c ON c.id = e.category_id "
          "LEFT JOIN categories p ON p.id = c.parent_id "
          "WHERE e.id = '$eventId'");
      return rows.first.toList();
    }

    final aRent = await path(eARent);
    final bRent = await path(eBRent);
    expect(aRent[1], _sA);
    expect(bRent[1], _sB);
    expect(aRent[0], isNot(bRent[0]));
    expect(aRent.sublist(2), ['Rent', '#5B7A2A', false, 0, 'Housing']);
    expect(bRent.sublist(2), ['Rent', '#5B7A2A', false, 0, 'Housing']);

    final aXfer = await path(eAXfer);
    final bXfer = await path(eBXfer);
    expect(aXfer[1], _sA);
    expect(bXfer[1], _sB);
    expect(aXfer[0], isNot(bXfer[0]));
    expect(aXfer.sublist(2), ['Wages', '#2B8AA8', false, 0, 'Income']);
    expect(bXfer.sublist(2), ['Wages', '#2B8AA8', false, 0, 'Income']);

    final cRent = await path(eCRent);
    expect(cRent[1], _sC);
    expect(cRent.sublist(2), ['Rent', '#B8488E', false, 0, 'Housing']);

    // Favourites are copied onto every stream's copy of that category.
    final favs =
        await c.execute("SELECT c.stream_id::text FROM category_favorites f "
            "JOIN categories c ON c.id = f.category_id "
            "WHERE f.user_id = '$_o1' ORDER BY c.stream_id");
    expect([for (final r in favs) r[0]], [_sA, _sB]);

    // Each of owner 1's streams has the same 4-name tree.
    for (final s in [_sA, _sB]) {
      final names =
          await c.execute("SELECT coalesce(p.name || ' / ', '') || c.name "
              "FROM categories c LEFT JOIN categories p ON p.id = c.parent_id "
              "WHERE c.stream_id = '$s' ORDER BY 1");
      expect({for (final r in names) r[0]},
          {'Housing', 'Income', 'Housing / Rent', 'Income / Wages'});
    }

    // Cross-stream category_id is rejected.
    try {
      final other = (await c.execute("SELECT category_id::text FROM events "
              "WHERE id = '$eBRent'"))
          .first[0] as String;
      await c.execute("INSERT INTO events (id, stream_id, name, direction, "
          "amount, start_date, recurrence_mode, end_mode, category_id) VALUES "
          "('00000000-0000-0000-0000-0000000035e9', '$_sA', 'tmp', 'debit', 1, "
          "'2026-01-01', 'once', 'never', '$other')");
      fail('expected cross-stream category to be rejected');
    } on ServerException catch (e) {
      expect(e.code, '23503');
    }

    // A name-only write creates the category in that stream only.
    await c.execute("INSERT INTO events (id, stream_id, name, direction, "
        "amount, start_date, recurrence_mode, end_mode) VALUES "
        "('00000000-0000-0000-0000-0000000035ea', '$_sA', 'Probe', 'debit', 1, "
        "'2026-01-01', 'once', 'never')");
    expect(
        (await c.execute("SELECT count(*) FROM categories "
                "WHERE name = 'Probe' AND stream_id = '$_sA'"))
            .first[0],
        1);
    expect(
        (await c.execute("SELECT count(*) FROM categories "
                "WHERE name = 'Probe' AND stream_id = '$_sB'"))
            .first[0],
        0);

    // Re-running the SQL is a no-op (idempotent).
    final sql =
        File('migrations/035_per_stream_categories.sql').readAsStringSync();
    for (final statement in splitSqlStatements(sql)) {
      await c.execute(statement);
    }
    expect((await c.execute('SELECT count(*) FROM categories')).first[0], 11);
    expect((await c.execute('SELECT count(*) FROM events')).first[0], 6);
  });
}
