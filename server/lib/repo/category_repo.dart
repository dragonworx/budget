import 'package:postgres/postgres.dart';

import '../auth/authz.dart' show uuidRe;
import '../domain/models.dart';
import 'event_repo.dart';

/// Longest category name.
const maxCategoryNameLength = 60;

/// A category name that is blank, too long or already used in the stream.
class CategoryNameException implements Exception {
  CategoryNameException(this.message, {this.conflict = false});
  final String message;

  /// The name is taken (409) rather than invalid (400).
  final bool conflict;
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

/// Categories of a stream (see migration 024). Names are unique per stream,
/// case-insensitively; events keep `events.name` equal to their category's
/// name through DB triggers.
class CategoryRepo {
  CategoryRepo(this._conn);

  final Session _conn;

  static const _cols = '''
    c.id::text, c.stream_id::text, c.name, c.color, c.hidden, c.created_at,
    c.version, (SELECT count(*) FROM events e WHERE e.category_id = c.id)::int''';

  Category _fromRow(ResultRow r) => Category(
        id: r[0] as String,
        streamId: r[1] as String,
        name: r[2] as String,
        color: r[3] as String,
        hidden: r[4] as bool,
        createdAt: (r[5] as DateTime).toUtc(),
        version: r[6] as int,
        eventCount: r[7] as int,
      );

  /// The stream's categories, oldest first (the order they were made).
  Future<List<Category>> listByStream(String streamId) async {
    final rows = await _conn.execute(
      Sql.named('SELECT $_cols FROM categories c '
          'WHERE c.stream_id = @s::uuid ORDER BY c.created_at, c.name'),
      parameters: {'s': streamId},
    );
    return rows.map(_fromRow).toList();
  }

  Future<Category?> get(String id) async {
    if (!uuidRe.hasMatch(id)) return null;
    final rows = await _conn.execute(
      Sql.named('SELECT $_cols FROM categories c WHERE c.id = @id::uuid'),
      parameters: {'id': id},
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// [streamId]'s category named [name] (case-insensitive), if any.
  Future<Category?> byName(String streamId, String name) async {
    final rows = await _conn.execute(
      Sql.named('SELECT $_cols FROM categories c WHERE c.stream_id = @s::uuid '
          'AND lower(c.name) = lower(@n)'),
      parameters: {'s': streamId, 'n': name.trim()},
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<void> _checkFree(String streamId, String name,
      {String? except}) async {
    final other = await byName(streamId, name);
    if (other != null && other.id != except) {
      throw CategoryNameException(
          'A category named "${other.name}" already exists',
          conflict: true);
    }
  }

  Future<Category> create(String streamId,
      {required String name, String? color, bool hidden = false}) async {
    final n = normalizeCategoryName(name);
    await _checkFree(streamId, n);
    color ??= await _unusedColor(streamId);
    final rows = await _conn.execute(
      Sql.named('INSERT INTO categories (stream_id, name, color, hidden) '
          'VALUES (@s::uuid, @n, @c, @h) RETURNING id::text'),
      parameters: {'s': streamId, 'n': n, 'c': color, 'h': hidden},
    );
    return (await get(rows.first[0] as String))!;
  }

  /// The first lane palette colour no category of [streamId] uses (the
  /// next in turn when all are taken).
  Future<String> _unusedColor(String streamId) async {
    final rows = await _conn.execute(
      Sql.named('SELECT color FROM categories WHERE stream_id = @s::uuid'),
      parameters: {'s': streamId},
    );
    final used = {for (final r in rows) r[0] as String};
    for (final c in categoryPalette) {
      if (!used.contains(c)) return c;
    }
    return categoryPalette[rows.length % categoryPalette.length];
  }

  /// Renames / recolours / hides [id]. A rename renames its events too
  /// (trigger).
  Future<Category?> update(String id,
      {String? name, String? color, bool? hidden}) async {
    final c = await get(id);
    if (c == null) return null;
    final n = name == null ? c.name : normalizeCategoryName(name);
    if (name != null) await _checkFree(c.streamId, n, except: id);
    await _conn.execute(
      Sql.named('UPDATE categories SET name = @n, color = @c, hidden = @h '
          'WHERE id = @id::uuid'),
      parameters: {
        'id': id,
        'n': n,
        'c': color ?? c.color,
        'h': hidden ?? c.hidden,
      },
    );
    return get(id);
  }

  /// What deleting [id] removes: its events and their transfer
  /// counterparts in other streams.
  Future<({int events, int counterparts})> deleteCounts(String id) async {
    final r = await _conn.execute(
      Sql.named('''
        SELECT count(*)::int,
          (SELECT count(*)::int FROM events p
             JOIN events e ON e.transfer_id = p.transfer_id AND p.id <> e.id
            WHERE e.category_id = @id::uuid AND e.transfer_id IS NOT NULL
              AND p.category_id <> @id::uuid)
        FROM events WHERE category_id = @id::uuid
      '''),
      parameters: {'id': id},
    );
    return (events: r.first[0] as int, counterparts: r.first[1] as int);
  }

  /// Deletes every event in [id] (and each transfer's other side, skips
  /// and overrides), keeping the streams' event orders tidy; the category
  /// stays. Call inside a DB transaction. Returns the deleted event ids
  /// (null when the category does not exist).
  Future<List<String>?> deleteEvents(String id) async {
    final c = await get(id);
    if (c == null) return null;
    final rows = await _conn.execute(
      Sql.named('SELECT id::text FROM events WHERE category_id = @id::uuid '
          'ORDER BY created_at'),
      parameters: {'id': id},
    );
    final events = EventRepo(_conn);
    final deleted = <String>[];
    for (final r in rows) {
      final eid = r[0] as String;
      final e = await events.get(eid);
      if (e == null) continue; // already gone as a peer
      final peer = e.transfer?.peerId;
      if (await events.delete(eid)) deleted.add(eid);
      if (peer != null) deleted.add(peer);
    }
    return deleted;
  }

  /// Deletes [id] with every event in it (see [deleteEvents]). Returns the
  /// deleted event ids (null when the category does not exist).
  Future<List<String>?> delete(String id) async {
    final deleted = await deleteEvents(id);
    if (deleted == null) return null;
    await _conn.execute(
      Sql.named('DELETE FROM categories WHERE id = @id::uuid'),
      parameters: {'id': id},
    );
    return deleted;
  }

  /// The name an event body means: its `categoryId`'s name (it must be a
  /// category of [streamId]), else the legacy `name` (mapped to / creating
  /// a category by the DB). Throws [FormatException] for an unknown id.
  Future<String?> nameFor(
      String streamId, Object? categoryId, String? legacyName) async {
    if (categoryId == null) return legacyName;
    final c = await get(categoryId.toString());
    if (c == null || c.streamId != streamId) {
      throw FormatException('categoryId is not a category of this stream');
    }
    return c.name;
  }
}

/// The client's lane palette (stack_lanes.dart laneColors; SQL
/// budget_lane_color), in order.
const categoryPalette = [
  '#3D6FD8', '#9250C8', '#B36A12', '#2B8AA8', '#B8488E', '#5B7A2A', //
  '#6A62D6', '#A0602C', '#3C8A6E', '#8E5A9E', '#4A78A8', '#9C7A1E',
];
