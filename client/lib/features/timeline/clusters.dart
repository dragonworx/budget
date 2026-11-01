// Group markers at coarse zoom (spec 006 §5): occurrences binned by calendar
// period on a global ladder, with exact integer-cent totals per bin.
import 'dart:math' as math;

import 'package:intl/intl.dart';

import '../../data/models.dart';
import '../../widgets/money_text.dart';
import 'lod.dart';

/// Calendar periods for group bins, smallest first.
enum BinPeriod {
  day(1),
  week(7),
  month(30.436875),
  quarter(91.310625),
  year(365.2425);

  const BinPeriod(this.averageDays);
  final double averageDays;
}

/// A bin must average at least this many logical px.
const double groupBinMinPx = 6;

/// The smallest period whose average width is ≥ [groupBinMinPx].
BinPeriod binPeriodFor(double dayPx) {
  for (final p in BinPeriod.values) {
    if (p.averageDays * dayPx >= groupBinMinPx) return p;
  }
  return BinPeriod.year;
}

/// Global ordinal of the [p] period holding [date] (local calendar date).
int binKeyOf(BinPeriod p, DateTime date) => switch (p) {
  BinPeriod.day => dayIndexOf(date),
  // 1970-01-01 was a Thursday: +3 puts ISO weeks (Mon–Sun) on the grid.
  BinPeriod.week => floorDiv(dayIndexOf(date) + 3, 7),
  BinPeriod.month => (date.year - 1970) * 12 + date.month - 1,
  BinPeriod.quarter => (date.year - 1970) * 4 + (date.month - 1) ~/ 3,
  BinPeriod.year => date.year - 1970,
};

DateTime _dayAt(int dayIndex) => DateTime(1970, 1, 1 + dayIndex);

/// First day of bin [key].
DateTime binStart(BinPeriod p, int key) => switch (p) {
  BinPeriod.day => _dayAt(key),
  BinPeriod.week => _dayAt(key * 7 - 3),
  BinPeriod.month => DateTime(1970 + floorDiv(key, 12), key % 12 + 1),
  BinPeriod.quarter => DateTime(1970 + floorDiv(key, 4), (key % 4) * 3 + 1),
  BinPeriod.year => DateTime(1970 + key),
};

/// The day after bin [key] ends.
DateTime binEnd(BinPeriod p, int key) => binStart(p, key + 1);

/// The period as the user names it: "12 Mar 2031", "10 – 16 Mar 2031",
/// "Mar 2031", "1 Jan – 31 Mar 2031", "2031".
String binLabel(BinPeriod p, int key) {
  final s = binStart(p, key);
  final last = binEnd(p, key).subtract(const Duration(hours: 12));
  final lastDay = DateTime(last.year, last.month, last.day);
  final dmy = DateFormat('d MMM y');
  switch (p) {
    case BinPeriod.day:
      return dmy.format(s);
    case BinPeriod.month:
      return DateFormat('MMM y').format(s);
    case BinPeriod.week:
    case BinPeriod.year:
    case BinPeriod.quarter:
      final head = s.year == lastDay.year
          ? DateFormat('d MMM').format(s)
          : dmy.format(s);
      return '$head – ${dmy.format(lastDay)}';
  }
}

/// One event's share of a bin.
typedef EventLine = ({String eventId, int count, int cents});

/// Exact totals for one calendar period (cents; debit kept positive).
class GroupBin {
  GroupBin._(this.period, this.key);
  final BinPeriod period;
  final int key;

  /// Range into [GroupClusters.order] (occurrences by date).
  int from = 0, to = 0;

  /// Counted (not skipped) event occurrences, excluding loan interest and
  /// transfers netted between combined streams.
  int count = 0;
  int creditCents = 0, debitCents = 0;
  int skipped = 0;

  /// Loan interest / derived charges: their own channel, never in [net].
  int interestCount = 0, interestCents = 0;

  /// Combined view: transfers between included streams (net out).
  int nettedCount = 0;
  int largestAbsCents = 0;

  /// Top 3 events by |sum| (stable: first seen), then the remainder.
  List<EventLine> top = const [];
  int remainderCount = 0, remainderCents = 0;

  /// Days (dayIndex) of the first and last occurrence in the bin.
  int firstDay = 0, lastDay = 0;

  /// Every counted occurrence belongs to this one event.
  String? singleEventId;

  /// Every occurrence in the bin, skipped and interest included.
  int get total => to - from;
  int get netCents => creditCents - debitCents;

  /// A lone occurrence: drawn as today's single-event dot.
  bool get single => total == 1;

