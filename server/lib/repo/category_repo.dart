import 'package:postgres/postgres.dart';

import '../auth/authz.dart' show uuidRe;
import '../domain/models.dart';
import 'trim_batch_repo.dart';

/// Longest category name.
const maxCategoryNameLength = 60;

/// A category name that is blank, too long or already used in the set.
class CategoryNameException implements Exception {
  CategoryNameException(this.message, {this.conflict = false});
  final String message;

  /// The name is taken (409) rather than invalid (400).
  final bool conflict;
  @override
  String toString() => message;
}

/// Parent / depth / delete-with-children constraints.
class CategoryConstraintException implements Exception {
  CategoryConstraintException(this.message, {this.code = 'invalid_parent'});
  final String message;

  /// `category_has_children`, `max_depth`, `sync_nested`, `invalid_parent`,
  /// `category_not_a_leaf`, `category_has_events`.
  final String code;
  @override
  String toString() => message;
}

/// Trimmed, single-spaced [raw]; throws [CategoryNameException] when blank
/// or too long.
String normalizeCategoryName(Object? raw) {
  if (raw is! String) throw CategoryNameException('name is required');
  final v = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (v.isEmpty) throw CategoryNameException('name is required');
  if (v.length > maxCategoryNameLength) {
    throw CategoryNameException(
        'name must be at most $maxCategoryNameLength characters');
  }
  return v;
}

bool isSyncName(String name) => name.trim().toLowerCase() == 'sync';

/// Categories, one global set per owner (migrations 024, 025, 031): every
/// stream the owner has uses it. Names are unique in the set,
/// case-insensitively; events keep `events.name` equal to their category's
/// name through DB triggers. Optional parent_id (max depth 2).
class CategoryRepo {
  CategoryRepo(this._conn);

  final Session _conn;

  static const _cols = '''
    c.id::text, c.owner_id::text, c.name, c.color, c.hidden, c.created_at,
    c.version,
    (SELECT count(*) FROM events e WHERE e.category_id = c.id)::int,
    (SELECT count(*) FROM events e
      WHERE e.category_id = c.id
         OR e.category_id IN (SELECT ch.id FROM categories ch
                               WHERE ch.parent_id = c.id))::int,
    c.parent_id::text, c.sort_order,
    CASE WHEN c.parent_id IS NULL THEN 0 ELSE 1 END''';

  Category _fromRow(ResultRow r) => Category(
        id: r[0] as String,
        ownerId: r[1] as String,
        name: r[2] as String,
        color: r[3] as String,
        hidden: r[4] as bool,
        createdAt: (r[5] as DateTime).toUtc(),
        version: r[6] as int,
        eventCount: r[7] as int,
        eventCountSubtree: r[8] as int,
        parentId: r[9] as String?,
        sortOrder: r[10] as int,
        depth: r[11] as int,
      );

  /// The owner of [streamId] (whose categories its events use).
  Future<String?> ownerOfStream(String streamId) async {
    if (!uuidRe.hasMatch(streamId)) return null;
    final rows = await _conn.execute(
      Sql.named('SELECT owner_id::text FROM streams WHERE id = @s::uuid'),
      parameters: {'s': streamId},
    );
    return rows.isEmpty ? null : rows.first[0] as String;
  }

  /// [ownerId]'s categories, sibling order then name.
  Future<List<Category>> listByOwner(String ownerId) async {
    final rows = await _conn.execute(
      Sql.named('SELECT $_cols FROM categories c '
          'WHERE c.owner_id = @o::uuid '
          'ORDER BY c.sort_order, c.name, c.created_at'),
      parameters: {'o': ownerId},
    );
    return rows.map(_fromRow).toList();
  }

  /// The categories [streamId]'s events use (its owner's set).
  Future<List<Category>> listByStream(String streamId) async {
    final owner = await ownerOfStream(streamId);
    if (owner == null) return const [];
    return listByOwner(owner);
  }

