import 'dart:io';

import 'package:budget_server/api/router.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/realtime/event_bus.dart';
import 'package:budget_server/realtime/pg_listener.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main(List<String> args) async {
  final config = Config.fromEnvironment(loadEnvironment());
  try {
    config.validate();
  } on StateError catch (e) {
    stderr.writeln('Refusing to start: ${e.message}');
    exit(78);
  }
  if (config.devBypass) {
    // ignore: avoid_print
    print('*** AUTH_DEV_BYPASS is ON: /api/auth/dev-login signs in as '
        '${config.primaryAdminEmail}. Never enable this in production. ***');
  }
  final conn = openPool(config);
  await conn.execute('SELECT 1');

  final bus = EventBus();
  final listener = PgListener(() => openConnection(config), bus,
      // ignore: avoid_print
      onLog: print)
    ..start();
  await listener.ready.timeout(const Duration(seconds: 10));

  final handler = buildHandler(conn, config, bus: bus);
  final server = await shelf_io.serve(handler, config.host, config.port);
  // ignore: avoid_print
  print('Budget API listening on http://${server.address.host}:${server.port}');

  for (final sig in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    sig.watch().listen((_) async {
      await listener.stop();
      await server.close(force: true);
      await conn.close();
      exit(0);
    });
  }
}
