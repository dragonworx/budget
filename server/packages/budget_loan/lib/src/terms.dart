import 'dart:convert';

import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:decimal/decimal.dart';

/// A loan JSON problem, naming the field (`loan.ratePeriods[1].ratePct must
/// be …`). The server turns it into a 400.
class LoanFormatException extends FormatException {
  const LoanFormatException(super.message);
}

/// Largest accepted `loan` JSON (encoded), in bytes.
const maxLoanJsonBytes = 16 * 1024;

/// Most rate periods a loan may have.
const maxRatePeriods = 120;

enum LoanMode { simple, advanced }

enum InterestType { reducing, flat }

enum RepaymentFrequency {
  weekly,
  fortnightly,
  monthly;

  /// Repayments per year (the annual-split convention).
  int get perYear => switch (this) {
        weekly => 52,
        fortnightly => 26,
        monthly => 12,
      };
}

enum ChargeSchedule { monthly, onRepaymentDates }

enum DayCount {
  d365('365'),
  actual('actual');

  const DayCount(this.json);
  final String json;
}

enum RateType { fixed, variable }

/// The day of the month a `monthly` charge schedule charges on.
sealed class ChargeDay {
  const ChargeDay();

  Object get json;

  @override
  String toString() => '$json';
}

/// Every monthly anniversary of the start date (day N = start day).
final class AnniversaryChargeDay extends ChargeDay {
  const AnniversaryChargeDay();
  @override
  Object get json => 'anniversary';
  @override
  bool operator ==(Object other) => other is AnniversaryChargeDay;
  @override
  int get hashCode => 1;
}

/// The last day of each month, at the end of the day.
final class MonthEndChargeDay extends ChargeDay {
  const MonthEndChargeDay();
  @override
  Object get json => 'monthEnd';
  @override
  bool operator ==(Object other) => other is MonthEndChargeDay;
  @override
  int get hashCode => 2;
}

/// Day `min(day, daysInMonth)` of every month.
final class DayOfMonthChargeDay extends ChargeDay {
  const DayOfMonthChargeDay(this.day);
  final int day;
  @override
  Object get json => day;
  @override
  bool operator ==(Object other) =>
      other is DayOfMonthChargeDay && other.day == day;
  @override
  int get hashCode => day + 100;
}

class RatePeriod {
  const RatePeriod({
    required this.from,
    required this.ratePct,
    this.type = RateType.fixed,
    this.interestOnly = false,
    this.offsetApplies = true,
    String? ratePctText,
  }) : _text = ratePctText;

  /// Inclusive start (UTC date).
  final DateTime from;
  final Decimal ratePct;
  final RateType type;
  final bool interestOnly;
  final bool offsetApplies;
  final String? _text;

  /// The rate as written (e.g. "6.40"), kept for round trips.
  String get ratePctText => _text ?? ratePct.toString();

  Map<String, Object?> toJson() => {
        'from': formatLoanDate(from),
        'ratePct': ratePctText,
        'type': type.name,
        'interestOnly': interestOnly,
        'offsetApplies': offsetApplies,
      };
}

/// The `events.loan` JSON (schema v1), defaults filled.
class LoanTerms {
  const LoanTerms({
    this.mode = LoanMode.advanced,
    this.interestType = InterestType.reducing,
    required this.termMonths,
    this.repaymentFrequency = RepaymentFrequency.monthly,
    this.firstRepaymentDate,
    this.chargeSchedule = ChargeSchedule.monthly,
    this.chargeDay = const AnniversaryChargeDay(),
    this.dayCount = DayCount.d365,
    required this.ratePeriods,
  });

  final LoanMode mode;
  final InterestType interestType;
  final int termMonths;
  final RepaymentFrequency repaymentFrequency;

  /// As stored: null until [withDefaults] fills it from the start date.
  final DateTime? firstRepaymentDate;
  final ChargeSchedule chargeSchedule;

  /// Null with [ChargeSchedule.onRepaymentDates].
  final ChargeDay? chargeDay;
  final DayCount dayCount;
  final List<RatePeriod> ratePeriods;

  bool get isFlat => interestType == InterestType.flat;

