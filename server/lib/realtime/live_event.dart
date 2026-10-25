/// A change event: one audit_log row. `id` is the global, monotonically
/// increasing event sequence (SSE `id:` / Last-Event-ID).
class LiveEvent {
  LiveEvent({
    required this.id,
    required this.action,
    required this.entity,
    this.entityId,
    this.streamId,
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
  final String? streamId;
  final String? actorId;
  final String? subjectUserId;
  final String? clientId;
  final DateTime at;
  final Map<String, dynamic> detail;

  static const channel = 'budget_events';

  /// audit_log columns in [fromRow] order.
  static const columns = 'id, action, entity, entity_id, '
      'stream_id::text, user_id::text, subject_user_id::text, client_id, at, detail';

  factory LiveEvent.fromRow(List<Object?> r) => LiveEvent(
        id: r[0] as int,
        action: r[1] as String,
        entity: r[2] as String,
        entityId: r[3] as String?,
        streamId: r[4] as String?,
        actorId: r[5] as String?,
        subjectUserId: r[6] as String?,
        clientId: r[7] as String?,
        at: (r[8] as DateTime).toUtc(),
        detail: r[9] is Map ? Map<String, dynamic>.from(r[9] as Map) : const {},
      );

  factory LiveEvent.fromJson(Map<String, dynamic> j) => LiveEvent(
        id: (j['id'] as num).toInt(),
        action: j['action'] as String,
        entity: j['entity'] as String,
        entityId: j['entityId'] as String?,
        streamId: j['streamId'] as String?,
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
        'streamId': streamId,
        'actorId': actorId,
        'subjectUserId': subjectUserId,
        'clientId': clientId,
        'at': at.toIso8601String(),
        'detail': detail,
      };

  /// Events that change who can see what.
  bool get changesAccess =>
      entity == 'stream_share' ||
      action == 'invite.accepted' ||
      action == 'stream.created' ||
      action == 'stream.deleted' ||
      action == 'admin.user_updated';
}
