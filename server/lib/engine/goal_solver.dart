import 'dart:math' as math;

import 'package:decimal/decimal.dart';

import '../domain/enums.dart';
import '../domain/models.dart';
import 'calendar_math.dart';
import 'occurrence_gen.dart';
import 'solver.dart' show SolverException;

/// Balance-goal variables (§4.5). Exactly one is solved for; the rest are
/// known or take a default (start today, every 1 unit, no one-off, 0%).
enum GoalVar {
  startBalance,
  targetBalance,
  amount,
  interval,
  startDate,
  endDate,
  count,
  oneOff,
  rate;

  String get label => switch (this) {
        GoalVar.startBalance => 'start balance',
        GoalVar.targetBalance => 'target balance',
        GoalVar.amount => 'amount each time',
        GoalVar.interval => 'frequency',
        GoalVar.startDate => 'start date',
        GoalVar.endDate => 'end date',
        GoalVar.count => 'count',
        GoalVar.oneOff => 'one-off amount',
        GoalVar.rate => 'interest rate',
      };

  static GoalVar parse(String v) => GoalVar.values.firstWhere(
        (e) => e.name == v,
        orElse: () => throw FormatException('Invalid solveFor: $v'),
      );
}

/// How the target is judged: the balance on the end date ([onDate]), or
/// never dropping below the target from the start through the end date
/// ([floor]: e.g. "stay above $500").
enum GoalMode {
  onDate,
  floor;

  static GoalMode parse(String v) => GoalMode.values.firstWhere(
        (e) => e.name == v,
        orElse: () => throw FormatException('Invalid mode: $v'),
      );
}

class GoalRequest {
  GoalRequest({
    required this.solveFor,
    this.mode = GoalMode.onDate,
    this.unit = RecurrenceUnit.weeks,
    this.startDate,
    this.endDate,
    this.startBalance,
    this.targetBalance,
    this.amount,
    this.interval,
    this.count,
    this.oneOff,
    this.rate,
  });

  final GoalVar solveFor;
  final GoalMode mode;
  final RecurrenceUnit unit;
  final DateTime? startDate;
  final DateTime? endDate;

  /// Balance at the start of [startDate]; null uses the projected balance.
  final double? startBalance;
  final double? targetBalance;

  /// Signed: + money in each time, − money out.
  final double? amount;
  final int? interval;

  /// Number of payments; null = every interval until the end date.
  final int? count;

  /// Signed one-off on the start date (− = a purchase).
  final double? oneOff;

  /// Annual interest / growth in percent, compounded daily on the balance.
  final double? rate;

  bool has(GoalVar v) => switch (v) {
        GoalVar.startBalance => startBalance != null,
        GoalVar.targetBalance => targetBalance != null,
        GoalVar.amount => amount != null,
        GoalVar.interval => interval != null,
        GoalVar.startDate => startDate != null,
        GoalVar.endDate => endDate != null,
        GoalVar.count => count != null,
        GoalVar.oneOff => oneOff != null,
        GoalVar.rate => rate != null,
      };

  /// Knowns each unknown needs (others default).
  static List<GoalVar> requiredFor(GoalVar v) => switch (v) {
        GoalVar.targetBalance => const [GoalVar.endDate],
        GoalVar.startBalance ||
        GoalVar.amount ||
        GoalVar.oneOff ||
        GoalVar.rate =>
          const [GoalVar.targetBalance, GoalVar.endDate],
        GoalVar.endDate => const [GoalVar.targetBalance],
        GoalVar.count ||
        GoalVar.interval ||
        GoalVar.startDate =>
          const [GoalVar.targetBalance, GoalVar.endDate, GoalVar.amount],
      };
}

/// Daily closing balances of the existing transactions from [from]
/// (inclusive); [opening] is the balance before [from].
class GoalBaseline {
  GoalBaseline({
    required this.from,
    required this.opening,
    required this.closes,
  });

  final DateTime from;
  final double opening;
  final List<double> closes;

  int indexOf(DateTime d) =>
      CalendarMath.daysBetween(from, CalendarMath.dateOnly(d));

