// Reconciler for spec 010's variables: re-derives `variable_refs` and
// re-resolves every formula, printing any drift (exit 1 if there is any).
// Read-only in effect: the re-resolution runs in a transaction that is
// always rolled back.
//
//   DATABASE_URL=postgres://budget:budget@127.0.0.1:5432/budget \
//     dart run tool/verify_variables.dart
import 'dart:io';

import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/domain/variable_verify.dart';

Future<void> main() async {
  final url = Platform.environment['DATABASE_URL'];
  if (url == null) {
    stderr.writeln('DATABASE_URL is required');
    exit(2);
  }
  final conn =
      await openConnection(Config(databaseUrl: url, host: '', port: 0));
  try {
    final drift = await verifyVariables(conn);
    final counts =
        (await conn.execute('SELECT (SELECT count(*) FROM variables), '
                '(SELECT count(*) FROM variable_refs)'))
            .first;
    stdout.writeln('variables: ${counts[0]}, refs: ${counts[1]}, '
        'drift: ${drift.length}');
    for (final d in drift) {
      stdout.writeln('  $d');
    }
    exitCode = drift.isEmpty ? 0 : 1;
  } finally {
    await conn.close();
  }
}
