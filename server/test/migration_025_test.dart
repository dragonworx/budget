// Migration 025 (global categories) on a scratch database at the 024
// schema: each owner's per-stream categories with the same name (any case)
// merge into one (the earliest made keeps its name, colour and hidden
// flag), events are repointed, nothing is lost, owners stay apart; the
// name trigger maps by the owner's set afterwards. DB-backed
// (TEST_DATABASE_URL, default local budget_test); skipped without Postgres.
import 'dart:io';

import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

const _scratch = 'budget_mig025_test';
const _o1 = '00000000-0000-0000-0000-0000000025a1';
const _o2 = '00000000-0000-0000-0000-0000000025a2';
const _s1 = '00000000-0000-0000-0000-0000000025b1';
const _s2 = '00000000-0000-0000-0000-0000000025b2';
const _s3 = '00000000-0000-0000-0000-0000000025b3';

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
      print('migration_025_test: no test DB ($e)');
      admin = null;
      db = null;
      return;
    }
    old = Directory.systemTemp.createTempSync('mig024');
    for (final f in Directory('migrations').listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name.compareTo('025') < 0) f.copySync('${old.path}/$name');
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

  test('025 merges same-named categories per owner, keeps every event',
      () async {
    if (db == null) return markTestSkipped('no test DB');
    final c = db!;
    await applyMigrations(c, migrationsDir: old.path);
    for (final (u, e) in [(_o1, 'a@x.io'), (_o2, 'b@x.io')]) {
      await c.execute("INSERT INTO users (id, email) VALUES ('$u', '$e')");
    }
    for (final (s, o) in [(_s1, _o1), (_s2, _o1), (_s3, _o2)]) {
      await c.execute("INSERT INTO streams (id, name, seed_balance, seed_date, "
          "owner_id) VALUES ('$s', 'S$s', 0, '2026-01-01', '$o')");
    }
    var n = 0;
    Future<String> ev(String stream, String name, {String? color}) async {
      final id = '00000000-0000-0000-0000-${(++n).toString().padLeft(12, '0')}';
      await c.execute(
        Sql.named('INSERT INTO events (id, stream_id, name, direction, amount, '
            'start_date, recurrence_mode, end_mode, color, created_at) '
            "VALUES (@id::uuid, @s::uuid, @n, 'debit', 10, '2026-01-01', "
            "'once', 'never', @c, now() + make_interval(secs => @i))"),
        parameters: {'id': id, 's': stream, 'n': name, 'c': color, 'i': n},
      );
      return id;
    }

    // Owner 1: Rent in both streams (S1's is older, green; S2's "RENT" is
    // pink and hidden), Wages only in S2. Owner 2: its own Rent.
    final r1 = await ev(_s1, 'Rent', color: '#5B7A2A');
    await c.execute("UPDATE categories SET created_at = now() - interval '1 h'"
        " WHERE stream_id = '$_s1'");
    final r2 = await ev(_s2, 'RENT', color: '#B8488E');
    await c.execute("UPDATE categories SET hidden = true "
        "WHERE stream_id = '$_s2' AND name = 'RENT'");
    final w = await ev(_s2, 'Wages');
    final r3 = await ev(_s3, 'Rent', color: '#3D6FD8');
    final eventsBefore =
        (await c.execute('SELECT count(*) FROM events')).first[0];
    expect((await c.execute('SELECT count(*) FROM categories')).first[0], 4);
    final versions =
        await c.execute('SELECT id::text, version FROM events ORDER BY id');

    await applyMigrations(c, migrationsDir: 'migrations');

    expect((await c.execute('SELECT count(*) FROM events')).first[0],
        eventsBefore);
    expect([
      for (final r in await c
          .execute('SELECT id::text, version FROM events ORDER BY id'))
        r.toList()
    ], [
      for (final r in versions) r.toList()
    ]);
    final cats = await c.execute('SELECT owner_id::text, name, color, hidden '
        'FROM categories ORDER BY owner_id, name');
    expect([
      for (final r in cats) r.toList()
    ], [
      [_o1, 'Rent', '#5B7A2A', false],
      [_o1, 'Wages', isA<String>(), false],
      [_o2, 'Rent', '#3D6FD8', false],
    ]);
    Future<List<Object?>> catOf(String id) async => (await c
            .execute('SELECT c.owner_id::text, c.name, e.name FROM events e '
                "JOIN categories c ON c.id = e.category_id WHERE e.id = '$id'"))
        .first
        .toList();
    expect(await catOf(r1), [_o1, 'Rent', 'Rent']);
    expect(await catOf(r2), [_o1, 'Rent', 'Rent'], reason: 'name follows');
    expect(await catOf(w), [_o1, 'Wages', 'Wages']);
    expect(await catOf(r3), [_o2, 'Rent', 'Rent']);
    // One category, two streams.
    expect(
        (await c.execute("SELECT count(DISTINCT category_id) FROM events "
                "WHERE stream_id IN ('$_s1', '$_s2') AND name = 'Rent'"))
            .first[0],
        1);

    // Legacy name writes map to the owner's set (any stream), or create.
    final again = await ev(_s2, ' rent ');
    expect(await catOf(again), [_o1, 'Rent', 'Rent']);
    final fresh = await ev(_s1, 'Fuel');
    expect((await catOf(fresh))[0], _o1);
    // Another owner's category is refused.
    final o2Rent = (await c
            .execute("SELECT id::text FROM categories WHERE owner_id = '$_o2'"))
        .first[0];
    await expectLater(
        c.execute("UPDATE events SET category_id = '$o2Rent' "
            "WHERE id = '$r1'"),
        throwsA(isA<ServerException>()));
    // Unique per owner.
    await expectLater(
        c.execute("INSERT INTO categories (owner_id, name, color) "
            "VALUES ('$_o1', 'WAGES', '#3D6FD8')"),
        throwsA(isA<ServerException>()));
    // A second run is a no-op.
    await applyMigrations(c, migrationsDir: 'migrations');
    expect((await c.execute('SELECT count(*) FROM categories')).first[0], 4);
  });
}
