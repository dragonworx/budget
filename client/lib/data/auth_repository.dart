import 'api_client.dart';

/// The signed-in user, as returned by the auth API.
class AuthUser {
  const AuthUser({
    required this.id,
    required this.email,
    this.name,
    this.pictureUrl,
    this.isAdmin = false,
  });

  final String id;
  final String email;
  final String? name;
  final String? pictureUrl;
  final bool isAdmin;

  String get displayName =>
      (name != null && name!.trim().isNotEmpty) ? name! : email;

  String get initials {
    final source = displayName.trim();
    if (source.isEmpty) return '?';
    final parts = source.split(RegExp(r'[\s@._-]+')).where((p) => p.isNotEmpty);
    return parts.take(2).map((p) => p[0].toUpperCase()).join();
  }

  static AuthUser fromJson(Map<String, dynamic> json) {
    final pic = json['pictureUrl'] ?? json['picture_url'] ?? json['picture'];
    final admin = json['isAdmin'] ?? json['is_admin'];
    return AuthUser(
      id: (json['id'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      name: json['name']?.toString(),
      pictureUrl: pic?.toString(),
      isAdmin: admin == true,
    );
  }

  /// Accepts `{user: {...}}`, `{user: null}` or a bare user object.
  static AuthUser? fromResponse(dynamic body) {
    if (body is! Map) return null;
    final map = Map<String, dynamic>.from(body);
    if (map.containsKey('user')) {
      final u = map['user'];
      return u is Map ? fromJson(Map<String, dynamic>.from(u)) : null;
    }
    if (map['email'] != null) return fromJson(map);
    return null;
  }
}

/// `GET /api/auth/config`: what the sign-in page needs, plus the current user.
class AuthConfig {
  const AuthConfig({
    this.googleClientId,
    this.googleUxMode = 'auto',
    this.devBypass = false,
    this.user,
  });

  final String? googleClientId;

  /// `popup`, `redirect` or `auto` (see the server's GOOGLE_UX_MODE).
  final String googleUxMode;
  final bool devBypass;
  final AuthUser? user;

  static AuthConfig fromJson(Map<String, dynamic> json) {
    final id = json['googleClientId'] ?? json['google_client_id'];
    final dev = json['devBypass'] ?? json['dev_bypass'];
    return AuthConfig(
      googleClientId: (id == null || id.toString().isEmpty)
          ? null
          : id.toString(),
      googleUxMode: switch (json['googleUxMode']) {
        'popup' => 'popup',
        'redirect' => 'redirect',
        _ => 'auto',
      },
      devBypass: dev == true,
      user: AuthUser.fromResponse(json),
    );
  }
}

abstract class AuthRepository {
  Future<AuthConfig> config();
  Future<AuthUser?> me();
  Future<AuthUser> signInWithGoogle(String credential);
  Future<AuthUser> devLogin();
  Future<void> logout();
}

class HttpAuthRepository implements AuthRepository {
  HttpAuthRepository(this._api);

  final ApiClient _api;

  @override
  Future<AuthConfig> config() async {
    final body = await _api.get('/api/auth/config');
    return AuthConfig.fromJson(
      body is Map ? Map<String, dynamic>.from(body) : const {},
    );
  }

  @override
  Future<AuthUser?> me() async {
    try {
      return AuthUser.fromResponse(await _api.get('/api/auth/me'));
    } on ApiException catch (e) {
      if (e.statusCode == 401) return null;
      rethrow;
    }
  }

  @override
  Future<AuthUser> signInWithGoogle(String credential) async {
    final body = await _api.post(
      '/api/auth/google',
      body: {'credential': credential},
    );
    return _require(body);
  }

  @override
  Future<AuthUser> devLogin() async =>
      _require(await _api.post('/api/auth/dev-login'));

  @override
  Future<void> logout() async {
    await _api.post('/api/auth/logout');
  }

  AuthUser _require(dynamic body) {
    final user = AuthUser.fromResponse(body);
    if (user == null) throw ApiException('Sign-in failed: no user returned');
    return user;
  }
}
