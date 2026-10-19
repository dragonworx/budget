import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

class Scenario {
  const Scenario({
    required this.id,
    required this.accountId,
    required this.name,
    required this.colorIndex,
    required this.included,
    required this.request,
    required this.createdAt,
    this.version = 1,
  });

  final int version;

  final String id;
  final String accountId;
  final String name;
  final int colorIndex;
  final bool included;
  final Map<String, dynamic> request;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'accountId': accountId,
    'name': name,
    'colorIndex': colorIndex,
    'included': included,
    'request': request,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'version': version,
  };
}

class ScenarioRepo {
  ScenarioRepo(this._conn);

  final Session _conn;
  final _uuid = const Uuid();

  static const _cols =
      'id, account_id, name, color_index, included, request, created_at, version';

  Future<List<Scenario>> listByAccount(String accountId) async {
    final rows = await _conn.execute(
      Sql.named(
        'SELECT $_cols FROM scenarios WHERE account_id = @a '
        'ORDER BY created_at ASC',
      ),
      parameters: {'a': accountId},
    );
    return rows.map(_fromRow).toList();
  }

  Future<Scenario?> get(String id) async {
    final rows = await _conn.execute(
      Sql.named('SELECT $_cols FROM scenarios WHERE id = @id'),
      parameters: {'id': id},
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<Scenario> create({
    required String accountId,
    required String name,
    required int colorIndex,
    required bool included,
    required Map<String, dynamic> request,
  }) async {
    final rows = await _conn.execute(
      Sql.named('''
        INSERT INTO scenarios (id, account_id, name, color_index, included, request)
        VALUES (@id, @a, @name, @color, @included, @request::jsonb)
        RETURNING $_cols
      '''),
      parameters: {
        'id': _uuid.v4(),
        'a': accountId,
        'name': name,
        'color': colorIndex,
        'included': included,
        'request': jsonEncode(request),
      },
    );
    return _fromRow(rows.first);
  }

  Future<Scenario?> update(
    String id, {
    String? name,
    int? colorIndex,
    bool? included,
    Map<String, dynamic>? request,
  }) async {
    final rows = await _conn.execute(
      Sql.named('''
        UPDATE scenarios SET
          name = COALESCE(@name, name),
          color_index = COALESCE(@color, color_index),
          included = COALESCE(@included, included),
          request = COALESCE(@request::jsonb, request)
        WHERE id = @id
        RETURNING $_cols
      '''),
      parameters: {
        'id': id,
        'name': name,
        'color': colorIndex,
        'included': included,
        'request': request == null ? null : jsonEncode(request),
      },
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<bool> delete(String id) async {
    final r = await _conn.execute(
      Sql.named('DELETE FROM scenarios WHERE id = @id'),
      parameters: {'id': id},
    );
    return r.affectedRows > 0;
  }

  Scenario _fromRow(ResultRow row) {
    final m = row.toColumnMap();
    final req = m['request'];
    return Scenario(
      id: m['id'].toString(),
      accountId: m['account_id'].toString(),
      name: m['name'] as String,
      colorIndex: m['color_index'] as int,
      included: m['included'] as bool,
      request: req is String
          ? jsonDecode(req) as Map<String, dynamic>
          : Map<String, dynamic>.from(req as Map),
      createdAt: m['created_at'] as DateTime,
      version: (m['version'] as int?) ?? 1,
    );
  }
}
