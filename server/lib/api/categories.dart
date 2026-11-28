import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../domain/models.dart';
import '../auth/middleware.dart';
import '../repo/category_repo.dart';
import 'streams.dart' show notifyPeers;
import 'json_helpers.dart';

// Categories (migration 035), mounted under `/api/streams`: each stream
// has its own set. Viewers read; owners and editors may add, rename,
// recolour, hide, reparent, reorder and delete (this stream only).
// Favourites are per user: any stream member may star or unstar for
// themselves.
//   GET    /<a>/categories            list (parentId, sortOrder, counts)
//   POST   /<a>/categories            {name, color?, hidden?, parentId?}
//   POST   /<a>/categories/reorder    {parentId, ids} sibling order
//   PATCH  /<a>/categories/<c>        {name?, color?, hidden?, parentId?, sortOrder?}
//   GET    /<a>/categories/<c>/delete-preview  {events, counterparts, children}
//   DELETE /<a>/categories/<c>        deletes it and all its events
//   DELETE /<a>/categories/<c>/events deletes all its events, keeps it
//   GET    /<a>/category-favorites
//   PUT    /<a>/categories/<c>/favorite
//   DELETE /<a>/categories/<c>/favorite
//   PATCH  /<a>/category-favorites    {ids}
// Names are unique in the stream (case-insensitive): a taken name is
// a 409. Deleting a parent that still has children is a 409.
void attachCategoryRoutes(Router router, Session conn) {
  const nameError = categoryNameError;

  Response constraintError(CategoryConstraintException e) =>
      jsonError(e.code == 'category_has_children' ? 409 : 400, e.message,
          details: {'code': e.code});

  String? optionalParentId(Map<String, dynamic> body) {
    if (!body.containsKey('parentId')) return null;
    final v = body['parentId'];
    if (v == null) return null;
    if (v is! String || v.isEmpty) {
      throw FormatException('parentId must be a category id');
    }
    return v;
  }

  List<String> idList(Object? raw, String field) {
    if (raw is! List) throw FormatException('$field must be a list of ids');
    return [
      for (final x in raw)
        if (x is String)
          x
        else
          throw FormatException('$field must be a list of ids')
    ];
  }

  router.get('/<a>/categories', (Request r, String a) async {
    final list = await CategoryRepo(conn).listByStream(a);
    return jsonOk({'categories': list.map((c) => c.toJson()).toList()});
  });

  router.post('/<a>/categories/reorder', (Request r, String a) async {
    try {
      final body = await readJsonObject(r);
      final parentId = optionalParentId(body);
      final ids = idList(body['ids'], 'ids');
      await txOf(conn).runTx((tx) => CategoryRepo(tx)
          .reorder(a, body.containsKey('parentId') ? parentId : null, ids));
      final list = await CategoryRepo(conn).listByStream(a);
      return jsonOk({'categories': list.map((c) => c.toJson()).toList()});
    } on CategoryConstraintException catch (e) {
      return constraintError(e);
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    }
  });

  router.post('/<a>/categories', (Request r, String a) async {
    try {
      final body = await readJsonObject(r);
      final c = await txOf(conn).runTx((tx) => CategoryRepo(tx).create(a,
          name: body['name'] is String ? body['name'] as String : '',
          color: parseEventColor(body['color']),
          hidden: optionalBool(body, 'hidden') ?? false,
          parentId: optionalParentId(body),
          moveParentEvents: optionalBool(body, 'moveParentEvents') ?? false));
      return jsonOk(c.toJson(), status: 201);
    } on CategoryNameException catch (e) {
      return nameError(e);
    } on CategoryConstraintException catch (e) {
      return constraintError(e);
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    }
  });

  Future<Category?> inStream(Session s, String a, String c) async {
    final repo = CategoryRepo(s);
    final cat = await repo.get(c);
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
      int? sortOrder;
      if (body.containsKey('sortOrder')) {
        final s = body['sortOrder'];
        if (s is! num || s.toInt() != s) {
          return jsonError(400, 'sortOrder must be an integer');
        }
        sortOrder = s.toInt();
      }
      final updated = await txOf(conn).runTx((tx) => CategoryRepo(tx).update(c,
          name:
              body.containsKey('name') ? (body['name'] ?? '').toString() : null,
          color: parseEventColor(body['color']),
          hidden: optionalBool(body, 'hidden'),
          parentId: body.containsKey('parentId') && body['parentId'] != null
              ? optionalParentId(body)
              : null,
          clearParent: body.containsKey('parentId') && body['parentId'] == null,
          sortOrder: sortOrder));
      return jsonOk(updated!.toJson());
    } on CategoryNameException catch (e) {
      return nameError(e);
    } on CategoryConstraintException catch (e) {
      return constraintError(e);
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
    return jsonOk({
      'events': n.events,
      'counterparts': n.counterparts,
      'children': n.children,
    });
  });

  router.delete('/<a>/categories/<c>/events',
      (Request r, String a, String c) async {
    if (await inStream(conn, a, c) == null) {
      return jsonError(404, 'category not found');
    }
    final me = requireAuth(r).user.id;
    final res = await txOf(conn).runTx(
        (tx) => CategoryRepo(tx).deleteEvents(c, streamId: a, userId: me));
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
    try {
      final res = await txOf(conn)
          .runTx((tx) => CategoryRepo(tx).delete(c, streamId: a, userId: me));
      if (res == null) return jsonError(404, 'category not found');
      await notifyPeers(conn, r, me, res.peerStreams, 'events.deleted');
      return jsonOk({'id': c, 'deletedEvents': res.deleted});
    } on CategoryConstraintException catch (e) {
      final n = await CategoryRepo(conn).deleteCounts(c);
      return jsonError(409, e.message, details: {
        'code': e.code,
        'events': n.events,
        'counterparts': n.counterparts,
        'children': n.children,
      });
    }
  });

  router.get('/<a>/category-favorites', (Request r, String a) async {
    final me = requireAuth(r).user.id;
    final list = await CategoryRepo(conn).listFavorites(me, a);
    return jsonOk({'favorites': list});
  });

  router.patch('/<a>/category-favorites', (Request r, String a) async {
    try {
      final body = await readJsonObject(r);
      final me = requireAuth(r).user.id;
      final ids = idList(body['ids'], 'ids');
      await txOf(conn)
          .runTx((tx) => CategoryRepo(tx).reorderFavorites(me, ids));
      final list = await CategoryRepo(conn).listFavorites(me, a);
      await notifyPeers(conn, r, me, {a}, 'category.favorite_updated');
      return jsonOk({'favorites': list});
    } on CategoryConstraintException catch (e) {
      return constraintError(e);
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    }
  });

  router.put('/<a>/categories/<c>/favorite',
      (Request r, String a, String c) async {
    if (await inStream(conn, a, c) == null) {
      return jsonError(404, 'category not found');
    }
    final me = requireAuth(r).user.id;
    try {
      await txOf(conn)
          .runTx((tx) => CategoryRepo(tx).addFavorite(me, c, streamId: a));
    } on CategoryConstraintException catch (e) {
      return constraintError(e);
    }
    await notifyPeers(conn, r, me, {a}, 'category.favorite_updated');
    final list = await CategoryRepo(conn).listFavorites(me, a);
    return jsonOk({'favorites': list});
  });

  router.delete('/<a>/categories/<c>/favorite',
      (Request r, String a, String c) async {
    if (await inStream(conn, a, c) == null) {
      return jsonError(404, 'category not found');
    }
    final me = requireAuth(r).user.id;
    await txOf(conn).runTx((tx) => CategoryRepo(tx).removeFavorite(me, c));
    await notifyPeers(conn, r, me, {a}, 'category.favorite_updated');
    final list = await CategoryRepo(conn).listFavorites(me, a);
    return jsonOk({'favorites': list});
  });
}

/// 409 for a taken name, 400 for a blank / too long one.

Response categoryConstraintOnEvent(CategoryConstraintException e) =>
    jsonError(400, e.message, details: {'code': e.code});

Response categoryNameError(CategoryNameException e) =>
    jsonError(e.conflict ? 409 : 400, e.message,
        details: {'code': e.conflict ? 'category_name_taken' : 'invalid_name'});

/// The event name (= category name) an event write in [streamId] means:
/// `newCategory: {name, color}` creates that category first (a taken name
/// throws [CategoryNameException], so plans never reuse one), else
/// `categoryId` (must be one of [streamId]'s), else [legacyName]
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
        color: parseEventColor(nc['color']),
        parentId: nc['parentId'] is String ? nc['parentId'] as String : null);
    return c.name;
  }
  return repo.nameFor(streamId, body['categoryId'], legacyName);
}
