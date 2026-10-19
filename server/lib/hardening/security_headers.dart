import 'package:shelf/shelf.dart';

/// Defensive headers on API/health responses (never HTML).
Middleware securityHeaders({required bool hsts}) {
  const base = {
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY',
    'referrer-policy': 'no-referrer',
    'cross-origin-resource-policy': 'same-origin',
    'content-security-policy': "default-src 'none'; frame-ancestors 'none'",
    'permissions-policy': 'interest-cohort=()',
  };
  return (inner) => (request) async {
        final res = await inner(request);
        final p = request.url.path;
        if (!(p.startsWith('api') || p == 'health' || p == 'ready')) return res;
        return res.change(headers: {
          ...base,
          if (hsts)
            'strict-transport-security': 'max-age=31536000; includeSubDomains',
        });
      };
}