  DateTime dateAt(int i) => from.add(Duration(days: i));

  double closeAt(int i) => i < 0
      ? opening
      : (i < closes.length ? closes[i] : (closes.isEmpty ? opening : closes.last));

  double openingAt(int i) => closeAt(i - 1);
  double deltaAt(int i) => closeAt(i) - closeAt(i - 1);
}

class GoalPoint {
  GoalPoint(this.date, this.balance);
  final DateTime date;
  final double balance;
  Map<String, Object?> toJson() =>
      {'date': formatDate(date), 'closingBalance': _m(balance)};
}

class GoalResult {
  GoalResult({
    required this.request,
    this.needs = const [],
    this.values,
    this.points = const [],
    this.projectedStartBalance,
    this.baselineEndBalance,
    this.endBalance,
    this.lowest,
    this.alertDate,
    this.paymentDates = const [],
    this.affordability,
    this.note,
  });

  final GoalRequest request;
  final List<GoalVar> needs;
  final Map<String, Object?>? values;
  final List<GoalPoint> points;
  final double? projectedStartBalance;
  final double? baselineEndBalance;
  final double? endBalance;
  final GoalPoint? lowest;
  final DateTime? alertDate;
  final List<DateTime> paymentDates;
  final Map<String, Object?>? affordability;
  final String? note;

  bool get isComplete => values != null;

  Map<String, Object?> toJson() => {
        'status': isComplete ? 'solved' : 'incomplete',
        'solveFor': request.solveFor.name,
        'mode': request.mode.name,
        if (!isComplete) 'needsMore': needs.length,
        if (!isComplete) 'needsOneOf': [for (final v in needs) v.name],
        if (values != null) 'values': values,
        if (projectedStartBalance != null)
          'projectedStartBalance': _m(projectedStartBalance!),
        if (baselineEndBalance != null)
          'baselineEndBalance': _m(baselineEndBalance!),
        if (endBalance != null) 'endBalance': _m(endBalance!),
        if (lowest != null) 'lowest': lowest!.toJson(),
        'alertDate': alertDate == null ? null : formatDate(alertDate!),
        'paymentCount': paymentDates.length,
        if (paymentDates.isNotEmpty)
          'lastPaymentDate': formatDate(paymentDates.last),
        if (affordability != null) 'affordability': affordability,
        if (note != null) 'note': note,
        'points': [for (final p in points) p.toJson()],
      };
}

String _m(double v) => v.toStringAsFixed(2);

/// Solves one balance-goal unknown against [baseline] (§4.5). The balance
/// from the start date is: opening (or the start balance), then each day
/// interest, the existing transactions' change, the one-off (start day)
/// and plan payments. All amounts enter linearly, so start balance,
/// amount and one-off are solved exactly; dates, count, frequency and
/// rate are found by search.
class GoalSolver {
  GoalSolver({
    required this.baseline,
    required this.threshold,
    required this.today,
    this.horizonDays = 365 * 50,
  });

  final GoalBaseline baseline;
  final double threshold;
  final DateTime today;
  final int horizonDays;

  static const maxCount = 10000;

  GoalResult solve(GoalRequest r) {
    final needs = [
      for (final v in GoalRequest.requiredFor(r.solveFor))
        if (!r.has(v)) v,
    ];
    if (needs.isNotEmpty) return GoalResult(request: r, needs: needs);

    final p = _Params.from(r, today);
    if (r.endDate != null &&
        r.solveFor != GoalVar.startDate &&
        CalendarMath.compare(r.endDate!, p.start) < 0) {
      throw SolverException('end date must be on or after the start date');
    }
    if ((p.interval) < 1) {
      throw SolverException('frequency interval must be at least 1');
    }
    if (p.count != null && (p.count! < 0 || p.count! > maxCount)) {
      throw SolverException('count must be 0..$maxCount');
    }
    if (p.rate < 0 || p.rate > 1000) {
      throw SolverException('rate must be between 0 and 1000%');
    }

    final target = r.targetBalance;
    String? note;
    switch (r.solveFor) {
      case GoalVar.targetBalance:
        break;
      case GoalVar.startBalance:
        p.startBalance = _linear(p, target!, (q, x) => q.startBalance = x,
            from: _opening(p));
      case GoalVar.amount:
        p.amount = _linear(p, target!, (q, x) => q.amount = x);
      case GoalVar.oneOff:
        p.oneOff = _linear(p, target!, (q, x) => q.oneOff = x);
      case GoalVar.rate:
        p.rate = _solveRate(p, target!);
      case GoalVar.endDate:
        final (end, n) = _solveEnd(p, target!);
        p.end = end;
        note = n;
      case GoalVar.count:
        p.count = _solveCount(p, target!);
      case GoalVar.interval:
        p.interval = _solveInterval(p, target!);
      case GoalVar.startDate:
        p.start = _solveStart(p, target!);
    }
    return _result(r, p, note: note);
  }

