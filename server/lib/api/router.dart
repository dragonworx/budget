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
import '../hardening/client_ip.dart';
import '../hardening/lifecycle.dart';
import '../hardening/logging.dart';
import '../hardening/rate_limit.dart';
import '../hardening/security_headers.dart';
import 'pools.dart';
import 'admin.dart';
import 'sharing.dart';
import 'auth.dart';
import 'json_helpers.dart';
import 'transactions.dart';

Handler buildHandler(Session base, Config config,
    {GoogleIdTokenVerifier? verifier,
    EventBus? bus,
    EventsSettings eventsSettings = const EventsSettings(),
    SessionStore? sessions,
    Log? log,
    Lifecycle? lifecycle,
    Future<Map<String, Object?>> Function()? readiness}) {
  final conn = base is ScopedDb ? base : ScopedDb(base);
  final root = Router();
  log ??= Log();
  lifecycle ??= Lifecycle();
  sessions ??= SessionStore(conn,
      secret: config.sessionSecret,
      ttl: Duration(days: config.sessionTtlDays),
      cacheTtl: config.sessionCacheTtl);
  final lc = lifecycle;

  // Readiness: DB reachable, realtime listener up, not draining. Used by
  // Compose healthchecks and Caddy's active health checks.
  root.get('/ready', (Request request) async {
    if (lc.draining) return jsonError(503, 'draining', details: {'ok': false});
    final Map<String, Object?> status;
    try {
      status = readiness != null
          ? await readiness().timeout(const Duration(seconds: 3))
          : (await conn
              .execute('SELECT 1')
              .then((_) => {'ok': true, 'db': true}));
    } catch (e) {
      return jsonError(503, 'not ready', details: {'ok': false, 'db': false});
    }
    return status['ok'] == true
        ? jsonOk(status)
        : jsonError(503, 'not ready', details: status);
  });

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
  final poolsApi = buildPoolsApi(conn);
  attachPoolSharingRoutes(poolsApi, conn, config);
  root.mount('/api/pools', poolsApi.call);
  root.mount('/api/invites', buildInvitesApi(conn, config).call);
  root.mount('/api/admin', buildAdminApi(conn, config, sessions).call);
  root.mount('/api/transactions', transactionsRouter(conn).call);
  root.mount('/api/events',
      buildEventsApi(conn, sessions, bus, settings: eventsSettings).call);

  return const Pipeline()
      .addMiddleware(requestLogging(
          log, ClientIpResolver(config.trustedProxies),
          quiet: (r) => r.url.path == 'health' || r.url.path == 'ready'))
      .addMiddleware(securityHeaders(hsts: config.secureCookies))
      .addMiddleware(corsMiddleware(config))
      .addMiddleware(lc.middleware())
      .addMiddleware(noStoreApi())
      .addMiddleware(_errorMiddleware(log))
      .addMiddleware(rateLimitMiddleware(
          auth: RateLimiter(config.rateLimitAuthPerMinute),
          general: RateLimiter(config.rateLimitPerMinute)))
      .addMiddleware(csrfMiddleware(config))
      .addMiddleware(removedApi(removedApiPrefixes))
      .addMiddleware(authMiddleware(sessions))
      .addMiddleware(authzMiddleware(conn))
      .addHandler(root.call);
}

Middleware _errorMiddleware(Log log) {
  return (Handler inner) {
    return (Request request) async {
      try {
        return await inner(request);
      } on FormatException catch (e) {
        return jsonError(400, e.message);
      } catch (e, st) {
        final id = requestInfoOf(request)?.id;
        log.error('unhandled', {
          'reqId': id,
          'method': request.method,
          'path': '/${request.url.path}',
          'error': e.toString(),
          'stack': st.toString().split('\n').take(8).join('\n'),
        });
        return jsonError(500, 'internal server error',
            details: {'requestId': id});
      }
    };
  };
}

/// API route families that no longer exist. A browser tab still running an
/// older client build calls them; it gets 410 with a "please reload" message
/// (which old builds show as is) instead of a bare 404.
const removedApiPrefixes = ['/api/projects', '/api/accounts'];

Middleware removedApi(List<String> prefixes) {
  return (Handler inner) {
    return (Request request) {
      final path = '/${request.url.path}';
      final gone = prefixes.any((p) => path == p || path.startsWith('$p/'));
      if (!gone) return inner(request);
      return jsonError(410, 'Budgie was updated. Please reload the page.',
          details: {'code': 'client_outdated'});
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
      if (!path.startsWith('/api') && path != '/health' && path != '/ready') {
        return response;
      }
      return response.change(headers: {
        'cache-control':
            'no-store, no-cache, must-revalidate, max-age=0, no-transform',
        'pragma': 'no-cache',
        'expires': '0',
      });
    };
  };
}
