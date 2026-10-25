import 'package:postgres/postgres.dart';

import 'live_event.dart';

/// What one user can currently read, for filtering events.
class AccessSet {
  AccessSet(this.userId,
      {this.ownedStreams = const {},
      this.sharedStreams = const {},
      this.isAdmin = false,
      this.disabled = false});

  final String userId;

  /// Streams the user owns.
  final Set<String> ownedStreams;

  /// Streams shared directly with the user.
  final Set<String> sharedStreams;
  final bool isAdmin;
  final bool disabled;

  static Future<AccessSet> load(Session db, String userId) async {
    final r = await db.execute(
      Sql.named('''
        SELECT
          ARRAY(SELECT id::text FROM streams WHERE owner_id = @u::uuid),
          ARRAY(SELECT s.stream_id::text FROM stream_shares s WHERE s.user_id = @u::uuid),
          COALESCE((SELECT is_admin FROM users WHERE id = @u::uuid), false),
          COALESCE((SELECT disabled FROM users WHERE id = @u::uuid), true)
      '''),
      parameters: {'u': userId},
    );
    Set<String> set(Object? v) => {for (final x in (v as List)) x.toString()};
    final row = r.first;
    return AccessSet(userId,
        ownedStreams: set(row[0]),
        sharedStreams: set(row[1]),
        isAdmin: row[2] as bool,
        disabled: row[3] as bool);
  }

  bool canReadStream(String id) =>
      ownedStreams.contains(id) || sharedStreams.contains(id);

  bool touches(LiveEvent e) => e.streamId != null && canReadStream(e.streamId!);

  /// Whether [e] may be delivered to this user.
  bool canRead(LiveEvent e) {
    if (e.subjectUserId == userId) return true;
    if (e.entity == 'admin') return isAdmin;
    final a = e.streamId;
    return a != null && canReadStream(a);
  }
}
