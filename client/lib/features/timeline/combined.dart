import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../boot/page_stub.dart'
    if (dart.library.js_interop) '../../boot/page_web.dart'
    as page;
import '../../data/models.dart';
import '../../theme/app_theme.dart';
import 'zoom_level.dart';

/// Another pool drawn into the current pool's timeline (View menu
/// "Combine with"): its name, tint and whether I may edit it.
class CombinedPool {
  const CombinedPool({
    required this.id,
    required this.name,
    required this.color,
    required this.canEdit,
  });

  final String id;
  final String name;
  final Color color;
  final bool canEdit;

  @override
  bool operator ==(Object other) =>
      other is CombinedPool &&
      other.id == id &&
      other.name == name &&
      other.color == color &&
      other.canEdit == canEdit;

  @override
  int get hashCode => Object.hash(id, name, color, canEdit);
}

/// Tint for the other pool at [index] (in my pools list order, so a pool
/// keeps its colour while others are toggled). Avoids the money-in / out
/// greens and reds, the accent line and the seed violet.
Color combinedPoolColor(int index) =>
    AppTheme.poolColors[index % AppTheme.poolColors.length];

/// One included pool's loaded data.
class CombinedPart {
  const CombinedPart({
    required this.poolId,
    required this.seedDate,
    required this.series,
    required this.transactions,
  });

  final String poolId;
  final DateTime seedDate;
  final BalanceSeries series;
  final List<Transaction> transactions;
}

/// The current pool's series with [others] folded in:
///
/// * points: per day, the sum of each pool's closing balance. A pool adds
///   nothing before its seed date (the server sends no points there); on
///   later days missing from a series its last closing carries forward.
/// * occurrences: the current pool's as they are, then the other pools',
///   tagged with their pool id. Transfers whose two pools are both included
///   are marked [Occurrence.netted]: the sum already nets them, so they
///   also stay out of the day's money in / out.
BalanceSeries combineSeries(CombinedPart current, List<CombinedPart> others) {
  if (others.isEmpty) return current.series;
  final parts = [current, ...others];
  final included = {for (final p in parts) p.poolId};
  final txById = {
    for (final p in parts)
      for (final t in p.transactions) t.id: t,
  };
  bool netted(Occurrence o) {
    final link = txById[o.transactionId]?.transfer;
    return link != null &&
        link.peerReadable &&
        included.contains(link.peerPoolId);
  }

  final days = <DateTime>{};
  final closes = <Map<DateTime, Decimal>>[];
  for (final p in parts) {
    final m = <DateTime, Decimal>{};
    for (final pt in p.series.points) {
      m[dateOnly(pt.date)] = pt.closingBalance;
    }
    closes.add(m);
    days.addAll(m.keys);
  }
  final sorted = days.toList()..sort();
  final last = List<Decimal?>.filled(parts.length, null);
  final points = <BalancePoint>[];
  for (final d in sorted) {
    var sum = Decimal.zero;
    for (var i = 0; i < parts.length; i++) {
      final v = closes[i][d];
      if (v != null) last[i] = v;
      sum += last[i] ?? Decimal.zero;
    }
    points.add(BalancePoint(date: d, closingBalance: sum));
  }
  return BalanceSeries(
    points: points,
    occurrences: [
      for (final o in current.series.occurrences)
        netted(o) ? o.tagged(netted: true) : o,
      for (final p in others)
        for (final o in p.series.occurrences)
          o.tagged(poolId: p.poolId, netted: netted(o)),
    ],
  );
}

/// Earliest seed among the included pools: where the combined line starts.
DateTime combinedLineStart(CombinedPart current, List<CombinedPart> others) {
  var start = dateOnly(current.seedDate);
  for (final p in others) {
    final s = dateOnly(p.seedDate);
    if (s.isBefore(start)) start = s;
  }
  return start;
}

/// "Combine with" choices, remembered per signed-in user per current pool
/// in this browser (local storage).
class CombineStore {
  const CombineStore();

  static String key(String userId, String poolId) =>
      'budget_combine:$userId:$poolId';

  Set<String> load(String userId, String poolId) {
    final raw = page.localGet(key(userId, poolId));
    if (raw == null || raw.isEmpty) return {};
    try {
      return {for (final v in jsonDecode(raw) as List) v as String};
    } catch (_) {
      return {};
    }
  }

  void save(String userId, String poolId, Set<String> ids) =>
      page.localSet(key(userId, poolId), jsonEncode(ids.toList()..sort()));
}
