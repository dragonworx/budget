import 'package:decimal/decimal.dart';
import 'package:uuid/uuid.dart';

import '../domain/enums.dart';
import '../domain/models.dart';
import 'calendar_math.dart';
import 'occurrence_gen.dart';

class SolverException implements Exception {
  SolverException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The six event-planning variables (§4.1). [interval] is the "every N"
/// part of the frequency; the unit is always chosen by the user.
enum SolveVar {
  startDate,
  endDate,
  amount,
  total,
  interval,
  count;

  String get label => switch (this) {
        SolveVar.startDate => 'start date',
        SolveVar.endDate => 'end date',
        SolveVar.amount => 'amount each time',
        SolveVar.total => 'total amount',
        SolveVar.interval => 'frequency',
        SolveVar.count => 'count',
      };
}

class SolveRequest {
  SolveRequest({
    required this.direction,
    required this.unit,
    this.name = '',
    this.startDate,
    this.endDate,
    this.amount,
    this.interval,
    this.occurrenceCount,
    this.targetTotal,
    this.rounding = RoundingMode.nearest,
    this.enabled = true,
  });

  final Direction direction;
  final RecurrenceUnit unit;
  final String name;
  final DateTime? startDate;
  final DateTime? endDate;
  final Decimal? amount;
  final int? interval;
  final int? occurrenceCount;
  final Decimal? targetTotal;
  final RoundingMode rounding;
  final bool enabled;
}

class SolveResult {
  SolveResult({
    required this.known,
    required this.solved,
    required this.values,
    this.event,
    this.previewOccurrences = const [],
    this.needsMore = 0,
    this.needsOneOf = const [],
  });

  final Set<SolveVar> known;
  final Set<SolveVar> solved;
  final SolveValues values;

  /// Null until every variable is determined.
  final BudgetEvent? event;
  final List<Occurrence> previewOccurrences;

  /// Minimum number of extra known values needed to finish solving.
  final int needsMore;

  /// Variables that could be filled in (any one of, when [needsMore] is 1).
  final List<SolveVar> needsOneOf;

  bool get isComplete => event != null;

  Map<String, Object?> toJson() => {
        'status': isComplete ? 'solved' : 'incomplete',
        'known': [
          for (final v in SolveVar.values)
            if (known.contains(v)) v.name
        ],
        'solved': [
          for (final v in SolveVar.values)
            if (solved.contains(v)) v.name,
        ],
        'values': values.toJson(),
        if (!isComplete) 'needsMore': needsMore,
        if (!isComplete) 'needsOneOf': [for (final v in needsOneOf) v.name],
        if (event != null) 'event': event!.toJson(),
        'previewOccurrences':
            previewOccurrences.map((o) => o.toJson()).toList(),
      };
}

class SolveValues {
  SolveValues(this.unit);

  final RecurrenceUnit unit;
  DateTime? startDate;
  DateTime? endDate;
  Decimal? amount;
  Decimal? total;
  int? interval;
  int? count;

  /// Last occurrence date once the schedule is fully known.
  DateTime? lastDate;

  bool has(SolveVar v) => switch (v) {
        SolveVar.startDate => startDate != null,
        SolveVar.endDate => endDate != null,
        SolveVar.amount => amount != null,
        SolveVar.total => total != null,
        SolveVar.interval => interval != null,
        SolveVar.count => count != null,
      };

  Map<String, Object?> toJson() => {
        'startDate': startDate == null ? null : formatDate(startDate!),
        'endDate': endDate == null ? null : formatDate(endDate!),
        'lastOccurrenceDate': lastDate == null ? null : formatDate(lastDate!),
        'amount': amount?.toString(),
        'total': total?.toString(),
        'actualTotal': amount != null && count != null
            ? (amount! * Decimal.fromInt(count!)).toString()
            : null,
        'interval': interval,
        'unit': unit.name,
        'count': count,
      };
}

enum _Relation { total, schedule }

class _Step {
  const _Step(this.relation, this.output, this.inputs);
  final _Relation relation;
  final SolveVar output;
  final List<SolveVar> inputs;
}

/// Fills in whichever event variables can be derived from the known ones
/// (§4). Two relations tie the variables together:
///
/// * total:    `T = A × N`
/// * schedule: `S`, `F`, `N`, `E` — any three determine the fourth
///
/// so any four independent knowns determine the whole event.
class EventSolver {
  static final _uuid = Uuid();

