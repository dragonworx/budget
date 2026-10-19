import 'dart:convert';

import 'package:postgres/postgres.dart';

import '../auth/authz.dart';
import '../realtime/event.dart';

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

  /// Inserts the audit row and NOTIFYs it on [BudgetEvent.channel] in the
  /// same session, so listeners only see it once the mutation commits.
  Future<BudgetEvent> record({
    required String? userId,
    required String action,
    String? projectId,
    String? accountId,
    String? entityId,
    String? subjectUserId,
    String? clientId,
    Map<String, Object?> detail = const {},
  }) async {
    final entity = action.split('.').first;
    final r = await _db.execute(
      Sql.named('''
        INSERT INTO audit_log (user_id, project_id, account_id, action, entity,
                               entity_id, detail, subject_user_id, client_id)
        VALUES (@u::uuid, @p::uuid, @a::uuid, @action, @entity, @eid,
                @detail::jsonb, @subj::uuid, @client)
        RETURNING ${BudgetEvent.columns}
      '''),
      parameters: {
        'u': userId,
        'p': _uuidOrNull(projectId),
        'a': _uuidOrNull(accountId),
        'action': action,
        'entity': entity,
        'eid': entityId,
        'detail': jsonEncode(detail),
        'subj': _uuidOrNull(subjectUserId),
        'client': clientId == null || clientId.length > 100 ? null : clientId,
      },
    );
    final event = BudgetEvent.fromRow(r.first);
    await _db.execute(
      Sql.named('SELECT pg_notify(@ch, @payload)'),
      parameters: {
        'ch': BudgetEvent.channel,
        'payload': jsonEncode(event.toJson()),
      },
    );
    return event;
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
    String? clientId,
  }) async {
    var action = policy.event!;
    // An invite to an existing user grants access immediately.
    if (action == 'invite.created' && response?['status'] == 'added') {
      action = params['a'] != null ? 'account_share.added' : 'membership.added';
    }
    final entity = action.split('.').first;
    final isCreate = action.endsWith('.created');
    String? entityId = switch (entity) {
      'project' => params['p'],
      'account' => params['a'],
      'transaction' => params['t'],
      'skip' => params['t'],
      'scenario' => params['s'],
      'membership' ||
      'account_share' =>
        params['u'] ?? (response?['member'] as Map?)?['userId']?.toString(),
      'invite' => params['i'],
      'admin' => params['u'] ?? params['pattern'],
      _ => null,
    };
    if (isCreate || entityId == null) entityId = createdId ?? entityId;
    final subject = switch (entity) {
      'membership' ||
      'account_share' =>
        action.endsWith('.left') ? userId : entityId,
      'admin' when action == 'admin.user_updated' => params['u'],
      'invite' when action == 'invite.accepted' => userId,
      'project' when action == 'project.ownership_transferred' =>
        response?['ownerId']?.toString(),
      _ => null,
    };

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
      subjectUserId: subject,
      clientId: clientId,
      detail: {
        if (response?['role'] != null) 'role': response!['role'],
        if (response?['member'] is Map)
          'role': (response!['member'] as Map)['role'],
        if (action == 'admin.user_updated' && response?['disabled'] != null)
          'disabled': response!['disabled'],
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