  static const _keys = {
    'v',
    'mode',
    'interestType',
    'termMonths',
    'repaymentFrequency',
    'firstRepaymentDate',
    'chargeSchedule',
    'chargeDay',
    'dayCount',
    'ratePeriods',
  };
  static const _periodKeys = {
    'from',
    'ratePct',
    'type',
    'interestOnly',
    'offsetApplies',
  };
  static final _ratePattern = RegExp(r'^\d{1,3}(\.\d{1,4})?$');

  /// Parses and checks the shape and every rule that needs no start date
  /// (see [validate] for the rest). Unknown keys, wrong types and JSON over
  /// [maxLoanJsonBytes] are rejected. Throws [LoanFormatException].
  static LoanTerms fromJson(Object? raw) {
    if (raw is! Map) throw const LoanFormatException('loan must be an object');
    if (utf8.encode(jsonEncode(raw)).length > maxLoanJsonBytes) {
      throw const LoanFormatException('loan must be at most 16 KB');
    }
    final m = raw.cast<String, Object?>();
    for (final k in m.keys) {
      if (!_keys.contains(k)) {
        throw LoanFormatException('loan.$k is not a known field');
      }
    }
    if (m['v'] != 1) throw const LoanFormatException('loan.v must be 1');
    final mode = _enum(m, 'mode', LoanMode.values, required: true)!;
    final interestType =
        _enum(m, 'interestType', InterestType.values) ?? InterestType.reducing;
    final flat = interestType == InterestType.flat;
    final term = m['termMonths'];
    if (term is! int || term < 1 || term > 600) {
      throw const LoanFormatException(
          'loan.termMonths must be a whole number from 1 to 600');
    }
    final freq = _enum(m, 'repaymentFrequency', RepaymentFrequency.values,
        required: true)!;
    final first = m['firstRepaymentDate'] == null
        ? null
        : _date(m['firstRepaymentDate'], 'loan.firstRepaymentDate');
    final schedule = _enum(m, 'chargeSchedule', ChargeSchedule.values) ??
        (flat ? ChargeSchedule.onRepaymentDates : ChargeSchedule.monthly);
    if (flat && schedule != ChargeSchedule.onRepaymentDates) {
      throw const LoanFormatException(
          'loan.chargeSchedule must be onRepaymentDates for a flat-rate loan');
    }
    final rawDay = m['chargeDay'];
    ChargeDay? chargeDay;
    if (schedule == ChargeSchedule.onRepaymentDates) {
      if (rawDay != null) {
        throw const LoanFormatException(
            'loan.chargeDay is only allowed with a monthly charge schedule');
      }
    } else {
      chargeDay = switch (rawDay) {
        null || 'anniversary' => const AnniversaryChargeDay(),
        'monthEnd' => const MonthEndChargeDay(),
        int d when d >= 1 && d <= 31 => DayOfMonthChargeDay(d),
        _ => throw const LoanFormatException(
            'loan.chargeDay must be "anniversary", "monthEnd" or a day 1 to 31'),
      };
    }
    final rawCount = m['dayCount'];
    final dayCount = switch (rawCount) {
      null || '365' => DayCount.d365,
      'actual' => DayCount.actual,
      _ => throw const LoanFormatException(
          'loan.dayCount must be "365" or "actual"'),
    };
    if (flat && dayCount != DayCount.d365) {
      throw const LoanFormatException(
          'loan.dayCount must be "365" for a flat-rate loan');
    }
    final rawPeriods = m['ratePeriods'];
    if (rawPeriods is! List || rawPeriods.isEmpty) {
      throw const LoanFormatException(
          'loan.ratePeriods must be a non-empty array');
    }
    if (rawPeriods.length > maxRatePeriods) {
      throw const LoanFormatException(
          'loan.ratePeriods must have at most $maxRatePeriods items');
    }
    if ((mode == LoanMode.simple || flat) && rawPeriods.length != 1) {
      throw LoanFormatException(flat
          ? 'loan.ratePeriods must have exactly one item for a flat-rate loan'
          : 'loan.ratePeriods must have exactly one item in simple mode');
    }
    final periods = <RatePeriod>[];
    for (var i = 0; i < rawPeriods.length; i++) {
      final f = 'loan.ratePeriods[$i]';
      final p = rawPeriods[i];
      if (p is! Map) throw LoanFormatException('$f must be an object');
      final pm = p.cast<String, Object?>();
      for (final k in pm.keys) {
        if (!_periodKeys.contains(k)) {
          throw LoanFormatException('$f.$k is not a known field');
        }
      }
      final from = _date(pm['from'], '$f.from');
      final rateRaw = pm['ratePct'];
      if (rateRaw is! String || !_ratePattern.hasMatch(rateRaw)) {
        throw LoanFormatException('$f.ratePct must be a decimal string with '
            'at most 4 decimal places, from 0 to 100');
      }
      final rate = Decimal.parse(rateRaw);
      if (rate > Decimal.fromInt(100)) {
        throw LoanFormatException('$f.ratePct must be from 0 to 100');
      }
      final type = _enum(pm, 'type', RateType.values, field: '$f.type') ??
          RateType.fixed;
      if (flat && type != RateType.fixed) {
        throw LoanFormatException('$f.type must be fixed for a flat-rate loan');
      }
      final io = _bool(pm, 'interestOnly', '$f.interestOnly') ?? false;
      if (io && (flat || mode == LoanMode.simple)) {
        throw LoanFormatException('$f.interestOnly is not allowed '
            '${flat ? 'for a flat-rate loan' : 'in simple mode'}');
      }
      final offset = _bool(pm, 'offsetApplies', '$f.offsetApplies') ?? !flat;
      if (flat && offset) {
        throw LoanFormatException(
            '$f.offsetApplies must be false for a flat-rate loan');
      }
      if (periods.isNotEmpty && !from.isAfter(periods.last.from)) {
        throw LoanFormatException(
            '$f.from must be after loan.ratePeriods[${i - 1}].from');
      }
      periods.add(RatePeriod(
        from: from,
        ratePct: rate,
        ratePctText: rateRaw,
        type: type,
        interestOnly: io,
        offsetApplies: offset,
      ));
    }
    return LoanTerms(
      mode: mode,
      interestType: interestType,
      termMonths: term,
      repaymentFrequency: freq,
      firstRepaymentDate: first,
      chargeSchedule: schedule,
      chargeDay: chargeDay,
      dayCount: dayCount,
      ratePeriods: List.unmodifiable(periods),
    );
  }