  // --- projection ----------------------------------------------------------

  double _opening(_Params p) =>
      baseline.openingAt(baseline.indexOf(p.start));

  List<DateTime> _payments(_Params p, DateTime end) {
    if (p.amount == 0 || p.count == 0) return const [];
    final probe = Transaction(
      id: 'goal',
      accountId: '',
      name: '',
      direction: Direction.credit,
      amount: Decimal.one,
      startDate: p.start,
      recurrenceMode: RecurrenceMode.every,
      interval: p.interval,
      unit: p.unit,
      endMode: p.count == null ? EndMode.never : EndMode.count,
      occurrenceCount: p.count,
      enabled: true,
      createdAt: DateTime.utc(2000),
    );
    return OccurrenceGenerator.datesForTransaction(probe, p.start, end);
  }

  /// Closing balances from the start date through [end] (inclusive).
  List<double> _project(_Params p, DateTime end) {
    final i0 = baseline.indexOf(p.start);
    final n = CalendarMath.daysBetween(p.start, end) + 1;
    if (n <= 0) return const [];
    final pay = <int>{
      for (final d in _payments(p, end)) CalendarMath.daysBetween(p.start, d),
    };
    final daily = p.rate / 100 / 365;
    var b = p.startBalance ?? baseline.openingAt(i0);
    final out = List<double>.filled(n, 0);
    for (var k = 0; k < n; k++) {
      b = b * (1 + daily) + baseline.deltaAt(i0 + k);
      if (k == 0) b += p.oneOff;
      if (pay.contains(k)) b += p.amount;
      out[k] = b;
    }
    return out;
  }

  bool _meets(_Params p, double target) {
    final s = _project(p, p.end!);
    if (s.isEmpty) return false;
    return p.mode == GoalMode.onDate
        ? s.last >= target - 0.005
        : s.reduce(math.min) >= target - 0.005;
  }

  /// Exact solve for a variable the balance is linear in (start balance,
  /// amount, one-off), rounded up to the cent.
  double _linear(
    _Params p,
    double target,
    void Function(_Params, double) set, {
    double from = 0,
  }) {
    final a = p.copy()..set0(set, from);
    final b = p.copy()..set0(set, from + 1);
    final s0 = _project(a, p.end!), s1 = _project(b, p.end!);
    if (s0.isEmpty) throw SolverException('no days between start and end');
    double x;
    if (p.mode == GoalMode.onDate) {
      final slope = s1.last - s0.last;
      if (slope.abs() < 1e-9) {
        throw SolverException(
            'this value does not change the balance by the end date '
            '(no payment falls in the period)');
      }
      x = from + (target - s0.last) / slope;
    } else {
      // Every day must stay at or above the target.
      double? need;
      for (var k = 0; k < s0.length; k++) {
        final slope = s1[k] - s0[k];
        if (slope.abs() < 1e-9) {
          if (s0[k] < target - 0.005) {
            throw SolverException(
                'the balance drops below the target on '
                '${formatDate(p.start.add(Duration(days: k)))} before this '
                'value can help');
          }
          continue;
        }
        final xk = from + (target - s0[k]) / slope;
        need = need == null ? xk : math.max(need, xk);
      }
      if (need == null) throw SolverException('this value has no effect');
      x = need;
    }
    return (x * 100).ceilToDouble() / 100;
  }

