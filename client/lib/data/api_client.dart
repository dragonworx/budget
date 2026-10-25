import 'dart:convert';

import 'dart:math';

import 'package:http/http.dart' as http;

import '../boot/page_stub.dart'
    if (dart.library.js_interop) '../boot/page_web.dart'
    as page;
import '../config.dart';
import 'http_client_stub.dart'
    if (dart.library.js_interop) 'http_client_web.dart'
    as platform;

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.body});

  final String message;
  final int? statusCode;
  final String? body;

  @override
  String toString() => message;
}

/// Thin HTTP wrapper around the Budget REST API.
class ApiRequestStats {
  int started = 0;
  int completed = 0;
  int get inFlight => started - completed;
}

class ApiClient {
  /// Global request counters, used by the boot loader to know when the
  /// initial data has arrived.
  static final ApiRequestStats stats = ApiRequestStats();
  static Object? firstFailure;

  static Future<T> _track<T>(Future<T> Function() run) async {
    stats.started++;
    try {
      return await run();
    } catch (e) {
      firstFailure ??= e;
      rethrow;
    } finally {
      stats.completed++;
    }
  }

  /// Called when a non-auth request comes back 401 (session missing or
  /// expired). The auth state registers this to route to sign-in.
  static void Function()? onUnauthorized;

  /// Called when a response suggests this tab runs an outdated build (a
  /// removed route, or HTML where JSON was expected). The version check
  /// then reloads into the new build if one is live.
  static void Function()? onOutdatedSuspected;

  static const outdatedMessage = 'Budgie was updated. Please reload the page.';

  static bool _looksLikeHtml(String body) {
    final t = body.trimLeft().toLowerCase();
    return t.startsWith('<!doctype') || t.startsWith('<html');
  }

  /// Per-tab id, echoed by the server in realtime events.
  static final String clientId = _randomId();

  static String _randomId() {
    final r = Random();
    return List.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  ApiClient({http.Client? httpClient, String? baseUrl})
    : _http = httpClient ?? platform.createHttpClient(),
      baseUrl = (baseUrl ?? AppConfig.apiBaseUrl).replaceAll(RegExp(r'/$'), '');

  final http.Client _http;
  final String baseUrl;

  Uri _uri(String path, [Map<String, String>? query]) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$baseUrl$normalized').replace(queryParameters: query);
  }

  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    final response = await _track(
      () => _http.get(_uri(path, query), headers: _headers()),
    );
    return _decode(response, path: path);
  }

  Future<dynamic> post(String path, {Object? body}) async {
    final response = await _track(
      () => _http.post(
        _uri(path),
        headers: _headers(),
        body: body == null ? null : jsonEncode(body),
      ),
    );
    return _decode(response, path: path);
  }

  Future<dynamic> patch(String path, {Object? body}) async {
    final response = await _track(
      () => _http.patch(
        _uri(path),
        headers: _headers(),
        body: body == null ? null : jsonEncode(body),
      ),
    );
    return _decode(response, path: path);
  }

  Future<dynamic> put(String path, {Object? body}) async {
    final response = await _track(
      () => _http.put(
        _uri(path),
        headers: _headers(),
        body: body == null ? null : jsonEncode(body),
      ),
    );
    return _decode(response, path: path);
  }

  /// PUT that still completes if the page is being hidden or unloaded
  /// (fetch keepalive); a normal PUT where that is unavailable. Fire and
  /// forget: errors are swallowed.
  void putKeepalive(String path, Object body) {
    final sent = page.keepaliveRequest(
      'PUT',
      _uri(path).toString(),
      _headers(),
      jsonEncode(body),
    );
    if (!sent) put(path, body: body).catchError((Object _) => null);
  }

  Future<void> delete(String path) async {
    final response = await _track(
      () => _http.delete(_uri(path), headers: _headers()),
    );
    _decode(response, allowEmpty: true, path: path);
  }

  Map<String, String> _headers() => {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    // Always fetch live data (a cached list would resurrect deleted items).
    'Cache-Control': 'no-cache',
    // CSRF defence required by the server on every request.
    'X-Requested-With': 'budget',
    'X-Client-Id': clientId,
  };

  dynamic _decode(
    http.Response response, {
    bool allowEmpty = false,
    String path = '',
  }) {
    final status = response.statusCode;
    if (status == 401 && !path.contains('api/auth/')) {
      onUnauthorized?.call();
    }
    final body = response.body;
    if (status >= 200 && status < 300) {
      if (body.isEmpty) {
        if (allowEmpty) return null;
        return null;
      }
      try {
        return jsonDecode(body);
      } on FormatException {
        if (_looksLikeHtml(body)) {
          onOutdatedSuspected?.call();
          throw ApiException(outdatedMessage, statusCode: status, body: body);
        }
        rethrow;
      }
    }
    if (status == 404 || status == 410 || _looksLikeHtml(body)) {
      onOutdatedSuspected?.call();
    }
    if (_looksLikeHtml(body)) {
      throw ApiException(outdatedMessage, statusCode: status, body: body);
    }

    String message = 'Request failed ($status)';
    try {
      final parsed = jsonDecode(body);
      if (parsed is Map && parsed['error'] != null) {
        message = parsed['error'].toString();
      } else if (parsed is Map && parsed['message'] != null) {
        message = parsed['message'].toString();
      }
    } catch (_) {
      if (body.isNotEmpty) message = body;
    }
    throw ApiException(message, statusCode: status, body: body);
  }

  void close() => _http.close();
}

/// Human-readable message for an error from the API layer.
String friendlyError(Object error) {
  if (error is ApiException) return error.message;
  final text = error.toString();
  if (text.contains('Failed to fetch') ||
      text.contains('ClientException') ||
      text.contains('SocketException') ||
      text.contains('XMLHttpRequest')) {
    return "Can't reach the budget server. Check your connection and try again.";
  }
  if (text.contains('TimeoutException')) {
    return 'The server took too long to respond. Try again.';
  }
  return text;
}