  Future<Category?> get(String id) async {
    if (!uuidRe.hasMatch(id)) return null;
    final rows = await _conn.execute(
      Sql.named('SELECT $_cols FROM categories c WHERE c.id = @id::uuid'),
      parameters: {'id': id},
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// [ownerId]'s category named [name] (case-insensitive), if any.
  Future<Category?> byName(String ownerId, String name) async {
    final rows = await _conn.execute(
      Sql.named('SELECT $_cols FROM categories c WHERE c.owner_id = @o::uuid '
          'AND lower(c.name) = lower(@n)'),
      parameters: {'o': ownerId, 'n': name.trim()},
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<int> childCount(String id) async {
    final r = await _conn.execute(
      Sql.named(
          'SELECT count(*)::int FROM categories WHERE parent_id = @id::uuid'),
      parameters: {'id': id},
    );
    return r.first[0] as int;
  }

  Future<void> _checkFree(String ownerId, String name, {String? except}) async {
    final other = await byName(ownerId, name);
    if (other != null && other.id != except) {
      throw CategoryNameException(
          'A category named "${other.name}" already exists',
          conflict: true);
    }
  }

  Future<int> _nextSort(String ownerId, String? parentId) async {
    final rows = await _conn.execute(
      Sql.named('SELECT coalesce(max(sort_order), -1) + 1 FROM categories '
          'WHERE owner_id = @o::uuid '
          'AND parent_id IS NOT DISTINCT FROM @p::uuid'),
      parameters: {'o': ownerId, 'p': parentId},
    );
    return rows.first[0] as int;
  }

  Future<void> _assertParent(String ownerId, String? parentId,
      {String? childId}) async {
    if (parentId == null) return;
    if (!uuidRe.hasMatch(parentId)) {
      throw CategoryConstraintException('parentId is not a valid category');
    }
    if (childId != null && parentId == childId) {
      throw CategoryConstraintException('category cannot be its own parent');
    }
    final parent = await get(parentId);
    if (parent == null || parent.ownerId != ownerId) {
      throw CategoryConstraintException(
          'parentId is not a category of this owner');
    }
    if (parent.parentId != null) {
      throw CategoryConstraintException(
          'categories can only nest one level deep',
          code: 'max_depth');
    }
    if (isSyncName(parent.name)) {
      throw CategoryConstraintException('Sync cannot have children',
          code: 'sync_nested');
    }
    if (childId != null) {
      final child = await get(childId);
      if (child != null && isSyncName(child.name)) {
        throw CategoryConstraintException('Sync cannot be nested',
            code: 'sync_nested');
      }
      if (child != null && await childCount(childId) > 0) {
        throw CategoryConstraintException(
            'a category with children must stay top-level',
            code: 'max_depth');
      }
    }
  }

  /// Adds a category to [ownerId]'s set.
  Future<int> _directEventCount(String id) async {
    final rows = await _conn.execute(
      Sql.named(
          'SELECT count(*)::int FROM events WHERE category_id = @id::uuid'),
      parameters: {'id': id},
    );
    return rows.first[0] as int;
  }

  Future<Category> create(String ownerId,
      {required String name,
      String? color,
      bool hidden = false,
      String? parentId,
      bool moveParentEvents = false}) async {
    final n = normalizeCategoryName(name);
    if (parentId != null && isSyncName(n)) {
      throw CategoryConstraintException('Sync cannot be nested',
          code: 'sync_nested');
    }
    await _checkFree(ownerId, n);
    await _assertParent(ownerId, parentId);
    var parentEvents = 0;
    if (parentId != null) {
      parentEvents = await _directEventCount(parentId);
      if (parentEvents > 0 && !moveParentEvents) {
        throw CategoryConstraintException(
            'This category has transactions, so it can\'t become a folder '
            'until those are moved into a subcategory',
            code: 'category_has_events');
      }
    }
    color ??= await _unusedColor(ownerId);
    final sort = await _nextSort(ownerId, parentId);
    try {
      // If we must move the parent's events into this new child, park them
      // on a temporary null? Events.category_id is probably NOT NULL.
      // So: insert the child while the parent still has events would trip
      // categories_parent_must_be_empty. Move events to a holding leaf first
      // is messy. Better: defer the parent_id on insert (create as top-level),
      // move events onto the new leaf, then set parent_id.
      String? insertParent = parentId;
      if (parentId != null && parentEvents > 0 && moveParentEvents) {
        insertParent = null;
      }
      final rows = await _conn.execute(
        Sql.named(
            'INSERT INTO categories (owner_id, name, color, hidden, parent_id, sort_order) '
            'VALUES (@o::uuid, @n, @c, @h, @p::uuid, @s) RETURNING id::text'),
        parameters: {
          'o': ownerId,
          'n': n,
          'c': color,
          'h': hidden,
          'p': insertParent,
          's': sort,
        },
      );
      final id = rows.first[0] as String;
      if (parentId != null && parentEvents > 0 && moveParentEvents) {
        await _conn.execute(
          Sql.named(
              'UPDATE events SET category_id = @c::uuid WHERE category_id = @p::uuid'),
          parameters: {'c': id, 'p': parentId},
        );
        await _conn.execute(
          Sql.named(
              'UPDATE categories SET parent_id = @p::uuid, sort_order = @s '
              'WHERE id = @id::uuid'),
          parameters: {'p': parentId, 's': sort, 'id': id},
        );
      }
      return (await get(id))!;
    } on ServerException catch (e) {
      throw _mapConstraint(e);
    }
  }

  /// The first lane palette colour no category of [ownerId] uses (the
  /// next in turn when all are taken).
  Future<String> _unusedColor(String ownerId) async {
    final rows = await _conn.execute(
      Sql.named('SELECT color FROM categories WHERE owner_id = @o::uuid'),
      parameters: {'o': ownerId},
    );
    final used = {for (final r in rows) r[0] as String};
    for (final c in categoryPalette) {
      if (!used.contains(c)) return c;
    }
    return categoryPalette[rows.length % categoryPalette.length];
  }

  /// Renames / recolours / hides / reparents [id]. A rename renames its
  /// events too (trigger). Pass [parentId] to nest, [clearParent] to
  /// un-nest; omit both to leave the parent alone.
  Future<Category?> update(String id,
      {String? name,
      String? color,
      bool? hidden,
      String? parentId,
      bool clearParent = false,
      int? sortOrder}) async {
    final c = await get(id);
    if (c == null) return null;
    final n = name == null ? c.name : normalizeCategoryName(name);
    if (name != null) await _checkFree(c.ownerId, n, except: id);
    final nextParent = clearParent ? null : (parentId ?? c.parentId);
    if (clearParent || parentId != null) {
      await _assertParent(c.ownerId, nextParent, childId: id);
      if (nextParent != null && await _directEventCount(nextParent) > 0) {
        throw CategoryConstraintException(
            'This category has transactions, so it can\'t become a folder '
            'until those are moved into a subcategory',
            code: 'category_has_events');
      }
    }
    if (nextParent != null && isSyncName(n)) {
      throw CategoryConstraintException('Sync cannot be nested',
          code: 'sync_nested');
    }
    var nextSort = sortOrder ?? c.sortOrder;
    if ((clearParent || parentId != null) && nextParent != c.parentId) {
      nextSort = sortOrder ?? await _nextSort(c.ownerId, nextParent);
    }
    try {
      await _conn.execute(
        Sql.named('UPDATE categories SET name = @n, color = @c, hidden = @h, '
            'parent_id = @p::uuid, sort_order = @s '
            'WHERE id = @id::uuid'),
        parameters: {
          'id': id,
          'n': n,
          'c': color ?? c.color,
          'h': hidden ?? c.hidden,
          'p': nextParent,
          's': nextSort,
        },
      );
    } on ServerException catch (e) {
      throw _mapConstraint(e);
    }
    return get(id);
  }

  /// Sets the sibling order of [ids] under [parentId] (null = top-level).
  /// Every id must belong to [ownerId] and end up with that parent.
  Future<void> reorder(
      String ownerId, String? parentId, List<String> ids) async {
    if (ids.isEmpty) return;
    for (final id in ids) {
      if (!uuidRe.hasMatch(id)) {
        throw CategoryConstraintException('invalid category id');
      }
    }
    await _assertParent(ownerId, parentId);
    final unique = ids.toSet();
    if (unique.length != ids.length) {
      throw CategoryConstraintException('duplicate category id in order');
    }
    for (final id in ids) {
      final c = await get(id);
      if (c == null || c.ownerId != ownerId) {
        throw CategoryConstraintException(
            'category is not in this owner\'s set');
      }
      if (parentId != null && parentId == id) {
        throw CategoryConstraintException('category cannot be its own parent');
      }
      if (c.parentId != parentId) {
        await _assertParent(ownerId, parentId, childId: id);
      }
    }
    // Two-phase so the unique sibling order cannot collide mid-update.
    var i = 0;
    for (final id in ids) {
      i++;
      await _conn.execute(
        Sql.named('UPDATE categories SET parent_id = @p::uuid, sort_order = @s '
            'WHERE id = @id::uuid'),
        parameters: {'id': id, 'p': parentId, 's': -100000 - i},
      );
    }
    i = 0;
    for (final id in ids) {
      await _conn.execute(
        Sql.named('UPDATE categories SET sort_order = @s WHERE id = @id::uuid'),
        parameters: {'id': id, 's': i++},
      );
    }
  }

  Never _mapConstraint(ServerException e) {
    final name = e.constraintName ?? '';
    final msg = e.message;
    if (name == 'categories_max_depth' ||
        msg.contains('one level deep') ||
        msg.contains('must stay top-level')) {
      throw CategoryConstraintException(
          'categories can only nest one level deep',
          code: 'max_depth');
    }
    if (name == 'categories_sync_top_level' || msg.contains('Sync cannot')) {
      throw CategoryConstraintException(
          msg.contains('children')
              ? 'Sync cannot have children'
              : 'Sync cannot be nested',
          code: 'sync_nested');
    }
    if (name == 'categories_parent_ck' || msg.contains('own parent')) {
      throw CategoryConstraintException('category cannot be its own parent');
    }
    if (name == 'categories_parent_owner_ck' ||
        name == 'categories_parent_id_fkey') {
      throw CategoryConstraintException(
          'parentId is not a category of this owner');
    }
    if (msg.contains('filed on a category that has children')) {
      throw CategoryConstraintException(
          "Folders can't hold transactions. Pick a category with no subcategories.",
          code: 'category_not_a_leaf');
    }
    if (msg.contains('still has events')) {
      throw CategoryConstraintException(
          'This category has transactions, so it can\'t become a folder '
          'until those are moved into a subcategory',
          code: 'category_has_events');
    }
    throw CategoryConstraintException(
        msg.isEmpty ? 'invalid category parent' : msg);
  }

  /// What deleting [id] removes: its events and their transfer
  /// counterparts in other streams, plus how many children block a
  /// category delete.
  Future<({int events, int counterparts, int children})> deleteCounts(
      String id) async {
    final r = await _conn.execute(
      Sql.named('''
        SELECT count(*)::int,
          (SELECT count(*)::int FROM events p
             JOIN events e ON e.transfer_id = p.transfer_id AND p.id <> e.id
            WHERE e.category_id = @id::uuid AND e.transfer_id IS NOT NULL
              AND p.category_id <> @id::uuid),
          (SELECT count(*)::int FROM categories ch WHERE ch.parent_id = @id::uuid)
        FROM events WHERE category_id = @id::uuid
      '''),
      parameters: {'id': id},
    );
    return (
      events: r.first[0] as int,
      counterparts: r.first[1] as int,
      children: r.first[2] as int,
    );
  }

  /// Deletes every event in [id] in ALL the owner's streams (and each
  /// transfer's other side, skips and overrides) as one undoable batch
  /// filed under [streamId] (`POST /streams/[streamId]/events/trim/undo`
  /// with the returned batch id); the category stays. peerStreams: every
  /// other stream touched. Call inside a DB transaction. Null when the
  /// category does not exist.
  Future<({String? batchId, List<String> deleted, Set<String> peerStreams})?>
      deleteEvents(String id,
          {required String streamId, required String userId}) async {
    final c = await get(id);
    if (c == null) return null;
    final rows = await _conn.execute(
      Sql.named('SELECT id::text FROM events WHERE category_id = @id::uuid '
          'ORDER BY created_at'),
      parameters: {'id': id},
    );
    return TrimBatchRepo(_conn).deleteAsBatch(
        streamId, [for (final r in rows) r[0] as String],
        userId: userId, anyStream: true);
  }

  /// Deletes [id] with every event in it (see [deleteEvents]; the events'
  /// batch is not offered for undo since the category itself is gone).
  /// Null when the category does not exist. Throws
  /// [CategoryConstraintException] when it still has children.
  Future<({String? batchId, List<String> deleted, Set<String> peerStreams})?>
      delete(String id,
          {required String streamId, required String userId}) async {
    if (await childCount(id) > 0) {
      throw CategoryConstraintException(
          'Move or delete its subcategories first',
          code: 'category_has_children');
    }
    final r = await deleteEvents(id, streamId: streamId, userId: userId);
    if (r == null) return null;
    await _conn.execute(
      Sql.named('DELETE FROM categories WHERE id = @id::uuid'),
      parameters: {'id': id},
    );
    return r;
  }

  /// The name an event body means: its `categoryId`'s name (it must be a
  /// category of [streamId]'s owner), else the legacy `name` (mapped to /
  /// creating a category by the DB). Throws [FormatException] for an
  /// unknown id.
  Future<String?> nameFor(
      String streamId, Object? categoryId, String? legacyName) async {
    if (categoryId == null) return legacyName;
    final c = await get(categoryId.toString());
    if (c == null || c.ownerId != await ownerOfStream(streamId)) {
      throw FormatException('categoryId is not a category of this stream');
    }
    if (await childCount(c.id) > 0) {
      throw CategoryConstraintException(
          "Folders can't hold transactions. Pick a category with no subcategories.",
          code: 'category_not_a_leaf');
    }
    return c.name;
  }

  /// [userId]'s favourite categories that belong to [ownerId], in order.
  Future<List<Map<String, Object?>>> listFavorites(
      String userId, String ownerId) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT f.category_id::text, f.sort_order, f.created_at
        FROM category_favorites f
        JOIN categories c ON c.id = f.category_id
        WHERE f.user_id = @u::uuid AND c.owner_id = @o::uuid
          AND NOT EXISTS (
            SELECT 1 FROM categories ch WHERE ch.parent_id = c.id)
        ORDER BY f.sort_order, f.created_at, c.name
      '''),
      parameters: {'u': userId, 'o': ownerId},
    );
    return [
      for (final r in rows)
        {
          'categoryId': r[0] as String,
          'sortOrder': r[1] as int,
          'createdAt': (r[2] as DateTime).toUtc().toIso8601String(),
        }
    ];
  }

  Future<void> addFavorite(String userId, String categoryId,
      {required String ownerId}) async {
    final c = await get(categoryId);
    if (c == null || c.ownerId != ownerId) {
      throw CategoryConstraintException('category not found');
    }
    if (await childCount(categoryId) > 0) {
      throw CategoryConstraintException(
          'Only categories with no subcategories can be favourited',
          code: 'category_not_a_leaf');
    }
    final next = await _conn.execute(
      Sql.named('SELECT coalesce(max(sort_order), -1) + 1 '
          'FROM category_favorites WHERE user_id = @u::uuid'),
      parameters: {'u': userId},
    );
    await _conn.execute(
      Sql.named(
          'INSERT INTO category_favorites (user_id, category_id, sort_order) '
          'VALUES (@u::uuid, @c::uuid, @s) '
          'ON CONFLICT (user_id, category_id) DO NOTHING'),
      parameters: {
        'u': userId,
        'c': categoryId,
        's': next.first[0] as int,
      },
    );
  }

  Future<void> removeFavorite(String userId, String categoryId) async {
    await _conn.execute(
      Sql.named('DELETE FROM category_favorites '
          'WHERE user_id = @u::uuid AND category_id = @c::uuid'),
      parameters: {'u': userId, 'c': categoryId},
    );
  }

  Future<void> reorderFavorites(String userId, List<String> ids) async {
    var i = 0;
    for (final id in ids) {
      if (!uuidRe.hasMatch(id)) {
        throw CategoryConstraintException('invalid category id');
      }
      i++;
      await _conn.execute(
        Sql.named('UPDATE category_favorites SET sort_order = @s '
            'WHERE user_id = @u::uuid AND category_id = @id::uuid'),
        parameters: {'u': userId, 'id': id, 's': -100000 - i},
      );
    }
    i = 0;
    for (final id in ids) {
      await _conn.execute(
        Sql.named('UPDATE category_favorites SET sort_order = @s '
            'WHERE user_id = @u::uuid AND category_id = @id::uuid'),
        parameters: {'u': userId, 'id': id, 's': i++},
      );
    }
  }
}

/// The client's lane palette (stack_lanes.dart laneColors; SQL
/// budget_lane_color), in order.
const categoryPalette = [
  '#3D6FD8', '#9250C8', '#B36A12', '#2B8AA8', '#B8488E', '#5B7A2A', //
  '#6A62D6', '#A0602C', '#3C8A6E', '#8E5A9E', '#4A78A8', '#9C7A1E',
];