  double _solveRate(_Params p, double target) {
    final q = p.copy()..rate = 0;
    if (_meets(q, target)) return 0;
    q.rate = 1000;
    if (!_meets(q, target)) {
      throw SolverException('no rate up to 1000% reaches the target');
    }
    var lo = 0.0, hi = 1000.0;
    for (var i = 0; i < 60; i++) {
      final mid = (lo + hi) / 2;
      q.rate = mid;
      if (_meets(q, target)) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    return (hi * 100).ceilToDouble() / 100;
  }

  /// onDate: the first day the balance reaches the target (crossing in
  /// whichever direction it starts from). floor: the last day before it
  /// first drops below the target (how long it lasts).
  (DateTime, String?) _solveEnd(_Params p, double target) {
    final horizonEnd = p.start.add(Duration(days: horizonDays));
    final s = _project(p, horizonEnd);
    if (p.mode == GoalMode.floor) {
      for (var k = 0; k < s.length; k++) {
        if (s[k] < target - 0.005) {
          if (k == 0) {
            throw SolverException('the balance is below the target from the '
                'start date');
          }
          return (p.start.add(Duration(days: k - 1)), null);
        }
      }
      return (
        horizonEnd,
        'stays at or above the target for the next ${horizonDays ~/ 365} years'
      );
    }
    final opening = p.startBalance ?? _opening(p);
    final up = target >= opening;
    for (var k = 0; k < s.length; k++) {
      if (up ? s[k] >= target - 0.005 : s[k] <= target + 0.005) {
        return (p.start.add(Duration(days: k)), null);
      }
    }
    throw SolverException(
        'the target is not reached within ${horizonDays ~/ 365} years');
  }

  int _solveCount(_Params p, double target) {
    final q = p.copy();
    final all = _payments(q..count = null, p.end!).length;
    q.count = all;
    if (all == 0 || !_meets(q, target)) {
      throw SolverException(
          'even every payment to the end date ($all) does not reach the '
          'target');
    }
    var lo = 0, hi = all;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      q.count = mid;
      if (_meets(q, target)) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  /// The least frequent spacing that still reaches the target.
  int _solveInterval(_Params p, double target) {
    final days = CalendarMath.daysBetween(p.start, p.end!);
    final maxK = math.max(1, switch (p.unit) {
      RecurrenceUnit.days => days + 1,
      RecurrenceUnit.weeks => days ~/ 7 + 1,
      RecurrenceUnit.months => days ~/ 28 + 1,
      RecurrenceUnit.years => days ~/ 365 + 1,
    });
    final q = p.copy();
    int? best;
    for (var k = 1; k <= math.min(maxK, 2000); k++) {
      q.interval = k;
      if (_meets(q, target)) best = k;
    }
    if (best == null) {
      throw SolverException('no frequency reaches the target, even every '
          '1 ${p.unit.name.substring(0, p.unit.name.length - 1)}');
    }
    return best;
  }

  /// The latest start date (from today) that still reaches the target.
  DateTime _solveStart(_Params p, double target) {
    final earliest = CalendarMath.dateOnly(today);
    final end = p.end!;
    if (CalendarMath.compare(end, earliest) < 0) {
      throw SolverException('the end date is before today');
    }
    final q = p.copy()..start = earliest;
    if (!_meets(q, target)) {
      throw SolverException('even starting today does not reach the target');
    }
    var lo = 0, hi = CalendarMath.daysBetween(earliest, end);
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      q.start = earliest.add(Duration(days: mid));
      if (_meets(q, target)) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return earliest.add(Duration(days: lo));
  }

  // --- result ----------------------------------------------------------------

  GoalResult _result(GoalRequest r, _Params p, {String? note}) {
    final end = p.end!;
    final s = _project(p, end);
    final base = _Params.from(r, today)
      ..start = p.start
      ..end = end
      ..amount = 0
      ..oneOff = 0
      ..rate = 0
      ..startBalance = null;
    final baseS = _project(base, end);
    final pays = _payments(p, end);

    GoalPoint? lowest;
    DateTime? alert;
    for (var k = 0; k < s.length; k++) {
      final d = p.start.add(Duration(days: k));
      if (lowest == null || s[k] < lowest.balance) lowest = GoalPoint(d, s[k]);
      // Strictly below (equal is not an alert), with the same cent
      // tolerance as the affordability floor below.
      if (alert == null && s[k] < threshold - 0.005) alert = d;
    }

    Map<String, Object?>? afford;
    if (p.oneOff < 0) {
      // A purchase: does the balance stay at or above the alert line?
      // (Touching it is fine, so the solved maximum one-off — which lands
      // exactly on the line — reads as affordable.)
      final floor = threshold - 0.005;
      DateTime? safeUntil;
      for (var k = 0; k < s.length; k++) {
        if (s[k] < floor) break;
        safeUntil = p.start.add(Duration(days: k));
      }
      afford = {
        'affordable': lowest != null && lowest.balance >= floor,
        'threshold': _m(threshold),
        'worst': lowest?.toJson(),
        'safeUntil': safeUntil == null ? null : formatDate(safeUntil),
      };
    }

    // Change points only (plus every ~1/1500th when the rate curves it).
    final points = <GoalPoint>[];
    final opening = p.startBalance ?? _opening(p);
    points.add(GoalPoint(p.start.subtract(const Duration(days: 1)), opening));
    var last = opening;
    final stride = math.max(1, s.length ~/ 1500);
    for (var k = 0; k < s.length; k++) {
      final keep = (s[k] - last).abs() >= 0.005 &&
          (p.rate == 0 || k % stride == 0);
      if (keep || k == s.length - 1) {
        points.add(GoalPoint(p.start.add(Duration(days: k)), s[k]));
        last = s[k];
      }
    }

    return GoalResult(
      request: r,
      values: {
        'startDate': formatDate(p.start),
        'endDate': formatDate(end),
        'startBalance': _m(opening),
        'targetBalance': _m(r.solveFor == GoalVar.targetBalance
            ? (p.mode == GoalMode.floor ? lowest!.balance : s.last)
            : r.targetBalance!),
        'amount': _m(p.amount),
        'interval': p.interval,
        'unit': p.unit.name,
        'count': p.count ?? pays.length,
        'oneOff': _m(p.oneOff),
        'rate': p.rate,
      },
      points: points,
      projectedStartBalance: _opening(p),
      baselineEndBalance: baseS.isEmpty ? null : baseS.last,
      endBalance: s.isEmpty ? null : s.last,
      lowest: lowest,
      alertDate: alert,
      paymentDates: pays,
      affordability: afford,
      note: note,
    );
  }
}

class _Params {
  _Params({
    required this.start,
    required this.end,
    required this.unit,
    required this.interval,
    required this.mode,
    this.startBalance,
    this.amount = 0,
    this.count,
    this.oneOff = 0,
    this.rate = 0,
  });

  DateTime start;
  DateTime? end;
  RecurrenceUnit unit;
  int interval;
  GoalMode mode;
  double? startBalance;
  double amount;
  int? count;
  double oneOff;
  double rate;

  factory _Params.from(GoalRequest r, DateTime today) => _Params(
        start: CalendarMath.dateOnly(r.startDate ?? today),
        end: r.endDate == null ? null : CalendarMath.dateOnly(r.endDate!),
        unit: r.unit,
        interval: r.interval ?? 1,
        mode: r.mode,
        startBalance: r.startBalance,
        amount: r.amount ?? 0,
        count: r.count,
        oneOff: r.oneOff ?? 0,
        rate: r.rate ?? 0,
      );

  _Params copy() => _Params(
        start: start,
        end: end,
        unit: unit,
        interval: interval,
        mode: mode,
        startBalance: startBalance,
        amount: amount,
        count: count,
        oneOff: oneOff,
        rate: rate,
      );

  void set0(void Function(_Params, double) set, double v) => set(this, v);
}
