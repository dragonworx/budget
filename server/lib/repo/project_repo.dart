import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../domain/models.dart';

class ProjectRepo {
  ProjectRepo(this._conn);

  final Session _conn;
  final _uuid = const Uuid();

  Future<List<Project>> list({required String ownerId}) async {
    final rows = await _conn.execute(
      Sql.named('SELECT id, name, created_at, version FROM projects '
          'WHERE owner_id = @o::uuid ORDER BY created_at ASC'),
      parameters: {'o': ownerId},
    );
    return rows.map(_fromRow).toList();
  }

  /// Projects the user can see: memberships (with role) plus projects where
  /// only some accounts are shared with them (`access: 'account'`).
  Future<List<Map<String, Object?>>> listAccessible(String userId) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT p.id, p.name, p.created_at, p.version, m.role::text,
               u.id::text, u.email, u.name, u.picture_url,
               ARRAY(SELECT s.account_id::text FROM account_shares s
                     JOIN accounts a ON a.id = s.account_id
                     WHERE a.project_id = p.id AND s.user_id = @u::uuid)
        FROM projects p
        JOIN users u ON u.id = p.owner_id
        LEFT JOIN project_members m
          ON m.project_id = p.id AND m.user_id = @u::uuid
        WHERE m.user_id IS NOT NULL OR EXISTS (
          SELECT 1 FROM account_shares s JOIN accounts a ON a.id = s.account_id
          WHERE a.project_id = p.id AND s.user_id = @u::uuid)
        ORDER BY p.created_at ASC
      '''),
      parameters: {'u': userId},
    );
    return rows.map((r) {
      final role = r[4] as String?;
      return {
        ..._fromRow(r).toJson(),
        'role': role ?? 'viewer',
        'access': role == null ? 'account' : 'project',
        'shared': r[5] != userId,
        'owner': {
          'id': r[5],
          'email': r[6],
          'name': r[7],
          'pictureUrl': r[8],
        },
        'sharedAccountIds': (r[9] as List).map((e) => e.toString()).toList(),
      };
    }).toList();
  }

  Future<Project?> get(String id) async {
    final rows = await _conn.execute(
      Sql.named(
          'SELECT id, name, created_at, version FROM projects WHERE id = @id'),
      parameters: {'id': id},
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<Project> create(String name, {required String ownerId}) async {
    final id = _uuid.v4();
    final rows = await _conn.execute(
      Sql.named('''
        WITH p AS (
          INSERT INTO projects (id, name, owner_id, created_by)
          VALUES (@id, @name, @owner::uuid, @owner::uuid)
          RETURNING id, name, created_at, version, owner_id
        ), m AS (
          INSERT INTO project_members (project_id, user_id, role, added_by)
          SELECT id, owner_id, 'owner', owner_id FROM p
        )
        SELECT id, name, created_at, version FROM p
      '''),
      parameters: {'id': id, 'name': name, 'owner': ownerId},
    );
    return _fromRow(rows.first);
  }

  Future<Project?> update(String id, {String? name}) async {
    if (name == null) return get(id);
    final rows = await _conn.execute(
      Sql.named('''
        UPDATE projects SET name = @name
        WHERE id = @id
        RETURNING id, name, created_at, version
      '''),
      parameters: {'id': id, 'name': name},
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<bool> delete(String id) async {
    // Transfers into accounts of other projects survive as plain rows.
    await _conn.execute(
      Sql.named('''
        UPDATE transactions SET transfer_id = NULL
        WHERE account_id NOT IN (SELECT id FROM accounts WHERE project_id = @p::uuid)
          AND transfer_id IN (
            SELECT t.transfer_id FROM transactions t
            JOIN accounts a ON a.id = t.account_id
            WHERE a.project_id = @p::uuid AND t.transfer_id IS NOT NULL)
      '''),
      parameters: {'p': id},
    );
    final rows = await _conn.execute(
      Sql.named('DELETE FROM projects WHERE id = @id RETURNING id'),
      parameters: {'id': id},
    );
    return rows.isNotEmpty;
  }

  Project _fromRow(ResultRow row) {
    return Project(
      id: row[0].toString(),
      name: row[1] as String,
      createdAt: (row[2] as DateTime).toUtc(),
      version: row.length > 3 ? (row[3] as int? ?? 1) : 1,
    );
  }
}