  DateTime get start => binStart(period, key);
  DateTime get end => binEnd(period, key);
}

/// One ladder level: the bins that hold occurrences, by key.
class GroupLevel {
  GroupLevel._(this.period, this.bins);
  final BinPeriod period;
  final List<GroupBin> bins;

  /// First bin whose key is ≥ [key].
  int lowerBound(int key) {
    var lo = 0, hi = bins.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (bins[mid].key < key) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Bins overlapping [from, to) (local dates).
  (int, int) range(DateTime from, DateTime to) => (
    lowerBound(binKeyOf(period, from)),
    lowerBound(binKeyOf(period, to.subtract(const Duration(hours: 12))) + 1),
  );
}

bool isInterest(Occurrence o) => o.component == 'interest' || o.derived;

/// Group bins for one occurrence list, every level built once and cached.
class GroupClusters {
  GroupClusters._(this.occurrences) {
    final n = occurrences.length;
    final idx = List<int>.generate(n, (i) => i);
    final days = List<int>.generate(n, (i) => dayIndexOf(occurrences[i].date));
    // Stable: same-day occurrences keep series order.
    idx.sort((a, b) {
      final c = days[a].compareTo(days[b]);
      return c != 0 ? c : a.compareTo(b);
    });
    order = idx;
    dayOf = [for (final i in idx) days[i]];
    cents = [for (final i in idx) decimalCents(occurrences[i].signedDelta)];
  }

  final List<Occurrence> occurrences;

  /// Occurrence indices by date, their days and exact cents (same order).
  late final List<int> order;
  late final List<int> dayOf;
  late final List<int> cents;
  final _levels = <BinPeriod, GroupLevel>{};

  Occurrence at(int k) => occurrences[order[k]];

  GroupLevel level(BinPeriod p) => _levels[p] ??= _build(p);

  /// Every level, e.g. at load so no gesture frame builds one.
  void prewarm() {
    for (final p in BinPeriod.values) {
      level(p);
    }
  }

  GroupLevel _build(BinPeriod p) {
    debugGroupBuilds++;
    final bins = <GroupBin>[];
    final n = order.length;
    var k = 0;
    while (k < n) {
      final key = p == BinPeriod.day ? dayOf[k] : binKeyOf(p, at(k).date);
      final bin = GroupBin._(p, key)..from = k;
      final events = <String, (int, int)>{};
      bin.firstDay = dayOf[k];
      while (k < n &&
          (p == BinPeriod.day ? dayOf[k] : binKeyOf(p, at(k).date)) == key) {
        final o = at(k);
        final c = cents[k];
        bin.lastDay = dayOf[k];
        if (o.skipped) {
          bin.skipped++;
        } else if (isInterest(o)) {
          bin.interestCount++;
          bin.interestCents += c;
        } else if (o.netted) {
          bin.nettedCount++;
        } else {
          bin.count++;
          if (c >= 0) {
            bin.creditCents += c;
          } else {
            bin.debitCents -= c;
          }
          if (c.abs() > bin.largestAbsCents) bin.largestAbsCents = c.abs();
          final e = events[o.eventId];
          events[o.eventId] = e == null ? (1, c) : (e.$1 + 1, e.$2 + c);
        }
        k++;
      }
      bin.to = k;
      final lines = [
        for (final MapEntry(:key, :value) in events.entries)
          (eventId: key, count: value.$1, cents: value.$2),
      ];
      if (lines.length == 1) bin.singleEventId = lines.first.eventId;
      // Stable sort: ties keep first-seen order.
      final ranked = mergeSortedBy(lines, (l) => -l.cents.abs());
      bin.top = List.unmodifiable(ranked.take(3));
      for (final l in ranked.skip(3)) {
        bin.remainderCount += l.count;
        bin.remainderCents += l.cents;
      }
      bins.add(bin);
    }
    return GroupLevel._(p, List.unmodifiable(bins));
  }

