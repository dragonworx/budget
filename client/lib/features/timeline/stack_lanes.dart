import 'dart:math' as math;
import 'dart:ui';

import '../../data/models.dart';
import 'chart_geometry.dart' show DayGroup, addCalendarDays;
import 'occurrence_dates.dart';
import 'zoom_level.dart';

/// Stacked lanes: the balance line drawn as one ribbon made of a thin lane
/// per transaction.
///
/// * A lane exists for a transaction over the days it is *active*: from its
///   first occurrence (its start date) to its last (the end date, or the
///   date of its final counted occurrence), or for ever when it never ends.
///   A once-off is a lane one day wide.
/// * The lanes active on a day are stacked in the Transactions list's order
///   (first = top) with no gaps, and the stack's centre sits on the balance
///   line, so the whole ribbon rises and falls with the balance.
/// * Excluded (Include in balance off) transactions have no occurrences and
///   no lane.
class StackLane {
  const StackLane({
    required this.id,
    required this.name,
    required this.credit,
    this.amount = 0,
    required this.colorIndex,
    required this.start,
    required this.end,
    this.poolId,
  });

  final String id;
  final String name;

  /// Money in (vs out).
  final bool credit;

  /// The transaction's own amount, signed (money out is negative); shown
  /// after its name inside the lane.
  final double amount;
  final int colorIndex;

  /// First day (inclusive).
  final DateTime start;

  /// Last day (inclusive); null: never ends.
  final DateTime? end;

  /// Combined view: the other pool it belongs to (null: the viewed pool).
  final String? poolId;

  bool activeOn(DateTime day) =>
      !day.isBefore(start) && (end == null || !day.isAfter(end!));

  /// The name shown inside the lane (its amount follows, coloured).
  String get label => name;
}

class LaneSet {
  LaneSet(this.lanes)
    : _index = {for (final (i, l) in lanes.indexed) l.id: i},
      maxActive = _maxConcurrent(lanes);

  static final LaneSet empty = LaneSet(const []);

  /// In stack order (the Transactions list's order; in a combined view the
  /// viewed pool's lanes, then each other pool's, in the pools' order).
  final List<StackLane> lanes;
  final Map<String, int> _index;

  /// The most lanes active on any one day: sizes the lane thickness, so it
  /// stays the same however the view is panned.
  final int maxActive;

  bool get isEmpty => lanes.isEmpty;

  int? indexOf(String id) => _index[id];

  /// Indices (ascending = top to bottom) of the lanes active on [day].
  List<int> activeOn(DateTime day) => [
    for (var i = 0; i < lanes.length; i++)
      if (lanes[i].activeOn(day)) i,
  ];

  /// Where lane [id] sits on [day]: (slot, lanes active that day), or null
  /// when it has no lane that day.
  (int, int)? slotOn(String id, DateTime day) {
    final target = _index[id];
    if (target == null || !lanes[target].activeOn(day)) return null;
    var slot = 0, n = 0;
    for (var i = 0; i < lanes.length; i++) {
      if (!lanes[i].activeOn(day)) continue;
      if (i < target) slot++;
      n++;
    }
    return (slot, n);
  }

  static int _maxConcurrent(List<StackLane> lanes) {
    if (lanes.isEmpty) return 0;
    // +1 at a start, -1 the day after an end: sweep the sorted events.
    final events = <(DateTime, int)>[];
    for (final l in lanes) {
      events.add((l.start, 1));
      if (l.end != null) events.add((addCalendarDays(l.end!, 1), -1));
    }
    events.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$2.compareTo(b.$2); // ends before starts
    });
    var n = 0, best = 0;
    for (final (_, d) in events) {
      n += d;
      if (n > best) best = n;
    }
    return best;
  }
}

/// The lanes for [transactions] (the viewed pool, by id) and [others]
/// (combined view, by id), in [order] (viewed pool: the Transactions list's
/// order), then anything [order] misses, the viewed pool's first. Names are
/// the transaction's own, trimmed.
LaneSet buildLaneSet({
  required List<String> order,
  required Map<String, Transaction> transactions,
  Map<String, Transaction> others = const {},
  List<String> otherOrder = const [],
}) {
  final seen = <String>{};
  final lanes = <StackLane>[];
  void add(String id, Transaction? t, {required bool other}) {
    if (t == null || !t.enabled || !seen.add(id)) return;
    final span = _span(t);
    final name = t.name.trim();
    lanes.add(
      StackLane(
        id: id,
        name: name.isEmpty ? 'Transaction' : name,
        credit: t.direction == TransactionDirection.credit,
        amount: t.signedAmount.toDouble(),
        colorIndex: lanes.length,
        start: span.$1,
        end: span.$2,
        poolId: other ? t.poolId : null,
      ),
    );
  }

  for (final id in order) {
    add(id, transactions[id], other: false);
  }
  for (final e in transactions.entries) {
    add(e.key, e.value, other: false);
  }
  for (final id in otherOrder) {
    add(id, others[id], other: true);
  }
  for (final e in others.entries) {
    add(e.key, e.value, other: true);
  }
  return LaneSet(lanes);
}

