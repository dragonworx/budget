// Migration 036 (per-user stream order) on a scratch database at the 035
// schema: existing accessible streams are backfilled in the previous
// default order (owned first by display_order, then shared by name),
// creates append, shares append, and deletes / revoked shares prune.
// DB-backed (TEST_DATABASE_URL, default local budget_test); skipped
// without Postgres.
import 'dart:io';

import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

const _scratch = 'budget_mig036_test';
const _owner = '00000000-0000-0000-0000-0000000036a1';
const _viewer = '00000000-0000-0000-0000-0000000036a2';
const _sA = '00000000-0000-0000-0000-0000000036b1';
const _sB = '00000000-0000-0000-0000-0000000036b2';
const _sC = '00000000-0000-0000-0000-0000000036b3';
const _sD = '00000000-0000-0000-0000-0000000036b4';

void main() {
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
      print('migration_036_test: no test DB ($e)');
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

  test('036 backfills default order and maintains it on write', () async {
    if (db == null) return markTestSkipped('no test DB');
    final c = db!;
    await applyMigrationsThrough(c, through: '035');

    await c.execute("INSERT INTO users (id, email) VALUES "
        "('$_owner', 'own@x.io'), ('$_viewer', 'vi@x.io')");
    // B before A by display_order for the owner; C (also owned) is last
    // by display_order and is shared with the viewer.
    await c.execute("INSERT INTO streams (id, name, seed_balance, seed_date, "
        "owner_id, display_order) VALUES "
        "('$_sA', 'Zebra', 0, '2026-01-01', '$_owner', 2), "
        "('$_sB', 'Alpha', 0, '2026-01-01', '$_owner', 1), "
        "('$_sC', 'Shared', 0, '2026-01-01', '$_owner', 3)");
    await c.execute("INSERT INTO stream_shares (stream_id, user_id, role) "
        "VALUES ('$_sC', '$_viewer', 'viewer')");

    await applyMigrations(c, migrationsDir: 'migrations');

    Future<List<String>> order(String userId) async {
      final rows = await c.execute(
          "SELECT id::text FROM unnest((SELECT stream_order FROM users "
          "WHERE id = '$userId')) AS id");
      return [for (final r in rows) r[0] as String];
    }

    expect(await order(_owner), [_sB, _sA, _sC]);
    expect(await order(_viewer), [_sC]);

    // New owned stream is appended for the owner only.
    await c.execute("INSERT INTO streams (id, name, seed_balance, seed_date, "
        "owner_id) VALUES "
        "('$_sD', 'New', 0, '2026-01-01', '$_owner')");
    expect(await order(_owner), [_sB, _sA, _sC, _sD]);
    expect(await order(_viewer), [_sC]);

    // A new share appends for that viewer; a second insert conflict
    // path isn't exercised here. Revoke prunes only the viewer.
    await c.execute("INSERT INTO stream_shares (stream_id, user_id, role) "
        "VALUES ('$_sA', '$_viewer', 'viewer')");
    expect(await order(_viewer), [_sC, _sA]);
    await c.execute("DELETE FROM stream_shares "
        "WHERE stream_id = '$_sA' AND user_id = '$_viewer'");
    expect(await order(_viewer), [_sC]);

    // Deleting a stream prunes every user that listed it.
    await c.execute("DELETE FROM streams WHERE id = '$_sC'");
    expect(await order(_owner), [_sB, _sA, _sD]);
    expect(await order(_viewer), isEmpty);

    // Re-running the SQL is a no-op (existing orders are kept).
    final sql = File('migrations/036_user_stream_order.sql').readAsStringSync();
    for (final statement in splitSqlStatements(sql)) {
      await c.execute(statement);
    }
    expect(await order(_owner), [_sB, _sA, _sD]);
    expect(await order(_viewer), isEmpty);
  });
}
