import 'package:budget_server/repo/user_repo.dart';
import 'package:postgres/postgres.dart';

/// A user to own test streams (streams.owner_id is NOT NULL).
Future<String> testOwnerId(Session c,
        [String email = 'test-owner@example.com']) async =>
    (await UserRepo(c).ensure(email, isAdmin: false)).id;

/// Removes every stream [ownerId] owns (cascades to their data).
/// Deletes [ownerId]'s streams (and their events) and categories (global
/// per owner since migration 025).
Future<void> deleteOwnedStreams(Session c, String ownerId) async {
  await c.execute(Sql.named('DELETE FROM streams WHERE owner_id = @o::uuid'),
      parameters: {'o': ownerId});
  await c.execute(Sql.named('DELETE FROM categories WHERE owner_id = @o::uuid'),
      parameters: {'o': ownerId});
}
