import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../domain/models.dart';
import '../auth/middleware.dart';
import '../repo/category_repo.dart';
import 'streams.dart' show notifyPeers;
import 'json_helpers.dart';

// Stream categories (migration 024), mounted under `/api/streams`:
//   GET    /<a>/categories            list (with eventCount)
//   POST   /<a>/categories            {name, color?, hidden?} -> 201
//   PATCH  /<a>/categories/<c>        {name?, color?, hidden?}
//   GET    /<a>/categories/<c>/delete-preview  {events, counterparts}
//   DELETE /<a>/categories/<c>        deletes it and all its events
//   DELETE /<a>/categories/<c>/events deletes all its events, keeps it
// Names are unique per stream (case-insensitive): a taken name is a 409.
void attachCategoryRoutes(Router router, Session conn) {
  const nameError = categoryNameError;

  router.get('/<a>/categories', (Request r, String a) async {
    final list = await CategoryRepo(conn).listByStream(a);
    return jsonOk({'categories': list.map((c) => c.toJson()).toList()});
  });

  router.post('/<a>/categories', (Request r, String a) async {
    try {
      final body = await readJsonObject(r);
      final c = await txOf(conn).runTx((tx) => CategoryRepo(tx).create(a,
          name: body['name'] is String ? body['name'] as String : '',
          color: parseEventColor(body['color']),
          hidden: optionalBool(body, 'hidden') ?? false));
      return jsonOk(c.toJson(), status: 201);
    } on CategoryNameException catch (e) {
      return nameError(e);
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    }
  });

  Future<Category?> inStream(Session s, String a, String c) async {
    final cat = await CategoryRepo(s).get(c);
    return cat != null && cat.streamId == a ? cat : null;
  }

  router.patch('/<a>/categories/<c>', (Request r, String a, String c) async {
    try {
      final body = await readJsonObject(r);
      if (await inStream(conn, a, c) == null) {
        return jsonError(404, 'category not found');
      }
      if (body.containsKey('color') && parseEventColor(body['color']) == null) {
        return jsonError(400, 'color must be "#RRGGBB"');
      }
      final updated = await txOf(conn).runTx((tx) => CategoryRepo(tx).update(c,
          name:
              body.containsKey('name') ? (body['name'] ?? '').toString() : null,
          color: parseEventColor(body['color']),
          hidden: optionalBool(body, 'hidden')));
      return jsonOk(updated!.toJson());
    } on CategoryNameException catch (e) {
      return nameError(e);
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    }
  });

  router.get('/<a>/categories/<c>/delete-preview',
      (Request r, String a, String c) async {
    if (await inStream(conn, a, c) == null) {
      return jsonError(404, 'category not found');
    }
    final n = await CategoryRepo(conn).deleteCounts(c);
    return jsonOk({'events': n.events, 'counterparts': n.counterparts});
  });

  router.delete('/<a>/categories/<c>/events',
      (Request r, String a, String c) async {
    if (await inStream(conn, a, c) == null) {
      return jsonError(404, 'category not found');
    }
    final me = requireAuth(r).user.id;
    final res = await txOf(conn)
        .runTx((tx) => CategoryRepo(tx).deleteEvents(c, userId: me));
    if (res == null) return jsonError(404, 'category not found');
    await notifyPeers(conn, r, me, res.peerStreams, 'events.deleted');
    // batchId: undo with POST /streams/:a/events/trim/undo.
    return jsonOk(
        {'id': c, 'deletedEvents': res.deleted, 'batchId': res.batchId});
  });

  router.delete('/<a>/categories/<c>', (Request r, String a, String c) async {
    if (await inStream(conn, a, c) == null) {
      return jsonError(404, 'category not found');
    }
    final me = requireAuth(r).user.id;
    final res =
        await txOf(conn).runTx((tx) => CategoryRepo(tx).delete(c, userId: me));
    if (res == null) return jsonError(404, 'category not found');
    await notifyPeers(conn, r, me, res.peerStreams, 'events.deleted');
    return jsonOk({'id': c, 'deletedEvents': res.deleted});
  });
}

/// 409 for a taken name, 400 for a blank / too long one.
Response categoryNameError(CategoryNameException e) =>
    jsonError(e.conflict ? 409 : 400, e.message,
        details: {'code': e.conflict ? 'category_name_taken' : 'invalid_name'});

/// The event name (= category name) an event write in [streamId] means:
/// `newCategory: {name, color}` creates that category first (a taken name
/// throws [CategoryNameException], so plans never reuse one), else
/// `categoryId` (must be a category of [streamId]), else [legacyName]
/// (mapped to, or creating, the category by name in the DB). Null when the
/// body names none.
Future<String?> resolveEventCategory(
    Session tx, String streamId, Map<String, dynamic> body,
    {String? legacyName}) async {
  final repo = CategoryRepo(tx);
  final nc = body['newCategory'];
  if (nc != null) {
    if (nc is! Map) throw FormatException('newCategory must be {name, color}');
    final c = await repo.create(streamId,
        name: nc['name'] is String ? nc['name'] as String : '',
        color: parseEventColor(nc['color']));
    return c.name;
  }
  return repo.nameFor(streamId, body['categoryId'], legacyName);
}
