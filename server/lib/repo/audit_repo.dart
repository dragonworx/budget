import 'dart:convert';

import 'package:postgres/postgres.dart';

import '../auth/authz.dart';

const _entityTables = {
  'project': 'projects',
  'account': 'accounts',
  'transaction': 'transactions',
  'scenario': 'scenarios',
};

/// Writes audit_log rows. Every mutation of shared data gets one; `id` is
/// the global event sequence used for real-time replay (P5).
class AuditRepo {
  AuditRepo(this._db);
  final Session _db;

  Future<int> record({
    required String? userId,
    required String action,
    String? projectId,
    String? accountId,
    String? entityId,
    Map<String, Object?> detail = const {},
  }) async {
    final entity = action.split('.').first;
    final r = await _db.execute(
      Sql.named('''
        INSERT INTO audit_log (user_id, project_id, account_id, action, entity, entity_id, detail)
        VALUES (@u::uuid, @p::uuid, @a::uuid, @action, @entity, @eid, @detail::jsonb)
        RETURNING id
      '''),
      parameters: {
        'u': userId,
        'p': _uuidOrNull(projectId),
        'a': _uuidOrNull(accountId),
        'action': action,
        'entity': entity,
        'eid': entityId,
        'detail': jsonEncode(detail),
      },
    );
    return r.first[0] as int;
  }

  /// Audit row for a successful API mutation described by [policy]. Also
  /// stamps created_by/updated_by on the affected row.
  Future<void> recordRequest({
    required String userId,
    required Policy policy,
    required Access access,
    required Map<String, String> params,
    String? createdId,
    Map<String, dynamic>? response,
  }) async {
    final action = policy.event!;
    final entity = action.split('.').first;
    final isCreate = action.endsWith('.created');
    String? entityId = switch (entity) {
      'project' => params['p'],
      'account' => params['a'],
      'transaction' => params['t'],
      'skip' => params['t'],
      'scenario' => params['s'],
      'membership' || 'account_share' => params['u'],
      'invite' => params['i'],
      'admin' => params['u'] ?? params['pattern'],
      _ => null,
    };
    if (isCreate || entityId == null) entityId = createdId ?? entityId;

    var projectId = access.projectId;
    var accountId = access.accountId;
    if (action == 'project.created') projectId = createdId;
    if (action == 'account.created') accountId = createdId;
    if (action == 'invite.accepted' && response != null) {
      projectId = response['projectId']?.toString();
      accountId = response['accountId']?.toString();
    }

    await record(
      userId: userId,
      action: action,
      projectId: projectId,
      accountId: accountId,
      entityId: entityId,
      detail: {
        if (params['d'] != null) 'date': params['d'],
        if (response?['version'] != null) 'version': response!['version'],
        if (params['peer'] != null) 'peerAccountId': params['peer'],
        if (action == 'transactions.imported' && response != null)
          'imported': response['imported'] ?? response['created'],
      },
    );

    final table = _entityTables[entity];
    if (table != null &&
        !action.endsWith('.deleted') &&
        entityId != null &&
        uuidRe.hasMatch(entityId)) {
      await _db.execute(
        Sql.named('UPDATE $table SET updated_by = @u::uuid, '
            'created_by = COALESCE(created_by, @u::uuid) WHERE id = @id::uuid'),
        parameters: {'u': userId, 'id': entityId},
      );
    }
  }

  static String? _uuidOrNull(String? v) =>
      v != null && uuidRe.hasMatch(v) ? v : null;
}
