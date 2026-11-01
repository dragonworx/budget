import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/authz.dart';
import '../auth/authz_middleware.dart';
import '../auth/middleware.dart';
import '../domain/formulas.dart';
import '../domain/variable_manager.dart';
import '../domain/variable_reads.dart';
import '../domain/variable_service.dart';
import '../realtime/access_set.dart';
import '../repo/variable_repo.dart';
import 'json_helpers.dart';

// Variables (spec 010), the owner-level named values formulas use.
// Under `/api/streams` they are the stream OWNER's set: every member lists
// and references them (D3, D20: shared viewers see all of them for now);
// only the owner manages. Under `/api/variables` they are the caller's own.
//   GET    variables                 {variables, attention, canManage}
//   POST   variables                 {name, expr, unit?, description?,
//                                     displayDecimals?} -> 201
//   PATCH  variables/<v>             any of those (rename rewrites texts)
//   DELETE variables/<v>             409 variable_in_use when referenced
//   GET    variables/<v>/usages      {usages, hidden}
//   POST   variables/<v>/preview     PATCH dry run {changes, invalid}
//   GET    variables/attention       {items, count}

Response variableError(Object e) => switch (e) {
      VariableException(:final status, :final message, :final details) =>
        jsonError(status, message, details: details),
      FormulaFieldException() =>
        jsonError(400, e.error.message, details: e.details),
      FormatException(:final message) => jsonError(400, message),
      _ => throw e,
    };

/// The owner whose set a request sees, whether the caller manages it, and
/// the streams the caller can read (null: all of the owner's).
typedef _Ctx = ({
  String owner,
  String me,
  bool canManage,
  Set<String>? readable
});

Future<Set<String>?> _readable(Session db, String me, String owner) async {
  if (me == owner) return null;
  final a = await AccessSet.load(db, me);
  return {...a.ownedStreams, ...a.sharedStreams};
}

class _Handlers {
  _Handlers(this.conn, this.ctxOf);
  final Session conn;
  final Future<_Ctx?> Function(Request r) ctxOf;

  Future<Variable?> _inSet(Session s, _Ctx c, String v) async {
    if (!uuidRe.hasMatch(v)) return null;
    final x = await VariableRepo(s).get(v);
    return x != null && x.ownerId == c.owner ? x : null;
  }

  Future<Response> list(Request r) async {
    final c = await ctxOf(r);
    if (c == null) return jsonError(404, 'stream not found');
    final vars = await VariableRepo(conn).list(c.owner);
    return jsonOk({
      'variables': [for (final v in vars) v.toJson()],
      'attention': await attentionCount(conn, c.owner, c.readable),
      'canManage': c.canManage,
    });
  }

  Future<Response> create(Request r) async {
    try {
      final c = await ctxOf(r);
      if (c == null) return jsonError(404, 'stream not found');
      final input = VariableInput.parse(await readJsonObject(r), create: true);
      final v = await txOf(conn).runTx((tx) =>
          VariableManager(tx, ownerId: c.owner, actorId: c.me).create(input));
      return jsonOk(v.toJson(), status: 201);
    } on Exception catch (e) {
      return variableError(e);
    }
  }

  Future<Response> patch(Request r, String id) async {
    try {
      final c = await ctxOf(r);
      if (c == null || await _inSet(conn, c, id) == null) {
        return jsonError(404, 'variable not found');
      }
      final input = VariableInput.parse(await readJsonObject(r), create: false);
      final v = await txOf(conn).runTx((tx) =>
          VariableManager(tx, ownerId: c.owner, actorId: c.me)
              .update(id, input));
      return jsonOk(v.toJson());
    } on Exception catch (e) {
      return variableError(e);
    }
  }

  Future<Response> delete(Request r, String id) async {
    try {
      final c = await ctxOf(r);
      if (c == null || await _inSet(conn, c, id) == null) {
        return jsonError(404, 'variable not found');
      }
      await txOf(conn).runTx((tx) =>
          VariableManager(tx, ownerId: c.owner, actorId: c.me).delete(id));
      return jsonOk({'deleted': true, 'id': id});
    } on Exception catch (e) {
      return variableError(e);
    }
  }

  Future<Response> usages(Request r, String id) async {
    final c = await ctxOf(r);
    if (c == null || await _inSet(conn, c, id) == null) {
      return jsonError(404, 'variable not found');
    }
    return jsonOk(await variableUsages(conn, id, c.readable));
  }

  Future<Response> preview(Request r, String id) async {
    try {
      final c = await ctxOf(r);
      if (c == null || await _inSet(conn, c, id) == null) {
        return jsonError(404, 'variable not found');
      }
      final input = VariableInput.parse(await readJsonObject(r), create: false);
      final out = await txOf(conn).runTx((tx) =>
          VariableManager(tx, ownerId: c.owner, actorId: c.me)
              .preview(id, input));
      return jsonOk(out);
    } on Exception catch (e) {
      return variableError(e);
    }
  }

  Future<Response> attention(Request r) async {
    final c = await ctxOf(r);
    if (c == null) return jsonError(404, 'stream not found');
    return jsonOk(await variableAttention(conn, c.owner, c.readable));
  }
}

/// Stream-scoped routes, mounted under `/api/streams`.
void attachVariableRoutes(Router router, Session conn) {
  final h = _Handlers(conn, (r) async {
    final a = r.params['a']!;
    final owner = await VariableService(conn).streamOwner(a);
    if (owner == null) return null;
    final me = requireAuth(r).user.id;
    return (
      owner: owner,
      me: me,
      canManage: accessOf(r)?.isOwner ?? me == owner,
      readable: await _readable(conn, me, owner),
    );
  });
  router.get('/<a>/variables', (Request r, String a) => h.list(r));
  router.post('/<a>/variables', (Request r, String a) => h.create(r));
  router.get(
      '/<a>/variables/attention', (Request r, String a) => h.attention(r));
  router.patch(
      '/<a>/variables/<v>', (Request r, String a, String v) => h.patch(r, v));
  router.delete(
      '/<a>/variables/<v>', (Request r, String a, String v) => h.delete(r, v));
  router.get('/<a>/variables/<v>/usages',
      (Request r, String a, String v) => h.usages(r, v));
  router.post('/<a>/variables/<v>/preview',
      (Request r, String a, String v) => h.preview(r, v));
}

/// The caller's own set, mounted at `/api/variables` (a manager page that
/// isn't inside a stream).
Router buildVariablesApi(Session conn) {
  final router = Router();
  final h = _Handlers(conn, (r) async {
    final me = requireAuth(r).user.id;
    return (owner: me, me: me, canManage: true, readable: null);
  });
  router.get('/', h.list);
  router.post('/', h.create);
  router.get('/attention', h.attention);
  router.patch('/<v>', (Request r, String v) => h.patch(r, v));
  router.delete('/<v>', (Request r, String v) => h.delete(r, v));
  router.get('/<v>/usages', (Request r, String v) => h.usages(r, v));
  router.post('/<v>/preview', (Request r, String v) => h.preview(r, v));
  return router;
}
