import 'package:budget_server/repo/user_repo.dart';
import 'package:postgres/postgres.dart';

/// A user to own test projects (projects.owner_id is NOT NULL since 009).
Future<String> testOwnerId(Session c,
        [String email = 'test-owner@example.com']) async =>
    (await UserRepo(c).ensure(email, isAdmin: false)).id;