  /// The rules that need the loan's start (drawdown) date. Throws
  /// [LoanFormatException].
  void validate(DateTime start) {
    final s = civil(start);
    final end = termEnd(s);
    if (ratePeriods.first.from != s) {
      throw LoanFormatException('loan.ratePeriods[0].from must be the loan '
          'start date ${formatLoanDate(s)}');
    }
    for (var i = 0; i < ratePeriods.length; i++) {
      if (!ratePeriods[i].from.isBefore(end)) {
        throw LoanFormatException('loan.ratePeriods[$i].from must be before '
            'the term end ${formatLoanDate(end)}');
      }
    }
    final first = firstRepayment(s);
    final latest = _period(s, 1);
    if (!first.isAfter(s) || first.isAfter(latest) || first.isAfter(end)) {
      throw LoanFormatException('loan.firstRepaymentDate must be after the '
          'start and no later than ${formatLoanDate(latest.isAfter(end) ? end : latest)}');
    }
    if (isFlat && repaymentDates(s, end).isEmpty) {
      throw const LoanFormatException(
          'loan.firstRepaymentDate must be on or before the term end');
    }
  }

  /// `addMonthsRolled(start, termMonths)`.
  DateTime termEnd(DateTime start) => addMonthsRolled(civil(start), termMonths);

  /// The stored first repayment date, else start + one period.
  DateTime firstRepayment(DateTime start) =>
      firstRepaymentDate ?? _period(civil(start), 1);

  DateTime _period(DateTime anchor, int k) => switch (repaymentFrequency) {
        RepaymentFrequency.weekly =>
          DateTime.utc(anchor.year, anchor.month, anchor.day + 7 * k),
        RepaymentFrequency.fortnightly =>
          DateTime.utc(anchor.year, anchor.month, anchor.day + 14 * k),
        RepaymentFrequency.monthly => addMonthsRolled(anchor, k),
      };

