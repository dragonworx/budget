/// A change event: one audit_log row. `id` is the global, monotonically
/// increasing event sequence (SSE `id:` / Last-Event-ID).
class BudgetEvent {
  BudgetEvent({
    required this.id,
    required this.action,
    required this.entity,
    this.entityId,
    this.projectId,
    this.accountId,
    this.actorId,
    this.subjectUserId,
    this.clientId,
    required this.at,
    this.detail = const {},
  });

  final int id;
  final String action;
  final String entity;
  final String? entityId;
  final String? projectId;
  final String? accountId;
  final String? actorId;
  final String? subjectUserId;
  final String? clientId;
  final DateTime at;
  final Map<String, dynamic> detail;

  static const channel = 'budget_events';

  /// audit_log columns in [fromRow] order.
  static const columns = 'id, action, entity, entity_id, project_id::text, '
      'account_id::text, user_id::text, subject_user_id::text, client_id, at, detail';

  factory BudgetEvent.fromRow(List<Object?> r) => BudgetEvent(
        id: r[0] as int,
        action: r[1] as String,
        entity: r[2] as String,
        entityId: r[3] as String?,
        projectId: r[4] as String?,
        accountId: r[5] as String?,
        actorId: r[6] as String?,
        subjectUserId: r[7] as String?,
        clientId: r[8] as String?,
        at: (r[9] as DateTime).toUtc(),
        detail:
            r[10] is Map ? Map<String, dynamic>.from(r[10] as Map) : const {},
      );

  factory BudgetEvent.fromJson(Map<String, dynamic> j) => BudgetEvent(
        id: (j['id'] as num).toInt(),
        action: j['action'] as String,
        entity: j['entity'] as String,
        entityId: j['entityId'] as String?,
        projectId: j['projectId'] as String?,
        accountId: j['accountId'] as String?,
        actorId: j['actorId'] as String?,
        subjectUserId: j['subjectUserId'] as String?,
        clientId: j['clientId'] as String?,
        at: DateTime.parse(j['at'] as String).toUtc(),
        detail: Map<String, dynamic>.from((j['detail'] as Map?) ?? const {}),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'action': action,
        'entity': entity,
        'entityId': entityId,
        'projectId': projectId,
        'accountId': accountId,
        'actorId': actorId,
        'subjectUserId': subjectUserId,
        'clientId': clientId,
        'at': at.toIso8601String(),
        'detail': detail,
      };

  /// Events that change who can see what.
  bool get changesAccess =>
      entity == 'membership' ||
      entity == 'account_share' ||
      action == 'invite.accepted' ||
      action == 'project.created' ||
      action == 'project.deleted' ||
      action == 'project.ownership_transferred' ||
      action == 'account.created' ||
      action == 'account.deleted' ||
      action == 'admin.user_updated';
}