  /// Every event line for [bin] (the breakdown beyond the top 3), by |sum|.
  List<EventLine> linesOf(GroupBin bin) {
    final events = <String, (int, int)>{};
    for (var k = bin.from; k < bin.to; k++) {
      final o = at(k);
      if (o.skipped || isInterest(o) || o.netted) continue;
      final e = events[o.eventId];
      events[o.eventId] = e == null
          ? (1, cents[k])
          : (e.$1 + 1, e.$2 + cents[k]);
    }
    return mergeSortedBy([
      for (final MapEntry(:key, :value) in events.entries)
        (eventId: key, count: value.$1, cents: value.$2),
    ], (l) => -l.cents.abs());
  }
}

/// Stable sort of [items] by an int key.
List<T> mergeSortedBy<T>(List<T> items, int Function(T) keyOf) {
  final keyed = [for (final (i, t) in items.indexed) (keyOf(t), i, t)];
  keyed.sort((a, b) {
    final c = a.$1.compareTo(b.$1);
    return c != 0 ? c : a.$2.compareTo(b.$2);
  });
  return [for (final k in keyed) k.$3];
}

final _clusters = Expando<GroupClusters>('groupClusters');

/// Cached per occurrence-list identity (like [pointIndexOf]).
GroupClusters groupClustersOf(List<Occurrence> occurrences) =>
    _clusters[occurrences] ??= GroupClusters._(occurrences);

/// Test hook: ladder levels built.
int debugGroupBuilds = 0;

// --- Label text -----------------------------------------------------------

final _grouped = NumberFormat.decimalPattern();

/// Exact count with thousands separators: "1,234".
String groupCountText(int n) => _grouped.format(n);

/// "$1,234.56" (exact) or, from a million, "~$1.24M" / "$1.2M" (`~` only
/// when the shown figure is not the exact cents).
String _absMoney(int absCents) {
  if (absCents < 100000000) {
    return NumberFormat.currency(
      symbol: moneySymbol,
      decimalDigits: 2,
    ).format(absCents / 100);
  }
  final unit = absCents >= 100000000000 ? 1e11 : 1e8; // $1B / $1M in cents
  final suffix = unit == 1e11 ? 'B' : 'M';
  final shown = (absCents / unit * 100).round(); // hundredths of a unit
  final exact = shown * (unit ~/ 100) == absCents;
  final whole = shown ~/ 100, frac = shown % 100;
  final digits = frac == 0
      ? ''
      : frac % 10 == 0
      ? '.${frac ~/ 10}'
      : '.${frac.toString().padLeft(2, '0')}';
  return '${exact ? '' : '~'}$moneySymbol${_grouped.format(whole)}$digits$suffix';
}

/// Signed: "−$1,234.56", "+$20.00", "~−$1.24M".
String groupMoneyText(int cents) {
  if (cents == 0) return '${moneySymbol}0.00';
  final abs = _absMoney(cents.abs());
  final approx = abs.startsWith('~');
  final body = approx ? abs.substring(1) : abs;
  return '${approx ? '~' : ''}${cents < 0 ? '−' : '+'}$body';
}

/// The label's lines: "net −$1,234.56", then "23 items" (mixed events) or
/// "Rent ×12" (one event), then "interest −$412.08" when the period has
/// loan interest. [nameOf] maps an event id to its name.
({String amount, List<String> lines}) groupLabelText(
  GroupBin bin,
  String Function(String eventId) nameOf,
) {
  final single = bin.singleEventId;
  return (
    amount: 'net ${groupMoneyText(bin.netCents)}',
    lines: [
      if (single != null && bin.count > 0)
        '${nameOf(single)} ×${groupCountText(bin.count)}'
      else
        '${groupCountText(bin.count)} ${bin.count == 1 ? 'item' : 'items'}',
      if (bin.interestCount > 0)
        'interest ${groupMoneyText(bin.interestCents)}',
    ],
  );
}

/// The [k] bins to label, ranked by |net| (stable: earlier day, then event
/// order), labels shown last frame first so a pan never trades them.
List<GroupBin> labelBudget(
  List<GroupBin> candidates,
  int k, {
  Set<int> previous = const {},
}) {
  if (k <= 0) return const [];
  final ranked = mergeSortedBy(candidates, (b) => -b.netCents.abs());
  return [
    ...ranked.where((b) => previous.contains(b.key)),
    ...ranked.where((b) => !previous.contains(b.key)),
  ].take(k).toList();
}

/// The bins to label while panning: one per tile of [tileDays] on a global
/// grid (by the glyph's day), the largest |net| in it (ties: the earlier).
/// The choice never depends on where the view starts, so a pan never
/// trades labels; with tiles of visibleDays / K a view holds about K.
Set<int> tileWinners(List<(GroupBin, double)> bins, double tileDays) {
  final best = <int, GroupBin>{};
  for (final (b, day) in bins) {
    final t = (day / tileDays).floor();
    final cur = best[t];
    if (cur == null || b.netCents.abs() > cur.netCents.abs()) best[t] = b;
  }
  return {for (final b in best.values) b.key};
}

/// K = floor(plot width / 120).
int groupLabelBudget(double plotWidth) => math.max(0, plotWidth ~/ 120);