(DateTime, DateTime?) _span(Transaction t) {
  final start = dateOnly(t.startDate);
  if (t.recurrenceMode == RecurrenceMode.once) return (start, start);
  switch (t.endMode) {
    case EndMode.never:
      return (start, null);
    case EndMode.untilDate:
      final end = t.endDate == null ? null : dateOnly(t.endDate!);
      return (start, end == null || end.isBefore(start) ? start : end);
    case EndMode.count:
      final n = (t.occurrenceCount ?? 1).clamp(1, 5000);
      final dates = estimateOccurrenceDates(t, maxCount: n);
      return (start, dates.isEmpty ? start : dates.last);
  }
}

/// A lane's colour: a fixed palette of mid-dark tones (white text reads on
/// all of them), chosen by position in the stack so neighbouring lanes
/// differ. None is the balance line's teal or the debit red; money in / out
/// is shown by the "+" / "−" in the label and by the dot.
const List<Color> laneColors = [
  Color(0xFF3D6FD8), // blue
  Color(0xFF9250C8), // purple
  Color(0xFFB36A12), // amber
  Color(0xFF2B8AA8), // sea blue
  Color(0xFFB8488E), // magenta
  Color(0xFF5B7A2A), // olive
  Color(0xFF6A62D6), // indigo
  Color(0xFFA0602C), // copper
  Color(0xFF3C8A6E), // pine
  Color(0xFF8E5A9E), // plum
  Color(0xFF4A78A8), // steel
  Color(0xFF9C7A1E), // ochre
];

Color laneColor(int index) => laneColors[index % laneColors.length];

/// Thickness of one lane. The stack must stay close to the dollars it
/// stands for, so the tallest stack gets about a quarter of the plot at full
/// (14-16px) lanes; past that lanes keep the text height while the stack
/// fits in about a third, then thin out (no text; hover / tap for details),
/// never below [minLaneHeight].
double laneThickness({
  required int maxActive,
  required double plotHeight,
  required bool phone,
}) {
  if (maxActive <= 0) return 0;
  final cap = phone ? 14.0 : 16.0;
  final share = plotHeight * (phone ? 0.22 : 0.25);
  final textShare = plotHeight * (phone ? 0.30 : 0.32);
  final h = (share / maxActive).clamp(minLaneHeight, cap).toDouble();
  if (h < laneTextMinHeight && maxActive * laneTextMinHeight <= textShare) {
    return laneTextMinHeight;
  }
  return h;
}

const double minLaneHeight = 3.0;

/// Lane text needs this much lane height.
const double laneTextMinHeight = 11.5;

/// One stretch of the ribbon between two changes (a balance step, a lane
/// starting or ending): the balance and the lanes stacked over it.
class StackPlateau {
  const StackPlateau({
    required this.day,
    required this.x0,
    required this.x1,
    required this.balance,
    required this.active,
  });

  final DateTime day;
  final double x0;
  final double x1;
  final double balance;

  /// Lane indices, top to bottom.
  final List<int> active;
}

/// The ribbon between [drawStart] and [drawEnd] (days): a plateau per run
/// of days where neither the balance nor the active lanes change. [samples]
/// are the balance points from the carry (on or before [drawStart]) on, in
/// date order. A balance changes at the left edge of its day.
List<StackPlateau> stackPlateaus({
  required LaneSet lanes,
  required List<BalancePoint> samples,
  required DateTime drawStart,
  required DateTime drawEnd,
  required double Function(DateTime) xOf,
  required double minX,
  required double maxX,
}) {
  if (!drawStart.isBefore(drawEnd) || samples.isEmpty) return const [];
  final cuts = <DateTime>{drawStart};
  void cut(DateTime d) {
    if (d.isAfter(drawStart) && d.isBefore(drawEnd)) cuts.add(d);
  }

  for (final s in samples) {
    cut(dateOnly(s.date));
  }
  for (final l in lanes.lanes) {
    cut(l.start);
    if (l.end != null) cut(addCalendarDays(l.end!, 1));
  }
  final days = cuts.toList()..sort();
  final out = <StackPlateau>[];
  var at = 0;
  double? balance;
  for (var i = 0; i < days.length; i++) {
    final d = days[i];
    while (at < samples.length && !dateOnly(samples[at].date).isAfter(d)) {
      balance = samples[at].closingBalance.toDouble();
      at++;
    }
    if (balance == null) continue;
    final next = i + 1 < days.length ? days[i + 1] : drawEnd;
    final x0 = xOf(d).clamp(minX, maxX).toDouble();
    final x1 = xOf(next).clamp(minX, maxX).toDouble();
    out.add(
      StackPlateau(
        day: d,
        x0: x0,
        x1: x1,
        balance: balance,
        active: lanes.activeOn(d),
      ),
    );
  }
  return out;
}