  static const maxCount = 10000;

  static const _steps = [
    _Step(_Relation.total, SolveVar.count, [SolveVar.total, SolveVar.amount]),
    _Step(_Relation.total, SolveVar.amount, [SolveVar.total, SolveVar.count]),
    _Step(_Relation.total, SolveVar.total, [SolveVar.amount, SolveVar.count]),
    _Step(
      _Relation.schedule,
      SolveVar.count,
      [SolveVar.startDate, SolveVar.interval, SolveVar.endDate],
    ),
    _Step(
      _Relation.schedule,
      SolveVar.endDate,
      [SolveVar.startDate, SolveVar.interval, SolveVar.count],
    ),
    _Step(
      _Relation.schedule,
      SolveVar.startDate,
      [SolveVar.endDate, SolveVar.interval, SolveVar.count],
    ),
    _Step(
      _Relation.schedule,
      SolveVar.interval,
      [SolveVar.startDate, SolveVar.endDate, SolveVar.count],
    ),
  ];

  static SolveResult solve(SolveRequest req) {
    _validate(req);

    final v = SolveValues(req.unit)
      ..startDate =
          req.startDate == null ? null : CalendarMath.dateOnly(req.startDate!)
      ..endDate =
          req.endDate == null ? null : CalendarMath.dateOnly(req.endDate!)
      ..amount = req.amount
      ..total = req.targetTotal
      ..interval = req.interval
      ..count = req.occurrenceCount;

    final known = {
      for (final x in SolveVar.values)
        if (v.has(x)) x
    };
    final solved = <SolveVar>{};
    final used = <_Relation>{};

    var progress = true;
    while (progress) {
      progress = false;
      for (final step in _steps) {
        if (used.contains(step.relation) || v.has(step.output)) continue;
        if (!step.inputs.every(v.has)) continue;
        _apply(step.output, v, req);
        solved.add(step.output);
        used.add(step.relation);
        progress = true;
      }
    }

    if (!used.contains(_Relation.total) &&
        v.has(SolveVar.total) &&
        v.has(SolveVar.amount) &&
        v.has(SolveVar.count)) {
      _checkTotal(v, req.rounding);
    }
    if (!used.contains(_Relation.schedule) &&
        v.has(SolveVar.startDate) &&
        v.has(SolveVar.interval) &&
        v.has(SolveVar.count) &&
        v.has(SolveVar.endDate)) {
      _checkSchedule(v);
    }

    if (!SolveVar.values.every(v.has)) {
      final (more, candidates) = _missing(known);
      return SolveResult(
        known: known,
        solved: solved,
        values: v,
        needsMore: more,
        needsOneOf: candidates,
      );
    }

    final event =
        _buildEvent(req, v, endDateKnown: known.contains(SolveVar.endDate));
    v.lastDate = OccurrenceGenerator.nthDate(event, v.count!);
    final preview = OccurrenceGenerator.generate(
      events: [event],
      from: v.startDate!,
      to: v.lastDate ?? v.startDate!,
    );
    return SolveResult(
      known: known,
      solved: solved,
      values: v,
      event: event,
      previewOccurrences: preview,
    );
  }

  static void _validate(SolveRequest req) {
    if (req.amount != null && req.amount! <= Decimal.zero) {
      throw SolverException('amount each time must be greater than 0');
    }
    if (req.targetTotal != null && req.targetTotal! <= Decimal.zero) {
      throw SolverException('total amount must be greater than 0');
    }
    if (req.occurrenceCount != null && req.occurrenceCount! < 1) {
      throw SolverException('count must be at least 1');
    }
    if (req.occurrenceCount != null && req.occurrenceCount! > maxCount) {
      throw SolverException('count must be at most $maxCount');
    }
    if (req.interval != null && req.interval! < 1) {
      throw SolverException('frequency interval must be at least 1');
    }
    if (req.startDate != null &&
        req.endDate != null &&
        CalendarMath.compare(req.endDate!, req.startDate!) < 0) {
      throw SolverException('end date must be on or after the start date');
    }
  }

