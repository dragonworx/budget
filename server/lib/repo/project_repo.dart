import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../domain/models.dart';

class ProjectRepo {
  ProjectRepo(this._conn);

  final Session _conn;
  final _uuid = const Uuid();

  Future<List<Project>> list() async {
    final rows = await _conn.execute(
      'SELECT id, name, created_at FROM projects ORDER BY created_at ASC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<Project?> get(String id) async {
    final rows = await _conn.execute(
      Sql.named('SELECT id, name, created_at FROM projects WHERE id = @id'),
      parameters: {'id': id},
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<Project> create(String name) async {
    final id = _uuid.v4();
    final rows = await _conn.execute(
      Sql.named('''
        INSERT INTO projects (id, name)
        VALUES (@id, @name)
        RETURNING id, name, created_at
      '''),
      parameters: {'id': id, 'name': name},
    );
    return _fromRow(rows.first);
  }

  Future<Project?> update(String id, {String? name}) async {
    if (name == null) return get(id);
    final rows = await _conn.execute(
      Sql.named('''
        UPDATE projects SET name = @name
        WHERE id = @id
        RETURNING id, name, created_at
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
    );
  }
}
