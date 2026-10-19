import 'dart:convert';
import 'package:postgres/postgres.dart';

import 'package:shelf/shelf.dart';

Response jsonOk(Object? body, {int status = 200}) {
  return Response(
    status,
    body: jsonEncode(body),
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

Response jsonError(int status, String message, {Object? details}) {
  return jsonOk(
    {
      'error': message,
      if (details != null) 'details': details,
    },
    status: status,
  );
}

Future<Map<String, dynamic>> readJsonObject(Request request) async {
  final raw = await request.readAsString();
  if (raw.trim().isEmpty) return <String, dynamic>{};
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('JSON body must be an object');
  }
  return decoded;
}

String requireString(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v is! String || v.trim().isEmpty) {
    throw FormatException('Missing or invalid field: $key');
  }
  return v;
}

String? optionalString(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is! String) throw FormatException('Invalid field: $key');
  return v;
}

bool? optionalBool(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is! bool) throw FormatException('Invalid field: $key');
  return v;
}

int? optionalInt(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.parse(v);
  throw FormatException('Invalid field: $key');
}

/// The transaction runner behind a DB handle (a `Pool` in the server, a
/// `Connection` in tests; both implement `Session` and `SessionExecutor`).
SessionExecutor txOf(Session db) => db as SessionExecutor;