  static void _apply(SolveVar output, SolveValues v, SolveRequest req) {
    switch (output) {
      case SolveVar.count when v.total != null && v.amount != null:
        final n = _roundPositiveInt(_div(v.total!, v.amount!), req.rounding);
        if (n < 1) {
          throw SolverException(
            'total ${v.total} is less than one payment of ${v.amount}',
          );
        }
        if (n > maxCount) {
          throw SolverException(
            'total ÷ amount each time gives $n occurrences (max $maxCount)',
          );
        }
        v.count = n;
      case SolveVar.count:
        final n = _countBetween(v.startDate!, v.endDate!, v.interval!, v.unit);
        if (n > maxCount) {
          throw SolverException(
            'start to end date gives $n occurrences (max $maxCount)',
          );
        }
        v.count = n;
      case SolveVar.amount:
        final raw = _div(v.total!, Decimal.fromInt(v.count!), scale: 10);
        final a = _roundMoney(raw, req.rounding, v.total!, v.count!);
        if (a <= Decimal.zero) {
          throw SolverException(
            'total ${v.total} over ${v.count} occurrences rounds to 0',
          );
        }
        v.amount = a;
      case SolveVar.total:
        v.total = v.amount! * Decimal.fromInt(v.count!);
      case SolveVar.endDate:
        v.endDate = _nth(v.startDate!, v.count!, v.interval!, v.unit);
      case SolveVar.startDate:
        v.startDate = CalendarMath.subtract(
          v.endDate!,
          v.interval! * (v.count! - 1),
          v.unit,
        );
      case SolveVar.interval:
        v.interval = _findInterval(
          start: v.startDate!,
          end: v.endDate!,
          unit: v.unit,
          desiredN: v.count!,
        );
    }
  }

  static void _checkTotal(SolveValues v, RoundingMode rounding) {
    final n = _roundPositiveInt(_div(v.total!, v.amount!), rounding);
    if (n == v.count) return;
    final actual = v.amount! * Decimal.fromInt(v.count!);
    throw SolverException(
      'total ${v.total} does not match ${v.amount} × ${v.count} = $actual. '
      'Clear one of total, amount each time, or count to have it calculated.',
    );
  }

  static void _checkSchedule(SolveValues v) {
    final n = _countBetween(v.startDate!, v.endDate!, v.interval!, v.unit);
    if (n == v.count) return;
    throw SolverException(
      '${formatDate(v.startDate!)} to ${formatDate(v.endDate!)} every '
      '${v.interval} ${v.unit.name} gives $n occurrences, not ${v.count}. '
      'Clear one of start date, end date, frequency, or count to have it '
      'calculated.',
    );
  }

  /// Smallest number of extra knowns that would complete the solve, and the
  /// variables that appear in any such minimal completion.
  static (int, List<SolveVar>) _missing(Set<SolveVar> known) {
    final closed = _closure(known);
    final open = SolveVar.values.where((x) => !closed.contains(x)).toList();
    for (var size = 1; size <= open.length; size++) {
      final hits = <SolveVar>{};
      for (final combo in _combinations(open, size)) {
        if (_closure({...known, ...combo}).length == SolveVar.values.length) {
          hits.addAll(combo);
        }
      }
      if (hits.isNotEmpty) {
        return (
          size,
          [
            for (final x in open)
              if (hits.contains(x)) x
          ]
        );
      }
    }
    return (open.length, open);
  }

  static Set<SolveVar> _closure(Set<SolveVar> known) {
    final out = {...known};
    final used = <_Relation>{};
    var progress = true;
    while (progress) {
      progress = false;
      for (final step in _steps) {
        if (used.contains(step.relation) || out.contains(step.output)) continue;
        if (!step.inputs.every(out.contains)) continue;
        out.add(step.output);
        used.add(step.relation);
        progress = true;
      }
    }
    return out;
  }

  static Iterable<List<T>> _combinations<T>(List<T> items, int size) sync* {
    if (size == 0) {
      yield const [];
      return;
    }
    for (var i = 0; i <= items.length - size; i++) {
      for (final rest in _combinations(items.sublist(i + 1), size - 1)) {
        yield [items[i], ...rest];
      }
    }
  }

