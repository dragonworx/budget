import 'package:budget_server/repo/user_repo.dart';
import 'package:postgres/postgres.dart';

/// A user to own test streams (streams.owner_id is NOT NULL).
Future<String> testOwnerId(Session c,
        [String email = 'test-owner@example.com']) async =>
    (await UserRepo(c).ensure(email, isAdmin: false)).id;

/// Removes every stream [ownerId] owns (cascades to their data).
Future<void> deleteOwnedStreams(Session c, String ownerId) =>
    c.execute(Sql.named('DELETE FROM streams WHERE owner_id = @o::uuid'),
        parameters: {'o': ownerId});
