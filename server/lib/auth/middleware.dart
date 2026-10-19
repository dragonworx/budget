import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

import '../api/json_helpers.dart';
import '../config.dart';
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
  final cookie = request.headers['cookie'];
  if (cookie == null) return null;
  for (final part in cookie.split(';')) {
    final i = part.indexOf('=');
    if (i < 0) continue;
    if (part.substring(0, i).trim() == sessionCookie) {
      return part.substring(i + 1).trim();
    }
  }
  return null;
}

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
        if (safe.contains(request.method) || !_isApi(path)) {
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
        return inner(request.change(context: {
          'auth': AuthContext(info.user, token!, isDev: info.isDev),
        }));
      };
}

final _uuidRe = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false);

/// P1 tenancy guard: every `/api/projects/<id>`, `/api/accounts/<id>` and
/// `/api/transactions/<id>` route (and any `transferToAccountId` in a body)
/// must belong to a project owned by the signed-in user; otherwise 404.
/// P3 replaces this with role-based checks via project membership.
Middleware ownershipMiddleware(Session db) {
  return (inner) => (request) async {
        final auth = authOf(request);
        final seg = request.url.pathSegments;
        if (auth == null || seg.length < 3 || seg[0] != 'api') {
          return inner(request);
        }
        final kind = seg[1];
        const queries = {
          'projects': 'SELECT 1 FROM projects p WHERE p.id = @id::uuid '
              'AND p.owner_id = @u::uuid',
          'accounts': 'SELECT 1 FROM accounts a JOIN projects p '
              'ON p.id = a.project_id WHERE a.id = @id::uuid AND p.owner_id = @u::uuid',
          'transactions': 'SELECT 1 FROM transactions t JOIN accounts a '
              'ON a.id = t.account_id JOIN projects p ON p.id = a.project_id '
              'WHERE t.id = @id::uuid AND p.owner_id = @u::uuid',
        };
        final q = queries[kind];
        if (q == null) return inner(request);
        Future<bool> owns(String sql, String id) async {
          if (!_uuidRe.hasMatch(id)) return false;
          final r = await db.execute(Sql.named(sql),
              parameters: {'id': id, 'u': auth.user.id});
          return r.isNotEmpty;
        }

        if (!await owns(q, seg[2])) {
          return jsonError(
              404, '${kind.substring(0, kind.length - 1)} not found');
        }

        // Transfers must target an account the user also owns.
        if ((request.method == 'POST' || request.method == 'PATCH') &&
            (kind == 'accounts' || kind == 'transactions')) {
          final raw = await request.readAsString();
          request = request.change(body: raw);
          if (raw.contains('transferToAccountId')) {
            Object? decoded;
            try {
              decoded = jsonDecode(raw);
            } catch (_) {}
            final to = decoded is Map ? decoded['transferToAccountId'] : null;
            if (to != null && !await owns(queries['accounts']!, '$to')) {
              return jsonError(404, 'transfer account not found');
            }
          }
        }
        return inner(request);
      };
}
