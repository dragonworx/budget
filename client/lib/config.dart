/// Runtime configuration injected via `--dart-define`.
class AppConfig {
  AppConfig._();

  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8080',
  );

  /// Google OAuth web client id. Optional: the server's `/api/auth/config`
  /// value is used when this is empty (no rebuild needed).
  static const String googleClientId = String.fromEnvironment(
    'GOOGLE_CLIENT_ID',
  );
}
