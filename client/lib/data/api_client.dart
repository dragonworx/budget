import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.body});

  final String message;
  final int? statusCode;
  final String? body;

  @override
  String toString() => message;
}

/// Thin HTTP wrapper around the Budget REST API.
class ApiClient {
  ApiClient({http.Client? httpClient, String? baseUrl})
    : _http = httpClient ?? http.Client(),
      baseUrl = (baseUrl ?? AppConfig.apiBaseUrl).replaceAll(RegExp(r'/$'), '');

  final http.Client _http;
  final String baseUrl;

  Uri _uri(String path, [Map<String, String>? query]) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$baseUrl$normalized').replace(queryParameters: query);
  }

  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    final response = await _http.get(_uri(path, query), headers: _headers());
    return _decode(response);
  }

  Future<dynamic> post(String path, {Object? body}) async {
    final response = await _http.post(
      _uri(path),
      headers: _headers(),
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(response);
  }

  Future<dynamic> patch(String path, {Object? body}) async {
    final response = await _http.patch(
      _uri(path),
      headers: _headers(),
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(response);
  }

  Future<dynamic> put(String path, {Object? body}) async {
    final response = await _http.put(
      _uri(path),
      headers: _headers(),
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(response);
  }

  Future<void> delete(String path) async {
    final response = await _http.delete(_uri(path), headers: _headers());
    _decode(response, allowEmpty: true);
  }

  Map<String, String> _headers() => {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    // Always fetch live data (a cached list would resurrect deleted items).
    'Cache-Control': 'no-cache',
  };

  dynamic _decode(http.Response response, {bool allowEmpty = false}) {
    final status = response.statusCode;
    final body = response.body;
    if (status >= 200 && status < 300) {
      if (body.isEmpty) {
        if (allowEmpty) return null;
        return null;
      }
      return jsonDecode(body);
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
