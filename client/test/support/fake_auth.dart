import 'package:budget_client/data/auth_repository.dart';

const adminUser = AuthUser(
  id: 'u1',
  email: 'musicartscience@gmail.com',
  name: 'Ali Chamas',
  isAdmin: true,
);

class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({
    this.user,
    this.devBypass = false,
    this.googleClientId,
    this.failConfig = false,
  });

  AuthUser? user;
  bool devBypass;
  String? googleClientId;
  bool failConfig;
  int devLogins = 0;
  int logouts = 0;
  final List<String> credentials = [];

  @override
  Future<AuthConfig> config() async {
    if (failConfig) throw Exception('offline');
    return AuthConfig(
      googleClientId: googleClientId,
      devBypass: devBypass,
      user: user,
    );
  }

  @override
  Future<AuthUser> devLogin() async {
    devLogins++;
    return user = adminUser;
  }

  @override
  Future<void> logout() async {
    logouts++;
    user = null;
  }

  @override
  Future<AuthUser?> me() async => user;

  @override
  Future<AuthUser> signInWithGoogle(String credential) async {
    credentials.add(credential);
    return user = adminUser;
  }
}
