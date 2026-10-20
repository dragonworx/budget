import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config.dart';
import '../data/api_client.dart';
import '../data/auth_repository.dart';
import '../features/auth/google_button.dart';
import 'providers.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return HttpAuthRepository(ref.watch(apiClientProvider));
});

/// Snapshot of auth: the user (null = signed out) and sign-in options.
class AuthState {
  const AuthState({
    this.user,
    this.googleClientId,
    this.googleUxMode = 'auto',
    this.devBypass = false,
  });

  final AuthUser? user;
  final String? googleClientId;
  final String googleUxMode;
  final bool devBypass;

  bool get signedIn => user != null;

  AuthState copyWith({AuthUser? user, bool clearUser = false}) => AuthState(
    user: clearUser ? null : (user ?? this.user),
    googleClientId: googleClientId,
    googleUxMode: googleUxMode,
    devBypass: devBypass,
  );
}

final authProvider = AsyncNotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);

class AuthNotifier extends AsyncNotifier<AuthState> {
  @override
  Future<AuthState> build() async {
    ApiClient.onUnauthorized = _onUnauthorized;
    ref.onDispose(() {
      if (ApiClient.onUnauthorized == _onUnauthorized) {
        ApiClient.onUnauthorized = null;
      }
    });
    final repo = ref.read(authRepositoryProvider);
    final config = await repo.config();
    final clientId = AppConfig.googleClientId.isNotEmpty
        ? AppConfig.googleClientId
        : config.googleClientId;
    return AuthState(
      user: config.user,
      googleClientId: clientId,
      googleUxMode: config.googleUxMode,
      devBypass: config.devBypass,
    );
  }

  AuthState get _current => state.valueOrNull ?? const AuthState();

  void _onUnauthorized() {
    if (_current.signedIn) {
      state = AsyncData(_current.copyWith(clearUser: true));
    }
  }

  Future<void> signInWithGoogle(String credential) async {
    final user = await ref
        .read(authRepositoryProvider)
        .signInWithGoogle(credential);
    _signedIn(user);
  }

  Future<void> devLogin() async {
    final user = await ref.read(authRepositoryProvider).devLogin();
    _signedIn(user);
  }

  void _signedIn(AuthUser user) {
    // Drop any data cached for a previous user.
    ref.invalidate(accountsProvider);
    ref.invalidate(accountProvider);
    ref.invalidate(myInvitesProvider);
    // A fresh sign-in lands on the last-used account again.
    ref.read(landedProvider.notifier).state = false;
    state = AsyncData(_current.copyWith(user: user));
  }

  Future<void> signOut() async {
    try {
      await ref.read(authRepositoryProvider).logout();
    } catch (e) {
      debugPrint('logout failed: $e');
    }
    disableGoogleAutoSelect();
    state = AsyncData(_current.copyWith(clearUser: true));
    ref.invalidate(accountsProvider);
    ref.invalidate(accountProvider);
    ref.read(landedProvider.notifier).state = false;
  }
}
