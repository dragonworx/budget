import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_router/shelf_router.dart';

import 'accounts.dart';
import 'json_helpers.dart';
import 'projects.dart';
import 'transactions.dart';

Handler buildHandler(Connection conn) {
  final root = Router();

  root.get('/health', (Request request) => jsonOk({'ok': true}));
  root.mount('/api/projects', buildProjectsApi(conn).call);
  root.mount('/api/accounts', buildAccountsApi(conn).call);
  root.mount('/api/transactions', transactionsRouter(conn).call);

  return const Pipeline()
      .addMiddleware(corsHeaders(
        headers: {
          ACCESS_CONTROL_ALLOW_ORIGIN: '*',
          ACCESS_CONTROL_ALLOW_METHODS:
              'GET,HEAD,PUT,PATCH,POST,DELETE,OPTIONS',
          ACCESS_CONTROL_ALLOW_HEADERS:
              'Origin,Content-Type,Accept,Authorization,Cache-Control,Pragma',
        },
      ))
      .addMiddleware(noStoreApi())
      .addMiddleware(_errorMiddleware())
      .addMiddleware(logRequests())
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
