import 'dart:io';

import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';

Future<void> main(List<String> args) async {
  final config = Config.fromEnvironment();
  final conn = await openConnection(config);

  // Prefer package-root/migrations (next to pubspec.yaml); fall back to CWD.
  final scriptDir = File(Platform.script.toFilePath()).parent;
  final packageRoot = scriptDir.parent;
  final candidates = [
    '${packageRoot.path}/migrations',
    '${Directory.current.path}/migrations',
    '${Directory.current.path}/server/migrations',
  ];
  final migrationsDir = candidates.firstWhere(
    (path) => Directory(path).existsSync(),
    orElse: () => candidates.first,
  );

  try {
    await applyMigrations(conn, migrationsDir: migrationsDir);
    // ignore: avoid_print
    print('Migrations applied successfully.');
    exitCode = 0;
  } catch (e, st) {
    stderr.writeln('Migration failed: $e\n$st');
    exitCode = 1;
  } finally {
    await conn.close();
  }
}
