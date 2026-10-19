import 'package:shelf/shelf.dart';

import '../api/json_helpers.dart';
import '../config.dart';
import '../hardening/logging.dart';
import '../repo/user_repo.dart';
import 'session_store.dart';

const sessionCookie = 'budget_session';

class AuthContext {
  AuthContext(this.user, this.token, {this.isDev = false});
  final User user;
  final String token;
  final bool isDev;
}

/// The signed-in user for [request] (set by [authMiddleware]).
AuthContext? authOf(Request request) => request.context['auth'] as AuthContext?;

AuthContext requireAuth(Request request) {
  final a = authOf(request);
  if (a == null) throw StateError('route reached without authentication');
  return a;
}

String? sessionTokenFrom(Request request) {
  final authz = request.headers['authorization'];
  if (authz != null && authz.toLowerCase().startsWith('bearer ')) {
    return authz.substring(7).trim();
  }
  return cookieValue(request, sessionCookie);
}

/// Value of cookie [name] on [request], or null.
String? cookieValue(Request request, String name) {
  final cookie = request.headers['cookie'];
  if (cookie == null) return null;
  for (final part in cookie.split(';')) {
    final i = part.indexOf('=');
    if (i < 0) continue;
    if (part.substring(0, i).trim() == name) {
      return part.substring(i + 1).trim();
    }
  }
  return null;
}

/// GIS redirect-mode `login_uri`: a cross-site form POST from Google,
/// protected by its own double-submit token instead of the Origin check.
const googleRedirectPath = '/api/auth/google/redirect';

String sessionCookieHeader(Config config, String token, {bool clear = false}) {
  final parts = [
    '$sessionCookie=${clear ? '' : token}',
    'Path=/',
    'HttpOnly',
    'SameSite=Lax',
    clear ? 'Max-Age=0' : 'Max-Age=${config.sessionTtlDays * 86400}',
    if (config.secureCookies) 'Secure',
  ];
  return parts.join('; ');
}

bool _isPublic(String path) =>
    path == '/health' || path.startsWith('/api/auth/') || path == '/api/auth';

bool _isApi(String path) => path == '/api' || path.startsWith('/api/');

/// CORS limited to [Config.allowedOrigins], with credentials.
Middleware corsMiddleware(Config config) {
  final allowed = config.allowedOrigins;
  Map<String, String> headersFor(String? origin) => {
        if (origin != null && allowed.contains(origin)) ...{
          'access-control-allow-origin': origin,
          'access-control-allow-credentials': 'true',
          'vary': 'Origin',
        },
        'access-control-allow-methods':
            'GET,HEAD,PUT,PATCH,POST,DELETE,OPTIONS',
        'access-control-allow-headers':
            'Origin,Content-Type,Accept,Authorization,Cache-Control,Pragma,'
                'X-Requested-With,X-Client-Id,If-Match',
        'access-control-max-age': '600',
      };
  return (inner) => (request) async {
        final origin = request.headers['origin'];
        if (request.method == 'OPTIONS') {
          return Response.ok(null, headers: headersFor(origin));
        }
        final res = await inner(request);
        return res.change(headers: headersFor(origin));
      };
}

/// CSRF defence for cookie-authenticated unsafe requests: a present Origin
/// must be allowed; without Origin, require `X-Requested-With`, a JSON
/// content type, or bearer auth (none of which a plain form can send).
Middleware csrfMiddleware(Config config) {
  const safe = {'GET', 'HEAD', 'OPTIONS'};
  return (inner) => (request) async {
        final path = '/${request.url.path}';
        if (safe.contains(request.method) ||
            !_isApi(path) ||
            (path == googleRedirectPath && request.method == 'POST')) {
          return inner(request);
        }
        final origin = request.headers['origin'];
        if (origin != null) {
          if (!config.allowedOrigins.contains(origin)) {
            return jsonError(403, 'origin not allowed');
          }
          return inner(request);
        }
        final h = request.headers;
        final ok = h['x-requested-with'] != null ||
            (h['content-type'] ?? '').contains('application/json') ||
            (h['authorization'] ?? '').toLowerCase().startsWith('bearer ');
        if (!ok) return jsonError(403, 'missing CSRF header');
        return inner(request);
      };
}

/// Resolves the session; `/api/*` (except `/api/auth/*`) requires one.
Middleware authMiddleware(SessionStore sessions) {
  return (inner) => (request) async {
        final path = '/${request.url.path}';
        final token = sessionTokenFrom(request);
        SessionInfo? info;
        if (token != null && token.isNotEmpty) {
          info = await sessions.lookup(token);
        }
        if (info == null) {
          if (_isApi(path) && !_isPublic(path)) {
            return jsonError(401, 'authentication required');
          }
          return inner(request);
        }
        requestInfoOf(request)?.userId = info.user.id;
        return inner(request.change(context: {
          'auth': AuthContext(info.user, token!, isDev: info.isDev),
        }));
      };
}
