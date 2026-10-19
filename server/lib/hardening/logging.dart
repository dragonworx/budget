import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shelf/shelf.dart';

import 'client_ip.dart';

/// Mutable per-request facts filled in by inner middleware (user id).
class RequestInfo {
  RequestInfo(this.id);
  final String id;
  String? userId;
}

RequestInfo? requestInfoOf(Request r) =>
    r.context['request_info'] as RequestInfo?;

typedef LogSink = void Function(String line);

/// One JSON object per line on stdout.
class Log {
  Log([LogSink? sink]) : _sink = sink ?? ((String l) => stdout.writeln(l));
  final LogSink _sink;

  void write(String level, String msg,
      [Map<String, Object?> fields = const {}]) {
    _sink(jsonEncode({
      'ts': DateTime.now().toUtc().toIso8601String(),
      'level': level,
      'msg': msg,
      ...fields,
    }));
  }

  void info(String msg, [Map<String, Object?> f = const {}]) =>
      write('info', msg, f);
  void warn(String msg, [Map<String, Object?> f = const {}]) =>
      write('warn', msg, f);
  void error(String msg, [Map<String, Object?> f = const {}]) =>
      write('error', msg, f);
}

final _rng = Random.secure();
final _idRe = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

String _newId() => List.generate(
    12, (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

/// Outermost middleware: request id (honours a sane incoming X-Request-Id),
/// client IP, latency, and one structured log line per request. Logs the
/// path only — never the query string, cookies or authorization headers.
Middleware requestLogging(Log log, ClientIpResolver ips,
    {bool Function(Request)? quiet}) {
  return (inner) => (request) async {
        final incoming = request.headers['x-request-id'];
        final id =
            incoming != null && _idRe.hasMatch(incoming) ? incoming : _newId();
        final info = RequestInfo(id);
        final ip = ips.forRequest(request);
        final sw = Stopwatch()..start();
        Response res;
        try {
          res = await inner(
              request.change(context: {'request_info': info, 'client_ip': ip}));
        } catch (e, st) {
          log.error('unhandled', {
            'reqId': id,
            'method': request.method,
            'path': '/${request.url.path}',
            'error': e.toString(),
            'stack': st.toString().split('\n').take(8).join('\n'),
          });
          res = Response.internalServerError(
              body: jsonEncode(
                  {'error': 'internal server error', 'requestId': id}),
              headers: {'content-type': 'application/json; charset=utf-8'});
        }
        if (!(quiet?.call(request) ?? false) || res.statusCode >= 400) {
          log.write(res.statusCode >= 500 ? 'error' : 'info', 'request', {
            'reqId': id,
            'method': request.method,
            'path': '/${request.url.path}',
            'status': res.statusCode,
            'ms': sw.elapsedMicroseconds / 1000,
            'userId': info.userId,
            'ip': ip,
          });
        }
        return res.change(headers: {'x-request-id': id});
      };
}
