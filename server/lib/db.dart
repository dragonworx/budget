import 'dart:io';

import 'package:postgres/postgres.dart';

import 'config.dart';

/// Opens a Postgres connection from [Config.databaseUrl].
Future<Connection> openConnection(Config config) async {
  final uri = Uri.parse(config.databaseUrl);
  final userInfo = uri.userInfo.split(':');
  final username = userInfo.isNotEmpty ? Uri.decodeComponent(userInfo.first) : '';
  final password = userInfo.length > 1
      ? Uri.decodeComponent(userInfo.sublist(1).join(':'))
      : '';

  final database = uri.path.isNotEmpty
      ? uri.path.replaceFirst('/', '')
      : 'budget';

  return Connection.open(
    Endpoint(
      host: uri.host.isEmpty ? 'localhost' : uri.host,
      port: uri.hasPort ? uri.port : 5432,
      database: database,
      username: username,
      password: password,
    ),
    settings: const ConnectionSettings(
      sslMode: SslMode.disable,
    ),
  );
}

/// Applies pending SQL files from [migrationsDir] in name order.
Future<void> applyMigrations(
  Connection conn, {
  required String migrationsDir,
}) async {
  await conn.execute('''
    CREATE TABLE IF NOT EXISTS schema_migrations (
      id TEXT PRIMARY KEY,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  ''');

  final dir = Directory(migrationsDir);
  if (!await dir.exists()) {
    throw StateError('Migrations directory not found: $migrationsDir');
  }

  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.sql'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in files) {
    final id = file.uri.pathSegments.last;
    final existing = await conn.execute(
      Sql.named('SELECT 1 FROM schema_migrations WHERE id = @id'),
      parameters: {'id': id},
    );
    if (existing.isNotEmpty) continue;

    final sql = await file.readAsString();
    final statements = splitSqlStatements(sql);
    await conn.runTx((session) async {
      for (final statement in statements) {
        await session.execute(statement);
      }
      await session.execute(
        Sql.named(
          'INSERT INTO schema_migrations (id) VALUES (@id) ON CONFLICT DO NOTHING',
        ),
        parameters: {'id': id},
      );
    });
  }
}

/// Splits a SQL file into individual statements (no procedure bodies expected).
List<String> splitSqlStatements(String sql) {
  final withoutComments = sql
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('--'))
      .join('\n');
  return withoutComments
      .split(';')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}
