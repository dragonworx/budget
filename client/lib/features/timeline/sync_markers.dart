import 'package:decimal/decimal.dart';

import '../../data/models.dart';

/// Spec 015: syncs on the chart are exact markers — a teal ring with a tick on
/// the balance line at the day's close, never merged into a group nor
/// hidden at any zoom. One [SyncMark] per day with a sync.
class SyncMark {
  SyncMark({
    required this.day,
    required this.dayIndex,
    required this.winner,
    required this.count,
  });

  final DateTime day;

  /// Days since 1970-01-01 (for the binary search).
  final int dayIndex;

  /// The sync that applies that day (the last in the list order).
  final Occurrence winner;

  /// Syncs that day (winner included).
  final int count;

  Decimal get balance => winner.syncBalance ?? Decimal.zero;
  Decimal? get drift => winner.drift;
}

final _memo = Expando<List<SyncMark>>('syncMarks');

int _dayIndex(DateTime d) =>
    DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 86400000;

/// The day marks of [syncs] (a series' sync occurrences), sorted by day;
/// built once per list.
List<SyncMark> syncMarksOf(List<Occurrence> syncs) {
  if (syncs.isEmpty) return const [];
  final cached = _memo[syncs];
  if (cached != null) return cached;
  final byDay = <int, List<Occurrence>>{};
  for (final o in syncs) {
    (byDay[_dayIndex(o.date)] ??= []).add(o);
  }
  final days = byDay.keys.toList()..sort();
  final out = [
    for (final d in days)
      () {
        final list = byDay[d]!;
        final winner = list.lastWhere(
          (o) => !o.superseded,
          orElse: () => list.last,
        );
        return SyncMark(
          day: DateTime(winner.date.year, winner.date.month, winner.date.day),
          dayIndex: d,
          winner: winner,
          count: list.length,
        );
      }(),
  ];
  _memo[syncs] = out;
  return out;
}

/// Index range [from, to) of [marks] with dayIndex in [firstDay, lastDay].
(int, int) syncMarkRange(List<SyncMark> marks, int firstDay, int lastDay) {
  int lower(int day) {
    var lo = 0, hi = marks.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (marks[mid].dayIndex < day) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  return (lower(firstDay), lower(lastDay + 1));
}

/// Marks sharing one pixel column (L1/L2 zoom): drawn as one ring with a
/// "×N" badge. [marks] in day order; [xOf] its x.
List<List<SyncMark>> syncColumns(
  List<SyncMark> marks,
  double Function(SyncMark) xOf,
) {
  final out = <List<SyncMark>>[];
  int? col;
  for (final m in marks) {
    final c = xOf(m).floor();
    if (col == c) {
      out.last.add(m);
    } else {
      out.add([m]);
      col = c;
    }
  }
  return out;
}

/// The day-totals row: "Sync to \$1,234.56 (+\$12.34)".
String syncDayTotalText(String balance, String? drift) =>
    drift == null ? 'Sync to $balance' : 'Sync to $balance ($drift)';
