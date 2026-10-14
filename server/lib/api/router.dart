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
              'Origin,Content-Type,Accept,Authorization',
        },
      ))
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