/// Top of lane [slot] of [n] stacked and centred on [balanceY].
double laneTop(double balanceY, int slot, int n, double thickness) =>
    balanceY - n * thickness / 2 + slot * thickness;

/// Slanted run, in px, where the ribbon moves from one level to the next
/// (just left of the new level's left edge, so the new level starts exactly
/// on its day's left edge, where the dots sit).
double stackConnectorWidth(double plateauPx) => math.min(3.0, plateauPx / 2);

/// One transaction's dot on a day: where it sits in the ribbon.
class LaneDot {
  const LaneDot({required this.txId, required this.y, required this.own});

  /// The transaction (null: occurrences with no lane, drawn together on the
  /// ribbon's centre).
  final String? txId;

  /// Dot centre, vertically (x is the day's left edge).
  final double y;

  /// That transaction's occurrences on the day (empty: the transaction has
  /// a lane here but does not occur on this step).
  final List<Occurrence> own;

  /// A lane's dot at a step its transaction does not occur on.
  bool get idle => own.isEmpty && txId != null;
}

/// The dots of day [group]: one in EVERY lane active that day (vertically
/// centred in it), in lane order from the top. A lane whose transaction
/// occurs that day gets its occurrences; the others get an [LaneDot.idle]
/// dot. Any occurrence with no lane that day gets its own dot on the balance.
/// [balanceY] is the ribbon's centre (the day's closing balance), [thickness]
/// a lane's. Also returns the stack's top and bottom ([stackTop] /
/// [stackBottom], both [balanceY] when no lane is active).
({List<LaneDot> dots, double stackTop, double stackBottom}) laneDotsForDay({
  required LaneSet lanes,
  required DayGroup group,
  required double balanceY,
  required double thickness,
}) {
  final active = lanes.activeOn(group.day);
  final n = active.length;
  final byTx = <String, List<Occurrence>>{};
  for (final o in group.all) {
    (byTx[o.transactionId] ??= []).add(o);
  }
  final placed = <(int, LaneDot)>[];
  final orphans = <MapEntry<String, List<Occurrence>>>[];
  for (final e in byTx.entries) {
    final li = lanes.indexOf(e.key);
    final slot = li == null ? -1 : active.indexOf(li);
    if (slot < 0) {
      orphans.add(e);
      continue;
    }
    placed.add((
      slot,
      LaneDot(
        txId: e.key,
        y: laneTop(balanceY, slot, n, thickness) + thickness / 2,
        own: e.value,
      ),
    ));
  }
  final taken = {for (final (slot, _) in placed) slot};
  for (var slot = 0; slot < n; slot++) {
    if (taken.contains(slot)) continue;
    placed.add((
      slot,
      LaneDot(
        txId: lanes.lanes[active[slot]].id,
        y: laneTop(balanceY, slot, n, thickness) + thickness / 2,
        own: const [],
      ),
    ));
  }
  placed.sort((a, b) => a.$1.compareTo(b.$1));
  return (
    dots: [
      for (final (_, d) in placed) d,
      // A transaction with no lane that day: its own dot on the balance (a
      // few of them fan out around it).
      for (final (i, e) in orphans.indexed)
        LaneDot(
          txId: null,
          y: balanceY + (i - (orphans.length - 1) / 2) * 9,
          own: e.value,
        ),
    ],
    stackTop: n == 0 ? balanceY : laneTop(balanceY, 0, n, thickness),
    stackBottom: n == 0 ? balanceY : laneTop(balanceY, n, n, thickness),
  );
}

/// Lane dots are drawn (and tappable) from this many pixels per day: past
/// that, a heavy pool would put thousands on screen.
const double laneDotsMinDayPx = 1.5;

/// A lane dot's radius: the day-width radius, no bigger than its lane.
double laneDotRadius(double base, double thickness) =>
    math.min(base, math.max(1.6, thickness / 2 + 0.6));
