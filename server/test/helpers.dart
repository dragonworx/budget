import 'package:budget_server/repo/user_repo.dart';
import 'package:postgres/postgres.dart';

/// A user to own test pools (pools.owner_id is NOT NULL).
Future<String> testOwnerId(Session c,
        [String email = 'test-owner@example.com']) async =>
    (await UserRepo(c).ensure(email, isAdmin: false)).id;

/// Removes every pool [ownerId] owns (cascades to their data).
Future<void> deleteOwnedPools(Session c, String ownerId) =>
    c.execute(Sql.named('DELETE FROM pools WHERE owner_id = @o::uuid'),
        parameters: {'o': ownerId});
