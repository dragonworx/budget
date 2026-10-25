import 'dart:convert';

import 'package:shelf/shelf.dart';

// DEPRECATED compatibility aliases from before the Pools/Transactions ->
// Streams/Events rename (migration 020). A browser tab still running an
// older client build keeps calling `/api/pools...` and `/api/transactions...`
// with the old JSON field names until it reloads. These requests are
// rewritten to the new routes, request JSON keys are renamed old -> new and
// response JSON keys new -> old, so the old build keeps working. Remove once
// no old builds are left in the wild (a few days after the rename shipped).

/// `poolId` -> `streamId`, `transactions` -> `events`, `pool_id` ->
/// `stream_id`, ... (any key containing the old words).
String legacyKeyToNew(String k) => k
    .replaceAll('Transaction', 'Event')
    .replaceAll('transaction', 'event')
    .replaceAll('Pool', 'Stream')
    .replaceAll('pool', 'stream');

/// The inverse of [legacyKeyToNew] for response keys.
String newKeyToLegacy(String k) => k
    .replaceAll('Event', 'Transaction')
    .replaceAll('event', 'transaction')
    .replaceAll('Stream', 'Pool')
    .replaceAll('stream', 'pool');

Object? renameKeys(Object? v, String Function(String) f) {
  if (v is Map) {
    return {
      for (final e in v.entries) f('${e.key}'): renameKeys(e.value, f),
    };
  }
  if (v is List) return [for (final x in v) renameKeys(x, f)];
  return v;
}

/// New path for a legacy `/api/...` path, or null if it is not legacy.
String? legacyPathToNew(String path) {
  List<String>? rest;
  String? base;
  if (path == '/api/pools' || path.startsWith('/api/pools/')) {
    base = '/api/streams';
    rest = path.substring('/api/pools'.length).split('/');
  } else if (path == '/api/transactions' ||
      path.startsWith('/api/transactions/')) {
    base = '/api/events';
    rest = path.substring('/api/transactions'.length).split('/');
  }
  if (base == null) return null;
  final mapped = [
    for (final s in rest!)
      switch (s) {
        'transactions' => 'events',
        'reorder-transactions' => 'reorder-events',
        _ => s,
      }
  ];
  return base + mapped.join('/');
}

bool _isJson(String? contentType) =>
    contentType != null && contentType.toLowerCase().contains('json');

Middleware legacyApiAliases() {
  return (Handler inner) {
    return (Request request) async {
      final oldPath = '/${request.url.path}';
      final newPath = legacyPathToNew(oldPath);
      if (newPath == null) return inner(request);
      final uri = request.requestedUri;
      final newUri = uri.replace(
          path: request.handlerPath.replaceAll(RegExp(r'/$'), '') + newPath,
          query: uri.hasQuery ? uri.query : null);
      Object? body;
      final raw = await request.readAsString();
      if (raw.isNotEmpty && _isJson(request.headers['content-type'])) {
        try {
          body = jsonEncode(renameKeys(jsonDecode(raw), legacyKeyToNew));
        } on FormatException {
          body = raw; // let the route report the bad JSON
        }
      } else {
        body = raw;
      }
      final headers = Map<String, String>.from(request.headers)
        ..remove('content-length')
        ..remove('transfer-encoding');
      final rewritten = Request(
        request.method,
        newUri,
        protocolVersion: request.protocolVersion,
        headers: {...headers, 'x-budgie-legacy-alias': '1'},
        handlerPath: request.handlerPath,
        body: body,
        context: request.context,
      );
      final response = await inner(rewritten);
      final deprecation = {
        'deprecation': 'true',
        'link': '<$newPath>; rel="successor-version"',
      };
      if (!_isJson(response.headers['content-type'])) {
        return response.change(headers: deprecation);
      }
      final text = await response.readAsString();
      Object? out = text;
      if (text.isNotEmpty) {
        try {
          out = jsonEncode(renameKeys(jsonDecode(text), newKeyToLegacy));
        } on FormatException {
          out = text;
        }
      }
      final rh = Map<String, String>.from(response.headers)
        ..remove('content-length');
      return Response(response.statusCode,
          body: out,
          headers: {...rh, ...deprecation},
          context: response.context);
    };
  };
}
