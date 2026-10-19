import 'dart:io';

/// Runtime configuration from environment variables (see /.env.example).
class Config {
  Config({
    required this.databaseUrl,
    required this.host,
    required this.port,
    this.appEnv = 'development',
    this.publicOrigin = 'http://localhost:8000',
    this.extraOrigins = const [],
    this.googleClientId = '',
    this.googleUxMode = 'auto',
    this.adminEmails = const [defaultAdminEmail],
    this.allowlist = const [],
    this.openSignup = false,
    this.invitesBypassAllowlist = true,
    this.devBypass = false,
    this.sessionSecret = devSessionSecret,
    this.sessionTtlDays = 30,
    this.dbPoolSize = 10,
    this.trustedProxies = const ['127.0.0.1', '::1'],
    this.rateLimitAuthPerMinute = 20,
    this.rateLimitPerMinute = 600,
    this.sessionCacheTtl = const Duration(seconds: 10),
    this.shutdownGrace = const Duration(seconds: 10),
    this.cleanupInterval = const Duration(hours: 1),
  });

  static const defaultAdminEmail = 'musicartscience@gmail.com';
  static const devSessionSecret = 'dev-insecure-session-secret';

  factory Config.fromEnvironment([Map<String, String>? source]) {
    final e = source ?? Platform.environment;
    String v(String k, String fallback) {
      final x = e[k];
      return (x == null || x.trim().isEmpty) ? fallback : x.trim();
    }

    bool b(String k, bool fallback) {
      final x = e[k]?.trim().toLowerCase();
      if (x == null || x.isEmpty) return fallback;
      return x == 'true' || x == '1' || x == 'yes';
    }

    return Config(
      databaseUrl:
          v('DATABASE_URL', 'postgres://budget:budget@localhost:5432/budget'),
      host: v('API_HOST', '0.0.0.0'),
      port: int.parse(v('API_PORT', '8080')),
      appEnv: v('APP_ENV', 'development').toLowerCase(),
      publicOrigin: v('PUBLIC_ORIGIN', 'http://localhost:8000')
          .replaceAll(RegExp(r'/+$'), ''),
      extraOrigins: csv(v('CORS_ORIGINS', '')),
      googleClientId: v('GOOGLE_CLIENT_ID', ''),
      googleUxMode: switch (v('GOOGLE_UX_MODE', 'auto').toLowerCase()) {
        'popup' => 'popup',
        'redirect' => 'redirect',
        _ => 'auto',
      },
      adminEmails: csv(v('ADMIN_EMAILS', defaultAdminEmail), lower: true),
      allowlist: csv(v('AUTH_ALLOWLIST', ''), lower: true),
      openSignup: b('AUTH_OPEN_SIGNUP', false),
      invitesBypassAllowlist: b('AUTH_INVITES_BYPASS_ALLOWLIST', true),
      devBypass: b('AUTH_DEV_BYPASS', false),
      sessionSecret: v('SESSION_SECRET', devSessionSecret),
      sessionTtlDays: int.parse(v('SESSION_TTL_DAYS', '30')),
      dbPoolSize: int.parse(v('DB_POOL_SIZE', '10')),
      trustedProxies: csv(v('TRUSTED_PROXIES', '127.0.0.1,::1')),
      rateLimitAuthPerMinute: int.parse(v('RATE_LIMIT_AUTH_PER_MIN', '20')),
      rateLimitPerMinute: int.parse(v('RATE_LIMIT_PER_MIN', '600')),
      sessionCacheTtl:
          Duration(seconds: int.parse(v('SESSION_CACHE_TTL_SECONDS', '10'))),
      shutdownGrace:
          Duration(seconds: int.parse(v('SHUTDOWN_GRACE_SECONDS', '10'))),
      cleanupInterval:
          Duration(minutes: int.parse(v('CLEANUP_INTERVAL_MINUTES', '60'))),
    );
  }

  final String databaseUrl;
  final String host;
  final int port;
  final String appEnv;
  final String publicOrigin;
  final List<String> extraOrigins;
  final String googleClientId;

