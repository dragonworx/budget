import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/google_verifier.dart';
import '../auth/jwks_cache.dart';
import '../auth/middleware.dart';
import '../auth/session_store.dart';
import '../config.dart';
import '../auth/authz_middleware.dart';
import '../db_scope.dart';
import '../realtime/event_bus.dart';
import 'events.dart';
import 'accounts.dart';
import 'admin.dart';
import 'sharing.dart';
import 'auth.dart';
import 'json_helpers.dart';
import 'projects.dart';
import 'transactions.dart';

Handler buildHandler(Session base, Config config,
    {GoogleIdTokenVerifier? verifier,
    EventBus? bus,
    EventsSettings eventsSettings = const EventsSettings()}) {
  final conn = base is ScopedDb ? base : ScopedDb(base);
  final root = Router();
  final sessions = SessionStore(conn,
      secret: config.sessionSecret, ttl: Duration(days: config.sessionTtlDays));

  root.get('/health', (Request request) async {
    try {
      await conn.execute('SELECT 1');
      return jsonOk({'ok': true});
    } catch (_) {
      return jsonError(503, 'database unavailable');
    }
  });
  root.mount(
      '/api/auth',
      buildAuthApi(
        config: config,
        db: conn,
        sessions: sessions,
        verifier: verifier ??
            GoogleIdTokenVerifier(
              clientId: config.googleClientId,
              jwks: JwksCache(httpJwksFetcher()),
            ),
      ).call);
  final projectsApi = buildProjectsApi(conn);
  attachProjectSharingRoutes(projectsApi, conn, config);
  final accountsApi = buildAccountsApi(conn);
  attachAccountSharingRoutes(accountsApi, conn, config);
  root.mount('/api/projects', projectsApi.call);
  root.mount('/api/accounts', accountsApi.call);
  root.mount('/api/invites', buildInvitesApi(conn, config).call);
  root.mount('/api/admin', buildAdminApi(conn, config, sessions).call);
  root.mount('/api/transactions', transactionsRouter(conn).call);
  root.mount('/api/events',
      buildEventsApi(conn, sessions, bus, settings: eventsSettings).call);

  return const Pipeline()
      .addMiddleware(corsMiddleware(config))
      .addMiddleware(noStoreApi())
      .addMiddleware(_errorMiddleware())
      .addMiddleware(logRequests())
      .addMiddleware(csrfMiddleware(config))
      .addMiddleware(authMiddleware(sessions))
      .addMiddleware(authzMiddleware(conn))
      .addHandler(root.call);
}

Middleware _errorMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      try {
        return await inner(request);
      } on FormatException catch (e) {
        return jsonError(400, e.message);
      } catch (e, st) {
        // ignore: avoid_print
        print('Unhandled error: $e\n$st');
        return jsonError(500, 'internal server error');
      }
    };
  };
}

/// API responses are live data: never let a browser, proxy or CDN cache them
/// (a cached GET after a delete makes the deleted item reappear on reload).
Middleware noStoreApi() {
  return (Handler inner) {
    return (Request request) async {
      final response = await inner(request);
      final path = '/${request.url.path}';
      if (!path.startsWith('/api') && path != '/health') return response;
      return response.change(headers: {
        'cache-control': 'no-store, no-cache, must-revalidate, max-age=0',
        'pragma': 'no-cache',
        'expires': '0',
      });
    };
  };
}