  /// The k-th (k ≥ 0) repayment-schedule date `R_k`.
  DateTime repaymentDate(DateTime start, int k) =>
      _period(firstRepayment(start), k);

  /// Repayment-schedule dates `R_k` from the first repayment through [until]
  /// (inclusive).
  List<DateTime> repaymentDates(DateTime start, DateTime until) {
    final out = <DateTime>[];
    final u = civil(until);
    for (var k = 0;; k++) {
      final d = repaymentDate(start, k);
      if (d.isAfter(u)) return out;
      out.add(d);
    }
  }

  /// Whether [d] is a repayment-schedule date (any k ≥ 0, unbounded).
  bool isRepaymentDate(DateTime start, DateTime d) {
    final first = firstRepayment(start);
    final day = civil(d);
    if (day.isBefore(first)) return false;
    switch (repaymentFrequency) {
      case RepaymentFrequency.weekly:
      case RepaymentFrequency.fortnightly:
        final step = repaymentFrequency == RepaymentFrequency.weekly ? 7 : 14;
        return day.difference(first).inDays % step == 0;
      case RepaymentFrequency.monthly:
        final dim = daysInMonth(day.year, day.month);
        return day.day == (first.day > dim ? dim : first.day);
    }
  }

  /// The period in force on [d] (the last with `from ≤ d`); the first
  /// before the loan starts.
  RatePeriod periodOn(DateTime d) {
    final day = civil(d);
    var p = ratePeriods.first;
    for (final r in ratePeriods) {
      if (r.from.isAfter(day)) break;
      p = r;
    }
    return p;
  }

  Decimal rateOn(DateTime d) => periodOn(d).ratePct;

  /// These terms with the first repayment date filled from [start].
  LoanTerms withDefaults(DateTime start) => LoanTerms(
        mode: mode,
        interestType: interestType,
        termMonths: termMonths,
        repaymentFrequency: repaymentFrequency,
        firstRepaymentDate: firstRepayment(start),
        chargeSchedule: chargeSchedule,
        chargeDay: chargeDay,
        dayCount: dayCount,
        ratePeriods: ratePeriods,
      );

  /// Stored form: every field present (call [withDefaults] first so
  /// `firstRepaymentDate` is filled).
  Map<String, Object?> toJson() => {
        'v': 1,
        'mode': mode.name,
        'interestType': interestType.name,
        'termMonths': termMonths,
        'repaymentFrequency': repaymentFrequency.name,
        'firstRepaymentDate': firstRepaymentDate == null
            ? null
            : formatLoanDate(firstRepaymentDate!),
        'chargeSchedule': chargeSchedule.name,
        'chargeDay': chargeDay?.json,
        'dayCount': dayCount.json,
        'ratePeriods': [for (final p in ratePeriods) p.toJson()],
      };

  static T? _enum<T extends Enum>(
    Map<String, Object?> m,
    String key,
    List<T> values, {
    bool required = false,
    String? field,
  }) {
    final name = field ?? 'loan.$key';
    final v = m[key];
    if (v == null) {
      if (required) throw LoanFormatException('$name is required');
      return null;
    }
    for (final e in values) {
      if (e.name == v) return e;
    }
    throw LoanFormatException(
        '$name must be one of ${values.map((e) => e.name).join(', ')}');
  }

  static bool? _bool(Map<String, Object?> m, String key, String field) {
    final v = m[key];
    if (v == null) return null;
    if (v is! bool) throw LoanFormatException('$field must be true or false');
    return v;
  }

  static final _datePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

  static DateTime _date(Object? v, String field) {
    final m = v is String ? _datePattern.firstMatch(v) : null;
    if (m == null) {
      throw LoanFormatException('$field must be a YYYY-MM-DD date');
    }
    final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
    final dt = DateTime.utc(y, mo, d);
    if (dt.month != mo || dt.day != d) {
      throw LoanFormatException('$field must be a real date');
    }
    return dt;
  }
}

String formatLoanDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';
