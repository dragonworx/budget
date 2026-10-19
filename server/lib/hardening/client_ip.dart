import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

/// An IP or CIDR range (v4 or v6).
class IpRange {
  IpRange._(this._net, this._bits);

  factory IpRange.parse(String s) {
    final parts = s.trim().split('/');
    final addr = InternetAddress(parts[0]);
    final raw = addr.rawAddress;
    final bits = parts.length > 1 ? int.parse(parts[1]) : raw.length * 8;
    return IpRange._(raw, bits);
  }

  final Uint8List _net;
  final int _bits;

  bool contains(String ip) {
    final InternetAddress a;
    try {
      a = InternetAddress(ip);
    } catch (_) {
      return false;
    }
    var raw = a.rawAddress;
    // IPv4-mapped IPv6 (::ffff:a.b.c.d) compares as IPv4.
    if (raw.length == 16 && _net.length == 4 && _isMapped(raw)) {
      raw = raw.sublist(12);
    }
    if (raw.length != _net.length) return false;
    var left = _bits;
    for (var i = 0; i < raw.length && left > 0; i++) {
      final take = left >= 8 ? 8 : left;
      final mask = (0xff << (8 - take)) & 0xff;
      if ((raw[i] & mask) != (_net[i] & mask)) return false;
      left -= take;
    }
    return true;
  }

  static bool _isMapped(Uint8List r) {
    for (var i = 0; i < 10; i++) {
      if (r[i] != 0) return false;
    }
    return r[10] == 0xff && r[11] == 0xff;
  }
}

/// Resolves the real client IP: the socket peer, unless the peer is a
/// trusted proxy, in which case X-Forwarded-For is walked right-to-left,
/// skipping trusted hops; the first untrusted address is the client.
class ClientIpResolver {
  ClientIpResolver(Iterable<String> trusted)
      : _trusted = trusted.map(IpRange.parse).toList();

  final List<IpRange> _trusted;

  bool isTrusted(String ip) => _trusted.any((r) => r.contains(ip));

  String resolve(String? peer, String? xff) {
    final p = peer ?? 'unknown';
    if (xff == null || !isTrusted(p)) return p;
    final hops =
        xff.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    for (final hop in hops.reversed) {
      if (!isTrusted(hop)) return hop;
    }
    return hops.isEmpty ? p : hops.first;
  }

  String forRequest(Request r) {
    final info = r.context['shelf.io.connection_info'];
    final peer = info is HttpConnectionInfo ? info.remoteAddress.address : null;
    return resolve(peer, r.headers['x-forwarded-for']);
  }
}

/// The resolved client IP (set by the logging middleware).
String clientIpOf(Request r) =>
    (r.context['client_ip'] as String?) ?? 'unknown';