  /// Google sign-in UX: `popup`, `redirect` (full-page, via
  /// /api/auth/google/redirect) or `auto` (redirect where popups can't
  /// report back: home-screen apps and in-app browsers; popup elsewhere).
  final String googleUxMode;
  final List<String> adminEmails;
  final List<String> allowlist;
  final bool openSignup;
  final bool invitesBypassAllowlist;
  final bool devBypass;
  final String sessionSecret;
  final int sessionTtlDays;
  final int dbPoolSize;

  /// Peers whose X-Forwarded-For is trusted (IPs or CIDRs, e.g. the Docker
  /// network Caddy runs on). Anyone else's XFF header is ignored.
  final List<String> trustedProxies;

  /// Per client IP on /api/auth/* (0 = off).
  final int rateLimitAuthPerMinute;

  /// Per session (or per IP when anonymous) on all /api routes (0 = off).
  final int rateLimitPerMinute;
  final Duration sessionCacheTtl;
  final Duration shutdownGrace;
  final Duration cleanupInterval;

  bool get isProduction => appEnv == 'production' || appEnv == 'prod';
  String get primaryAdminEmail =>
      adminEmails.isEmpty ? defaultAdminEmail : adminEmails.first;
  bool get secureCookies => publicOrigin.startsWith('https://');

  /// Origins allowed for CORS and the CSRF Origin check.
  Set<String> get allowedOrigins => {
        publicOrigin,
        ...extraOrigins,
        if (!isProduction) ...[
          'http://localhost:8000',
          'http://127.0.0.1:8000',
        ],
      };

  /// Throws [StateError] for unsafe combinations. The dev bypass can never
  /// run in production.
  void validate() {
    if (isProduction) {
      if (devBypass) {
        throw StateError(
            'AUTH_DEV_BYPASS=true is forbidden with APP_ENV=production');
      }
      if (sessionSecret == devSessionSecret || sessionSecret.length < 32) {
        throw StateError(
            'SESSION_SECRET must be set (>= 32 chars) in production');
      }
      if (googleClientId.isEmpty) {
        throw StateError('GOOGLE_CLIENT_ID must be set in production');
      }
      if (!publicOrigin.startsWith('https://')) {
        throw StateError('PUBLIC_ORIGIN must be https in production');
      }
    }
  }
}

List<String> csv(String raw, {bool lower = false}) => raw
    .split(',')
    .map((s) => lower ? s.trim().toLowerCase() : s.trim())
    .where((s) => s.isNotEmpty)
    .toList();

String env(String key, String fallback) {
  final value = Platform.environment[key];
  if (value == null || value.isEmpty) return fallback;
  return value;
}

/// Process environment merged over a dotenv file (process vars win). Looks
/// at $ENV_FILE, then ./.env, then ../.env (repo root when run from server/).
Map<String, String> loadEnvironment() {
  final merged = <String, String>{};
  final candidates = [
    if (Platform.environment['ENV_FILE'] != null)
      Platform.environment['ENV_FILE']!,
    '.env',
    '../.env',
  ];
  for (final path in candidates) {
    final f = File(path);
    if (!f.existsSync()) continue;
    merged.addAll(parseDotEnv(f.readAsStringSync()));
    break;
  }
  merged.addAll(Platform.environment);
  return merged;
}

Map<String, String> parseDotEnv(String text) {
  final out = <String, String>{};
  for (var line in text.split('\n')) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('export ')) line = line.substring(7).trim();
    final i = line.indexOf('=');
    if (i <= 0) continue;
    var v = line.substring(i + 1).trim();
    if (v.length >= 2 &&
        ((v.startsWith('"') && v.endsWith('"')) ||
            (v.startsWith("'") && v.endsWith("'")))) {
      v = v.substring(1, v.length - 1);
    } else {
      final hash = v.indexOf(' #');
      if (hash >= 0) v = v.substring(0, hash).trim();
    }
    out[line.substring(0, i).trim()] = v;
  }
  return out;
}
