import 'dart:async';
import 'dart:io';

import 'package:budget_server/api/router.dart';
import 'package:budget_server/auth/session_store.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/hardening/cleanup.dart';
import 'package:budget_server/hardening/lifecycle.dart';
import 'package:budget_server/hardening/logging.dart';
import 'package:budget_server/realtime/event_bus.dart';
import 'package:budget_server/realtime/pg_listener.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main(List<String> args) async {
  final log = Log();
  final config = Config.fromEnvironment(loadEnvironment());
  try {
    config.validate();
  } on StateError catch (e) {
    log.error('refusing to start', {'reason': e.message});
    exit(78);
  }
  if (config.devBypass) {
    log.warn('AUTH_DEV_BYPASS is ON: /api/auth/dev-login signs in as '
        '${config.primaryAdminEmail}. Never enable this in production.');
  }
  final pool = openPool(config);
  await pool.execute('SELECT 1');

  final sessions = SessionStore(pool,
      secret: config.sessionSecret,
      ttl: Duration(days: config.sessionTtlDays),
      cacheTtl: config.sessionCacheTtl);
  final bus = EventBus();
  final listener = PgListener(() => openConnection(config), bus,
      onLog: (m) => log.info(m),
      extraChannels: {
        SessionStore.invalidationChannel: sessions.handleInvalidation,
      },
      // Invalidations may have been missed while disconnected.
      onReconnect: sessions.clearCache)
    ..start();
  await listener.ready.timeout(const Duration(seconds: 10));

  final lifecycle = Lifecycle();
  final handler = buildHandler(pool, config,
      bus: bus,
      sessions: sessions,
      log: log,
      lifecycle: lifecycle, readiness: () async {
    await pool.execute('SELECT 1');
    final ok = listener.connected;
    return {'ok': ok, 'db': true, 'listener': ok};
  });
  final server = await shelf_io.serve(handler, config.host, config.port);
  server.idleTimeout = const Duration(seconds: 30);
  final cleanup =
      CleanupJob(pool, sessions, log, interval: config.cleanupInterval)
        ..start();
  log.info('listening', {
    'url': 'http://${server.address.host}:${server.port}',
    'env': config.appEnv,
    'sessionCacheSeconds': config.sessionCacheTtl.inSeconds,
  });

  var stopping = false;
  Future<void> shutdown(String signal) async {
    if (stopping) return;
    stopping = true;
    final grace = config.shutdownGrace;
    log.info('shutdown: draining',
        {'signal': signal, 'graceSeconds': grace.inSeconds});
    // 1. Fail /ready so the proxy stops routing here; stop accepting.
    lifecycle.startDraining();
    cleanup.stop();
    final closing = server.close(); // waits for open connections
    // 2. SSE clients: 'reconnect' event, then their streams close.
    bus.shutdown('server shutting down');
    // 3. Drain in-flight requests (bounded), then force-close leftovers.
    final drained = await lifecycle.waitIdle(grace);
    await closing.timeout(const Duration(seconds: 2), onTimeout: () async {
      await server.close(force: true);
    });
    // 4. Realtime listener and stream.
    await listener.stop();
    await pool.close();
    log.info(
        'shutdown: done', {'drained': drained, 'inFlight': lifecycle.inFlight});
    exit(0);
  }

  for (final sig in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    sig.watch().listen((s) => unawaited(shutdown(s.toString())));
  }
}
