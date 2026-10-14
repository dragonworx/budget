import 'dart:io';

/// Runtime configuration from environment variables.
class Config {
  Config({
    required this.databaseUrl,
    required this.host,
    required this.port,
  });

  factory Config.fromEnvironment() {
    return Config(
      databaseUrl: env('DATABASE_URL', 'postgres://budget:budget@localhost:5432/budget'),
      host: env('API_HOST', '0.0.0.0'),
      port: int.parse(env('API_PORT', '8080')),
    );
  }

  final String databaseUrl;
  final String host;
  final int port;
}

String env(String key, String fallback) {
  final value = Platform.environment[key];
  if (value == null || value.isEmpty) return fallback;
  return value;
}
