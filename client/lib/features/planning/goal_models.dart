import 'package:decimal/decimal.dart';

import '../../data/models.dart';

/// Balance-goal variables (mirrors the server's GoalVar, §4.5).
enum GoalVar {
  startBalance('Start balance'),
  targetBalance('Target balance'),
  amount('Amount each time'),
  interval('Frequency'),
  startDate('Start date'),
  endDate('End date'),
  count('Count'),
  oneOff('One-off'),
  rate('Interest / growth');

  const GoalVar(this.label);
  final String label;

  static GoalVar? tryParse(Object? v) {
    for (final g in values) {
      if (g.name == v) return g;
    }
    return null;
  }
}

/// [onDate]: the balance on the end date reaches the target. [floor]: the
/// balance never drops below the target from the start through the end.
enum GoalMode {
  onDate,
  floor;

  static GoalMode parse(Object? v) => v == 'floor' ? floor : onDate;
}

class GoalRequest {
  const GoalRequest({
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
  final double? startBalance;
  final double? targetBalance;

  /// Signed: + in, − out, each time.
  final double? amount;
  final int? interval;
  final int? count;

  /// Signed one-off on the start date (− = a purchase).
  final double? oneOff;

  /// Annual %, compounded daily.
  final double? rate;

  Map<String, dynamic> toJson() => {
    'solveFor': solveFor.name,
    'mode': mode.name,
    'unit': unit.toJson(),
    if (startDate != null) 'startDate': formatDate(startDate!),
    if (endDate != null) 'endDate': formatDate(endDate!),
    if (startBalance != null) 'startBalance': startBalance,
    if (targetBalance != null) 'targetBalance': targetBalance,
    if (amount != null) 'amount': amount,
    if (interval != null) 'interval': interval,
    if (count != null) 'count': count,
    if (oneOff != null) 'oneOff': oneOff,
    if (rate != null) 'rate': rate,
  };

  factory GoalRequest.fromJson(Map<String, dynamic> j) {
    DateTime? date(String k) => j[k] == null ? null : parseDate(j[k]);
    double? num_(String k) =>
        j[k] == null ? null : double.tryParse(j[k].toString());
    int? int_(String k) => j[k] == null ? null : int.tryParse('${j[k]}');
    return GoalRequest(
      solveFor: GoalVar.tryParse(j['solveFor']) ?? GoalVar.amount,
      mode: GoalMode.parse(j['mode']),
      unit: RecurrenceUnit.values.firstWhere(
        (u) => u.toJson() == j['unit'],
        orElse: () => RecurrenceUnit.weeks,
      ),
      startDate: date('startDate'),
      endDate: date('endDate'),
      startBalance: num_('startBalance'),
      targetBalance: num_('targetBalance'),
      amount: num_('amount'),
      interval: int_('interval'),
      count: int_('count'),
      oneOff: num_('oneOff'),
      rate: num_('rate'),
    );
  }

  /// [v]'s value from a solved result, for locking it in after the solve
  /// slot moves elsewhere.
  GoalRequest withValue(GoalVar v, Object? value) => GoalRequest(
    solveFor: solveFor,
    mode: mode,
    unit: unit,
    startDate: v == GoalVar.startDate ? value as DateTime? : startDate,
    endDate: v == GoalVar.endDate ? value as DateTime? : endDate,
    startBalance: v == GoalVar.startBalance ? value as double? : startBalance,
    targetBalance: v == GoalVar.targetBalance
        ? value as double?
        : targetBalance,
    amount: v == GoalVar.amount ? value as double? : amount,
    interval: v == GoalVar.interval ? value as int? : interval,
    count: v == GoalVar.count ? value as int? : count,
    oneOff: v == GoalVar.oneOff ? value as double? : oneOff,
    rate: v == GoalVar.rate ? value as double? : rate,
  );

  GoalRequest copyWith({
    GoalVar? solveFor,
    GoalMode? mode,
    RecurrenceUnit? unit,
  }) => GoalRequest(
    solveFor: solveFor ?? this.solveFor,
    mode: mode ?? this.mode,
    unit: unit ?? this.unit,
    startDate: startDate,
    endDate: endDate,
    startBalance: startBalance,
    targetBalance: targetBalance,
    amount: amount,
    interval: interval,
    count: count,
    oneOff: oneOff,
    rate: rate,
  );
}

class GoalValues {
  const GoalValues({
    required this.startDate,
    required this.endDate,
    required this.startBalance,
    required this.targetBalance,
    required this.amount,
    required this.interval,
    required this.unit,
    required this.count,
    required this.oneOff,
    required this.rate,
  });

  final DateTime startDate;
  final DateTime endDate;
  final double startBalance;
  final double targetBalance;
  final double amount;
  final int interval;
  final RecurrenceUnit unit;
  final int count;
  final double oneOff;
  final double rate;

  Object? of(GoalVar v) => switch (v) {
    GoalVar.startBalance => startBalance,
    GoalVar.targetBalance => targetBalance,
    GoalVar.amount => amount,
    GoalVar.interval => interval,
    GoalVar.startDate => startDate,
    GoalVar.endDate => endDate,
    GoalVar.count => count,
    GoalVar.oneOff => oneOff,
    GoalVar.rate => rate,
  };

  factory GoalValues.fromJson(Map<String, dynamic> j) => GoalValues(
    startDate: parseDate(j['startDate']),
    endDate: parseDate(j['endDate']),
    startBalance: double.parse('${j['startBalance']}'),
    targetBalance: double.parse('${j['targetBalance']}'),
    amount: double.parse('${j['amount']}'),
    interval: (j['interval'] as num).toInt(),
    unit: RecurrenceUnit.values.firstWhere(
      (u) => u.toJson() == j['unit'],
      orElse: () => RecurrenceUnit.weeks,
    ),
    count: (j['count'] as num).toInt(),
    oneOff: double.parse('${j['oneOff']}'),
    rate: (j['rate'] as num).toDouble(),
  );
}

class Affordability {
  const Affordability({
    required this.affordable,
    this.worstDate,
    this.worstBalance,
    this.safeUntil,
  });

  final bool affordable;
  final DateTime? worstDate;
  final double? worstBalance;

  /// Last day the balance stays above the alert line after the purchase.
  final DateTime? safeUntil;

  factory Affordability.fromJson(Map<String, dynamic> j) {
    final w = j['worst'];
    return Affordability(
      affordable: j['affordable'] == true,
      worstDate: w is Map ? parseDate(w['date']) : null,
      worstBalance: w is Map ? double.tryParse('${w['closingBalance']}') : null,
      safeUntil: j['safeUntil'] == null ? null : parseDate(j['safeUntil']),
    );
  }
}

class GoalResult {
  const GoalResult({
    required this.solveFor,
    this.needsOneOf = const [],
    this.values,
    this.points = const [],
    this.projectedStartBalance,
    this.baselineEndBalance,
    this.endBalance,
    this.lowestDate,
    this.lowestBalance,
    this.alertDate,
    this.paymentCount = 0,
    this.affordability,
    this.note,
  });

  final GoalVar solveFor;
  final List<GoalVar> needsOneOf;
  final GoalValues? values;
  final List<BalancePoint> points;
  final double? projectedStartBalance;
  final double? baselineEndBalance;
  final double? endBalance;
  final DateTime? lowestDate;
  final double? lowestBalance;
  final DateTime? alertDate;
  final int paymentCount;
  final Affordability? affordability;
  final String? note;

  bool get isComplete => values != null;

  factory GoalResult.fromJson(Map<String, dynamic> j) {
    double? d(String k) => j[k] == null ? null : double.tryParse('${j[k]}');
    final low = j['lowest'];
    return GoalResult(
      solveFor: GoalVar.tryParse(j['solveFor']) ?? GoalVar.amount,
      needsOneOf: [
        for (final v in (j['needsOneOf'] as List? ?? const []))
          ?GoalVar.tryParse(v),
      ],
      values: j['values'] is Map<String, dynamic>
          ? GoalValues.fromJson(j['values'])
          : null,
      points: [
        for (final p in (j['points'] as List? ?? const []))
          BalancePoint.fromJson(p as Map<String, dynamic>),
      ],
      projectedStartBalance: d('projectedStartBalance'),
      baselineEndBalance: d('baselineEndBalance'),
      endBalance: d('endBalance'),
      lowestDate: low is Map ? parseDate(low['date']) : null,
      lowestBalance: low is Map
          ? double.tryParse('${low['closingBalance']}')
          : null,
      alertDate: j['alertDate'] == null ? null : parseDate(j['alertDate']),
      paymentCount: (j['paymentCount'] as num?)?.toInt() ?? 0,
      affordability: j['affordability'] is Map<String, dynamic>
          ? Affordability.fromJson(j['affordability'])
          : null,
      note: j['note'] as String?,
    );
  }

  /// The plan as transactions to add (explicit button only): the
  /// recurring payment and/or the one-off.
  List<Transaction> toTransactions(String poolId, {String name = 'Goal'}) {
    final v = values;
    if (v == null) return const [];
    final out = <Transaction>[];
    Transaction base(double signed, String label) => Transaction(
      id: '',
      poolId: poolId,
      name: label,
      direction: signed >= 0
          ? TransactionDirection.credit
          : TransactionDirection.debit,
      amount: Decimal.parse(signed.abs().toStringAsFixed(2)),
      startDate: v.startDate,
      recurrenceMode: RecurrenceMode.once,
      endMode: EndMode.never,
      enabled: true,
    );
    if (v.amount != 0 && v.count > 0) {
      final t = base(v.amount, name);
      out.add(
        v.count == 1
            ? t
            : t.copyWith(
                recurrenceMode: RecurrenceMode.every,
                interval: v.interval,
                unit: v.unit,
                endMode: EndMode.count,
                occurrenceCount: v.count,
              ),
      );
    }
    if (v.oneOff != 0) out.add(base(v.oneOff, '$name (one-off)'));
    return out;
  }
}

/// A saved what-if: a goal request stored per pool. Included scenarios
/// are overlaid on the chart as coloured ghost lines; they never change the
/// pool's real transactions.
class Scenario {
  const Scenario({
    required this.id,
    required this.name,
    required this.colorIndex,
    required this.included,
    required this.request,
  });

  final String id;
  final String name;
  final int colorIndex;
  final bool included;
  final GoalRequest request;

  factory Scenario.fromJson(Map<String, dynamic> j) => Scenario(
    id: j['id'] as String,
    name: j['name'] as String,
    colorIndex: (j['colorIndex'] as num?)?.toInt() ?? 0,
    included: j['included'] as bool? ?? true,
    request: GoalRequest.fromJson(
      Map<String, dynamic>.from(j['request'] as Map),
    ),
  );
}

/// "+3 wks" / "−5 days" / "same": how much later (+) the alert date lands.
String shiftText(int days) {
  if (days == 0) return 'same';
  final sign = days > 0 ? '+' : '−';
  final a = days.abs();
  if (a >= 14 && a % 7 == 0 || a >= 28) {
    final w = (a / 7).round();
    return '$sign$w wk${w == 1 ? '' : 's'}';
  }
  return '$sign$a day${a == 1 ? '' : 's'}';
}

/// Delta of a solved scenario against the pool as it is: the balance
/// change at the plan's end and how far the first alert date moves.
/// [baselineAlert] is the pool's current first alert date (null: none
/// within the horizon). Returns parts like ['+$420 by 1 Mar', 'alert +3 wks'].
({double? balance, int? alertShiftDays, bool alertCleared, bool alertNew})
scenarioDelta(GoalResult r, DateTime? baselineAlert) {
  final end = r.endBalance, base = r.baselineEndBalance;
  final balance = end == null || base == null ? null : end - base;
  final a = r.alertDate;
  int? shift;
  var cleared = false, isNew = false;
  if (a != null && baselineAlert != null) {
    shift = DateTime.utc(a.year, a.month, a.day)
        .difference(
          DateTime.utc(
            baselineAlert.year,
            baselineAlert.month,
            baselineAlert.day,
          ),
        )
        .inDays;
  } else if (a == null && baselineAlert != null) {
    final endDate = r.values?.endDate;
    // Only "cleared" when the plan window covers the old alert date.
    cleared = endDate != null && !endDate.isBefore(baselineAlert);
  } else if (a != null && baselineAlert == null) {
    isNew = true;
  }
  return (
    balance: balance,
    alertShiftDays: shift,
    alertCleared: cleared,
    alertNew: isNew,
  );
}
