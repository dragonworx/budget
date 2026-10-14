import 'dart:io';

import 'package:budget_server/api/router.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main(List<String> args) async {
  final config = Config.fromEnvironment();
  final conn = await openConnection(config);

  final handler = buildHandler(conn);
  final server = await shelf_io.serve(handler, config.host, config.port);
  // ignore: avoid_print
  print('Budget API listening on http://${server.address.host}:${server.port}');

  ProcessSignal.sigint.watch().listen((_) async {
    await server.close(force: true);
    await conn.close();
    exit(0);
  });
}