  static BudgetEvent _probe(
          DateTime start, int interval, RecurrenceUnit unit) =>
      BudgetEvent(
        id: 'probe',
        streamId: 'probe',
        name: '',
        direction: Direction.credit,
        amount: Decimal.one,
        startDate: start,
        recurrenceMode: RecurrenceMode.every,
        interval: interval,
        unit: unit,
        endMode: EndMode.never,
        enabled: true,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  static DateTime _nth(
    DateTime start,
    int n,
    int interval,
    RecurrenceUnit unit,
  ) =>
      OccurrenceGenerator.nthDate(_probe(start, interval, unit), n)!;

  static int _countBetween(
    DateTime start,
    DateTime end,
    int interval,
    RecurrenceUnit unit,
  ) =>
      OccurrenceGenerator.countThrough(_probe(start, interval, unit), end);

  /// Smallest interval in [unit] giving exactly [desiredN] occurrences
  /// on `[start, end]`.
  static int _findInterval({
    required DateTime start,
    required DateTime end,
    required RecurrenceUnit unit,
    required int desiredN,
  }) {
    final days = CalendarMath.daysBetween(start, end);
    final maxInterval = switch (unit) {
      RecurrenceUnit.days => days + 1,
      RecurrenceUnit.weeks => days ~/ 7 + 1,
      RecurrenceUnit.months => days ~/ 28 + 1,
      RecurrenceUnit.years => days ~/ 365 + 1,
    };

    int? aboveInterval, aboveN, belowInterval, belowN;
    for (var interval = 1; interval <= maxInterval; interval++) {
      final n = _countBetween(start, end, interval, unit);
      if (n == desiredN) return interval;
      if (n > desiredN) {
        aboveInterval = interval;
        aboveN = n;
      } else {
        belowInterval = interval;
        belowN = n;
        break;
      }
    }

    final options = [
      if (aboveInterval != null)
        'every $aboveInterval ${unit.name} gives $aboveN',
      if (belowInterval != null)
        'every $belowInterval ${unit.name} gives $belowN',
    ];
    throw SolverException(
      'no frequency in ${unit.name} gives exactly $desiredN occurrences '
      'between ${formatDate(start)} and ${formatDate(end)}'
      '${options.isEmpty ? '' : ' (${options.join(', ')})'}. '
      'Try a different unit or adjust the dates.',
    );
  }

  static Decimal _div(Decimal a, Decimal b, {int scale = 10}) =>
      (a / b).toDecimal(scaleOnInfinitePrecision: scale);

  static int _roundPositiveInt(Decimal value, RoundingMode mode) {
    if (value <= Decimal.zero) return 0;
    final floor = value.floor().toBigInt().toInt();
    final ceil = value.ceil().toBigInt().toInt();
    return switch (mode) {
      RoundingMode.nearest => () {
          final half = Decimal.parse('0.5');
          final frac = value - Decimal.fromInt(floor);
          return frac < half ? floor : (frac > half ? ceil : floor);
        }(),
      RoundingMode.atLeast => ceil,
      RoundingMode.atMost => floor,
    };
  }

  /// Rounds to cents so `A × N` is nearest / atLeast / atMost [target].
  static Decimal _roundMoney(
    Decimal raw,
    RoundingMode mode,
    Decimal target,
    int n,
  ) {
    final scale = Decimal.parse('100');
    final rawCents = raw * scale;
    Decimal fromCents(BigInt c) => _div(Decimal.fromBigInt(c), scale, scale: 2);

    final floorA = fromCents(rawCents.floor().toBigInt());
    final ceilA = fromCents(rawCents.ceil().toBigInt());
    final nDec = Decimal.fromInt(n);

    return switch (mode) {
      RoundingMode.nearest =>
        (target - floorA * nDec).abs() <= (target - ceilA * nDec).abs()
            ? floorA
            : ceilA,
      RoundingMode.atLeast => floorA * nDec >= target ? floorA : ceilA,
      RoundingMode.atMost => ceilA * nDec <= target ? ceilA : floorA,
    };
  }

  static BudgetEvent _buildEvent(
    SolveRequest req,
    SolveValues v, {
    required bool endDateKnown,
  }) {
    final base = BudgetEvent(
      id: _uuid.v4(),
      streamId: '', // filled by API layer
      name: req.name,
      direction: req.direction,
      amount: v.amount!,
      startDate: v.startDate!,
      recurrenceMode: RecurrenceMode.once,
      endMode: EndMode.never,
      enabled: req.enabled,
      createdAt: DateTime.now().toUtc(),
    );
    if (v.count == 1) return base;

    return base.copyWith(
      recurrenceMode: RecurrenceMode.every,
      interval: v.interval,
      unit: v.unit,
      endMode: endDateKnown ? EndMode.untilDate : EndMode.count,
      endDate: endDateKnown ? v.endDate : null,
      occurrenceCount: endDateKnown ? null : v.count,
    );
  }
}
