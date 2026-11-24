import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import '../hardening/client_ip.dart';
import '../hardening/logging.dart';
import '../hardening/rate_limit.dart';
import 'json_helpers.dart';

/// Temporary remote log for the iOS keyboard investigation.
/// Unauthenticated, rate-limited, size-capped. No database.
const kbdebugMaxBody = 16384;
const kbdebugMaxEntries = 20;
const kbdebugMaxFileBytes = 200000;

final _store = KbDebugStore(File('/tmp/budget-kbdebug.jsonl'));
final _limiter = RateLimiter(8);

String get kbdebugLogPath => _store.file.path;

Handler kbdebugHandler({Log? log, KbDebugStore? store, RateLimiter? limiter}) {
  final logs = log ?? Log();
  final s = store ?? _store;
  final limit = limiter ?? _limiter;
  return (Request request) async {
    final ip = clientIpOf(request);
    final wait = limit.take('ip:$ip');
    if (wait != null) {
      return jsonError(429, 'too many requests', details: {'retryAfter': wait})
          .change(headers: {'retry-after': '$wait'});
    }
    if (request.method == 'GET') {
      return jsonOk({'ok': true, 'path': s.file.path, 'entries': s.read()});
    }
    if (request.method != 'POST') {
      return jsonError(405, 'method not allowed');
    }
    final raw = await request.readAsString();
    if (raw.length > kbdebugMaxBody) {
      return jsonError(413, 'payload too large',
          details: {'maxBytes': kbdebugMaxBody});
    }
    Object? decoded;
    try {
      decoded = raw.trim().isEmpty ? <String, dynamic>{} : jsonDecode(raw);
    } on FormatException {
      return jsonError(400, 'invalid JSON');
    }
    if (decoded is! Map) {
      return jsonError(400, 'JSON body must be an object');
    }
    final entry = <String, dynamic>{
      'recv': DateTime.now().toUtc().toIso8601String(),
      'ip': ip,
      ...Map<String, dynamic>.from(decoded),
    };
    s.add(entry);
    logs.info('kbdebug', {
      'ip': ip,
      'build': entry['build'],
      'kb': entry['kb'],
      'log': entry['log'],
    });
    return jsonOk({'ok': true});
  };
}

class KbDebugStore {
  KbDebugStore(this.file);

  final File file;
  final List<Map<String, dynamic>> _mem = [];

  List<Map<String, dynamic>> read() {
    if (_mem.isNotEmpty) return List.unmodifiable(_mem);
    if (!file.existsSync()) return const [];
    try {
      final lines = file.readAsLinesSync();
      final out = <Map<String, dynamic>>[];
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        final v = jsonDecode(line);
        if (v is Map<String, dynamic>) out.add(v);
      }
      return out.length > kbdebugMaxEntries
          ? out.sublist(out.length - kbdebugMaxEntries)
          : out;
    } catch (_) {
      return const [];
    }
  }

  void add(Map<String, dynamic> entry) {
    _mem.add(entry);
    if (_mem.length > kbdebugMaxEntries) {
      _mem.removeRange(0, _mem.length - kbdebugMaxEntries);
    }
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        '${_mem.map(jsonEncode).join('\n')}\n',
        flush: true,
      );
      if (file.lengthSync() > kbdebugMaxFileBytes) {
        file.writeAsStringSync(
          '${_mem.map(jsonEncode).join('\n')}\n',
          flush: true,
        );
      }
    } catch (_) {
      // In-memory copy is enough if the filesystem is read-only.
    }
  }

  void clear() {
    _mem.clear();
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}
