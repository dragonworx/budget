// Migration 020 (pools -> streams, transactions -> events) keeps every row.
// Builds a scratch database at the 019 schema, fills it with data under the
// old names, applies the full migration set and checks counts, renamed
// objects, foreign keys and rewritten audit names. DB-backed
// (TEST_DATABASE_URL, default local budget_test); skipped without Postgres.
import 'dart:io';

import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

const _scratch = 'budget_mig020_test';

void main() {
  Connection? admin;
  Connection? db;
  late Directory oldMigrations;
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
      print('migration_020_test: no test DB ($e)');
      admin = null;
      db = null;
      return;
    }
    oldMigrations = Directory.systemTemp.createTempSync('mig019');
    for (final f in Directory('migrations').listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name.compareTo('020') < 0) {
        f.copySync('${oldMigrations.path}/$name');
      }
    }
  });

  tearDownAll(() async {
    await db?.close();
    if (admin != null) {
      await admin!.execute('DROP DATABASE IF EXISTS $_scratch');
      await admin!.close();
    }
    if (admin != null) oldMigrations.deleteSync(recursive: true);
  });

  Future<int> count(String sql) async =>
      (await db!.execute(sql)).first[0] as int;

  // (Later migrations' own foreign keys, e.g. 022's, are not counted.)
  test('020 renames pools/transactions and preserves all data', () async {
    if (db == null) return markTestSkipped('no test DB');
    final c = db!;
    // The Dart data migration 006 is written against the current schema
    // (streams); an empty pre-020 database has nothing to backfill.
    await c.execute('CREATE TABLE schema_migrations ('
        'id TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())');
    await c.execute("INSERT INTO schema_migrations (id) "
        "VALUES ('006_currency_scale_backfill')");
    await applyMigrations(c,
        migrationsDir: oldMigrations.path, adminEmail: 'boss@example.com');
    expect(
        await count("SELECT count(*) FROM schema_migrations "
            "WHERE id = '020_streams_events.sql'"),
        0);

    // Old-schema data covering every table the rename touches.
    await c.execute('''
      INSERT INTO users (id, email, is_admin, last_pool_id) VALUES
        ('00000000-0000-0000-0000-0000000000a1', 'boss@example.com', true, NULL),
        ('00000000-0000-0000-0000-0000000000a2', 'guest@example.com', false, NULL)
      ON CONFLICT (email) DO UPDATE SET is_admin = EXCLUDED.is_admin''');
    final ids = await c.execute(
        "SELECT id::text FROM users WHERE email IN ('boss@example.com','guest@example.com') ORDER BY email");
    final boss = ids[0][0] as String, guest = ids[1][0] as String;
    const pool = '00000000-0000-0000-0000-0000000000b1';
    const tx1 = '00000000-0000-0000-0000-0000000000c1';
    const tx2 = '00000000-0000-0000-0000-0000000000c2';
    for (final s in [
      "INSERT INTO allowed_emails (pattern) VALUES ('@example.com') ON CONFLICT DO NOTHING",
      "INSERT INTO sessions (id_hash, user_id, expires_at) VALUES ('\\x01', '$boss', now() + interval '1 day')",
      "INSERT INTO sessions (id_hash, user_id, expires_at) VALUES ('\\x02', '$guest', now() + interval '1 day')",
      "INSERT INTO pools (id, name, seed_balance, seed_date, owner_id, transaction_order) VALUES ('$pool', 'Main', 100, '2026-01-01', '$boss', ARRAY['$tx2','$tx1']::uuid[])",
      "UPDATE users SET last_pool_id = '$pool' WHERE id = '$boss'",
      "INSERT INTO pool_shares (pool_id, user_id, role, added_by) VALUES ('$pool', '$guest', 'editor', '$boss')",
      "INSERT INTO transactions (id, pool_id, name, direction, amount, start_date, recurrence_mode, end_mode) VALUES ('$tx1', '$pool', 'Rent', 'debit', 50, '2026-01-02', 'once', 'never')",
      "INSERT INTO transactions (id, pool_id, name, direction, amount, start_date, recurrence_mode, interval, unit, end_mode) VALUES ('$tx2', '$pool', 'Pay', 'credit', 70, '2026-01-03', 'every', 1, 'months', 'never')",
      "INSERT INTO skipped_occurrences (transaction_id, date) VALUES ('$tx2', '2026-02-03')",
      "INSERT INTO occurrence_overrides (transaction_id, date, amount, direction) VALUES ('$tx2', '2026-03-03', 80, 'credit')",
      "INSERT INTO pool_views (user_id, pool_id, start_day, visible_days) VALUES ('$guest', '$pool', 1, 30)",
      "INSERT INTO scenarios (id, pool_id, name, request) VALUES (gen_random_uuid(), '$pool', 'What if', '{}'::jsonb)",
      "INSERT INTO invites (id, token_hash, email, pool_id, role, invited_by, expires_at) VALUES (gen_random_uuid(), '\\x03', 'new@example.com', '$pool', 'viewer', '$boss', now() + interval '7 days')",
      "INSERT INTO audit_log (user_id, pool_id, action, entity, entity_id) VALUES ('$boss', '$pool', 'pool.created', 'pool', '$pool')",
      "INSERT INTO audit_log (user_id, pool_id, action, entity) VALUES ('$boss', '$pool', 'transactions.imported', 'transactions')",
      "INSERT INTO audit_log (user_id, pool_id, action, entity, entity_id) VALUES ('$boss', '$pool', 'transaction.updated', 'transaction', '$tx1')",
      "INSERT INTO audit_log (user_id, pool_id, action, entity) VALUES ('$boss', '$pool', 'pool_share.added', 'pool_share')",
      "INSERT INTO audit_log (user_id, action, entity, detail) VALUES ('$boss', 'transactions.transfers_deleted', 'transactions', '{\"deletedPoolId\": \"$pool\", \"ids\": []}'::jsonb)",
      "INSERT INTO audit_log (user_id, pool_id, action, entity) VALUES ('$boss', '$pool', 'skip.changed', 'skip')",
    ]) {
      await c.execute(s);
    }
    const tables = [
      'users',
      'sessions',
      'allowed_emails',
      'invites',
      'audit_log',
      'scenarios',
      'skipped_occurrences',
      'occurrence_overrides',
    ];
    final before = {
      for (final t in tables) t: await count('SELECT count(*) FROM $t')
    };
    final fksBefore =
        await count("SELECT count(*) FROM pg_constraint WHERE contype = 'f' "
            "AND conrelid::regclass::text <> 'event_trim_batches'");

    await applyMigrations(c, migrationsDir: 'migrations');
    // A second run is a no-op.
    await applyMigrations(c, migrationsDir: 'migrations');

    for (final t in tables) {
      expect(await count('SELECT count(*) FROM $t'), before[t], reason: t);
    }
    expect(await count('SELECT count(*) FROM streams'), 1);
    expect(await count('SELECT count(*) FROM events'), 2);
    expect(await count('SELECT count(*) FROM stream_shares'), 1);
    expect(await count('SELECT count(*) FROM stream_views'), 1);
    expect(await count('SELECT count(*) FROM users WHERE is_admin'), 1);
    expect(
        await count(
            "SELECT count(*) FROM users WHERE last_stream_id = '$pool'"),
        1);
    expect(
        await count("SELECT count(*) FROM pg_constraint WHERE contype = 'f' "
            "AND conrelid::regclass::text <> 'event_trim_batches'"),
        fksBefore);
    for (final old in ['pools', 'transactions', 'pool_shares', 'pool_views']) {
      expect((await c.execute("SELECT to_regclass('public.$old')")).first[0],
          isNull,
          reason: old);
    }
    // No schema object keeps an old name.
    expect(await count("""
          SELECT (SELECT count(*) FROM pg_class c JOIN pg_namespace n
                    ON n.oid = c.relnamespace
                  WHERE n.nspname = 'public'
                    AND c.relname ~ '(pool|transaction|account)')
               + (SELECT count(*) FROM pg_constraint
                  WHERE connamespace = 'public'::regnamespace
                    AND conname ~ '(pool|transaction|account)')
               + (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal
                    AND tgname ~ '(pool|transaction|account)')
               + (SELECT count(*) FROM information_schema.columns
                  WHERE table_schema = 'public'
                    AND column_name ~ '(pool|transaction|account)')
        """), 0);
    // Joins over the renamed keys still line up.
    final r = await c.execute('''
      SELECT s.name, e.name, s.event_order::text[]
      FROM streams s JOIN events e ON e.stream_id = s.id
      WHERE e.id = '$tx2' ''');
    expect(r.first[0], 'Main');
    expect(r.first[1], 'Pay');
    expect(r.first[2], [tx2, tx1]);
    expect(await count('''
      SELECT count(*) FROM skipped_occurrences k
      JOIN events e ON e.id = k.event_id'''), 1);
    expect(await count('''
      SELECT count(*) FROM occurrence_overrides o
      JOIN events e ON e.id = o.event_id'''), 1);
    expect(await count('''
      SELECT count(*) FROM stream_shares ss
      JOIN streams s ON s.id = ss.stream_id
      WHERE ss.role = 'editor' '''), 1);
    // Stored realtime/audit names follow the rename.
    final actions =
        (await c.execute('SELECT action, entity FROM audit_log ORDER BY id'))
            .map((row) => '${row[0]}|${row[1]}')
            .toList();
    expect(actions, [
      'stream.created|stream',
      'events.imported|events',
      'event.updated|event',
      'stream_share.added|stream_share',
      'events.transfers_deleted|events',
      'skip.changed|skip',
    ]);
    expect(
        await count("SELECT count(*) FROM audit_log "
            "WHERE detail->>'deletedStreamId' = '$pool' "
            "AND NOT detail ? 'deletedPoolId'"),
        1);
    // The bump-version trigger still fires on the renamed table.
    await c.execute("UPDATE events SET name = 'Rent 2' WHERE id = '$tx1'");
    expect(await count("SELECT version FROM events WHERE id = '$tx1'"), 2);
  });
}
