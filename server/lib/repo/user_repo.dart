import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

class User {
  User({
    required this.id,
    required this.email,
    this.googleSub,
    this.name,
    this.pictureUrl,
    this.isAdmin = false,
    this.disabled = false,
  });

  final String id;
  final String email;
  final String? googleSub;
  final String? name;
  final String? pictureUrl;
  final bool isAdmin;
  final bool disabled;

  Map<String, Object?> toJson() => {
        'id': id,
        'email': email,
        'name': name,
        'pictureUrl': pictureUrl,
        'isAdmin': isAdmin,
      };
}

const userCols =
    'u.id, u.email, u.google_sub, u.name, u.picture_url, u.is_admin, u.disabled';

User userFromRow(List<Object?> r, [int o = 0]) => User(
      id: r[o].toString(),
      email: r[o + 1] as String,
      googleSub: r[o + 2] as String?,
      name: r[o + 3] as String?,
      pictureUrl: r[o + 4] as String?,
      isAdmin: r[o + 5] as bool,
      disabled: r[o + 6] as bool,
    );

class UserRepo {
  UserRepo(this._db);
  final Session _db;
  static const _uuid = Uuid();

  Future<User?> byEmail(String email) async {
    final rows = await _db.execute(
        Sql.named('SELECT $userCols FROM users u WHERE u.email = @e'),
        parameters: {'e': email.toLowerCase()});
    return rows.isEmpty ? null : userFromRow(rows.first);
  }

  /// Upserts a Google identity: link by `sub`, else by verified email.
  Future<User> upsertGoogle({
    required String sub,
    required String email,
    String? name,
    String? picture,
    required bool isAdmin,
  }) async {
    final rows = await _db.execute(
      Sql.named('''
        INSERT INTO users AS u (id, google_sub, email, name, picture_url, is_admin, last_login_at)
        VALUES (@id, @sub, @email, @name, @pic, @admin, now())
        ON CONFLICT (email) DO UPDATE SET
          google_sub = EXCLUDED.google_sub, name = EXCLUDED.name,
          picture_url = EXCLUDED.picture_url, is_admin = EXCLUDED.is_admin,
          last_login_at = now()
        RETURNING $userCols
      '''),
      parameters: {
        'id': _uuid.v4(),
        'sub': sub,
        'email': email.toLowerCase(),
        'name': name,
        'pic': picture,
        'admin': isAdmin,
      },
    );
    return userFromRow(rows.first);
  }

  /// Ensures a user row for [email] (used by the dev bypass).
  Future<User> ensure(String email, {required bool isAdmin}) async {
    final rows = await _db.execute(
      Sql.named('''
        INSERT INTO users AS u (id, email, is_admin, last_login_at)
        VALUES (@id, @email, @admin, now())
        ON CONFLICT (email) DO UPDATE SET is_admin = EXCLUDED.is_admin,
          last_login_at = now()
        RETURNING $userCols
      '''),
      parameters: {
        'id': _uuid.v4(),
        'email': email.toLowerCase(),
        'admin': isAdmin
      },
    );
    return userFromRow(rows.first);
  }
}
