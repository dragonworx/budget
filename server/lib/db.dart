import 'dart:io';

import 'package:postgres/postgres.dart';

import 'repo/bare_variable_names.dart';
import 'repo/currency_scale_backfill.dart';

import 'config.dart';

/// Parses [Config.databaseUrl] into an endpoint + SSL mode.
(Endpoint, SslMode) parseDatabaseUrl(String url) {
  final uri = Uri.parse(url);
  final userInfo = uri.userInfo.split(':');
  final username =
      userInfo.isNotEmpty ? Uri.decodeComponent(userInfo.first) : '';
  final password = userInfo.length > 1
      ? Uri.decodeComponent(userInfo.sublist(1).join(':'))
      : '';
  final database =
      uri.path.isNotEmpty ? uri.path.replaceFirst('/', '') : 'budget';
  return (
    Endpoint(
      host: uri.host.isEmpty ? 'localhost' : uri.host,
      port: uri.hasPort ? uri.port : 5432,
      database: database,
      username: username,
      password: password,
    ),
    (uri.queryParameters['sslmode'] ?? 'disable') == 'disable'
        ? SslMode.disable
        : SslMode.require,
  );
}

/// Opens a connection pool (the API server's shared DB handle).
Pool<void> openPool(Config config) {
  final (endpoint, ssl) = parseDatabaseUrl(config.databaseUrl);
  return Pool.withEndpoints(
    [endpoint],
    settings: PoolSettings(
      maxConnectionCount: config.dbPoolSize,
      sslMode: ssl,
    ),
  );
}

/// Opens a single Postgres connection from [Config.databaseUrl].
Future<Connection> openConnection(Config config) async {
  final (endpoint, ssl) = parseDatabaseUrl(config.databaseUrl);
  return Connection.open(endpoint, settings: ConnectionSettings(sslMode: ssl));
}

/// Applies pending SQL files from [migrationsDir] in name order.
Future<void> applyMigrations(
  Connection conn, {
  required String migrationsDir,
  String adminEmail = Config.defaultAdminEmail,
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
      // Settings readable by migrations via current_setting('budget.*').
      await session.execute(
        Sql.named("SELECT set_config('budget.admin_email', @e, true)"),
        parameters: {'e': adminEmail.toLowerCase()},
      );
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

  // Data migrations (Dart), each run once after the SQL files.
  for (final entry in _dataMigrations.entries) {
    final done = await conn.execute(
      Sql.named('SELECT 1 FROM schema_migrations WHERE id = @id'),
      parameters: {'id': entry.key},
    );
    if (done.isNotEmpty) continue;
    await conn.runTx((session) async {
      // False: its prerequisites aren't there yet (not recorded, so it
      // runs once they are).
      if (!await entry.value(session)) return;
      await session.execute(
        Sql.named('INSERT INTO schema_migrations (id) VALUES (@id) '
            'ON CONFLICT DO NOTHING'),
        parameters: {'id': entry.key},
      );
    });
  }
}

/// Applies SQL files from [migrationsDir] whose names sort before the
/// next prefix after [through] (e.g. `through: '031'` applies 000–031,
/// not 032+). Historical migration tests should use this so a later
/// schema change (such as 035 dropping `categories.owner_id`) does not
/// break their post-conditions.
Future<void> applyMigrationsThrough(
  Connection conn, {
  required String through,
  String migrationsDir = 'migrations',
  String adminEmail = Config.defaultAdminEmail,
}) async {
  final next = (int.parse(through) + 1).toString().padLeft(through.length, '0');
  final tmp = Directory.systemTemp.createTempSync('mig_through_$through');
  try {
    for (final f in Directory(migrationsDir).listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name.endsWith('.sql') && name.compareTo(next) < 0) {
        f.copySync('${tmp.path}/$name');
      }
    }
    await applyMigrations(
      conn,
      migrationsDir: tmp.path,
      adminEmail: adminEmail,
    );
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

final _dataMigrations = <String, Future<bool> Function(Session)>{
  '006_currency_scale_backfill': (s) async {
    await backfillCurrencyScales(s);
    return true;
  },
  '029_bare_variable_names': (s) => migrateBareVariableNames(s),
};

/// Splits a SQL file into statements on `;`, keeping `$$ ... $$` bodies
/// (plpgsql functions) intact. Whole-line `--` comments are dropped.
List<String> splitSqlStatements(String sql) {
  final text = sql
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('--'))
      .join('\n');
  final out = <String>[];
  final buf = StringBuffer();
  var inDollar = false;
  for (var i = 0; i < text.length; i++) {
    if (text.startsWith(r'$$', i)) {
      inDollar = !inDollar;
      buf.write(r'$$');
      i++;
      continue;
    }
    final ch = text[i];
    if (ch == ';' && !inDollar) {
      out.add(buf.toString());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  out.add(buf.toString());
  return out.map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
}
