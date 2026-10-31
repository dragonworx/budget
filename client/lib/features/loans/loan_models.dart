import 'package:budget_loan/budget_loan.dart';
import 'package:budget_recurrence/budget_recurrence.dart' show addMonthsRolled;
import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

import '../../data/models.dart';
import '../timeline/occurrence_dates.dart';
import '../timeline/zoom_level.dart' show dateOnly;

/// Loan money with cents: "\$2,000.00".
String loanMoney(Decimal v) =>
    NumberFormat.currency(symbol: '\$', decimalDigits: 2).format(v.toDouble());

/// A rate as typed ("6.40") shown as "6.40%".
String loanRate(String pct) => '$pct%';

/// "15 Feb 2027".
String loanDate(DateTime d) => DateFormat('d MMM y').format(d);

/// "fortnightly" / "weekly" / "monthly".
String frequencyWord(RepaymentFrequency f) => f.name;

/// "Fortnightly".
String frequencyLabel(RepaymentFrequency f) => switch (f) {
  RepaymentFrequency.weekly => 'Weekly',
  RepaymentFrequency.fortnightly => 'Fortnightly',
  RepaymentFrequency.monthly => 'Monthly',
};

DateTime _local(DateTime utc) => fromRuleDate(utc);
DateTime? _parse(Object? v) => v is String ? parseDate(v) : null;
Decimal? _dec(Object? v) => v == null ? null : Decimal.tryParse('$v');

/// One editable rate period (spec 003 §5): [from] is a client (local)
/// date, [rate] the text as typed.
class RatePeriodDraft {
  RatePeriodDraft({
    required this.from,
    required this.rate,
    this.type = RateType.fixed,
    this.interestOnly = false,
    this.offsetApplies = false,
  });

  DateTime from;
  String rate;
  RateType type;
  bool interestOnly;

  /// Kept as loaded; not editable until offset accounts exist (spec 004).
  bool offsetApplies;

  RatePeriodDraft copy() => RatePeriodDraft(
    from: from,
    rate: rate,
    type: type,
    interestOnly: interestOnly,
    offsetApplies: offsetApplies,
  );

  Map<String, Object?> toJson({required bool flat}) => {
    'from': formatDate(from),
    'ratePct': rate.trim(),
    'type': flat ? 'fixed' : type.name,
    'interestOnly': flat ? false : interestOnly,
    'offsetApplies': flat ? false : offsetApplies,
  };
}

/// The loan editor's state: everything `events.loan` holds plus the
/// drawdown (principal, start). Converts to / from the stored JSON.
class LoanDraft {
  LoanDraft({
    required this.start,
    this.principal = '',
    this.mode = LoanMode.simple,
    this.interestType = InterestType.reducing,
    this.termMonths = 360,
    this.frequency = RepaymentFrequency.monthly,
    this.firstRepayment,
    this.chargeSchedule = ChargeSchedule.monthly,
    this.chargeDay = const AnniversaryChargeDay(),
    this.dayCount = DayCount.d365,
    List<RatePeriodDraft>? periods,
  }) : periods = periods ?? [RatePeriodDraft(from: start, rate: '')];

  /// A new loan starting on [start].
  factory LoanDraft.initial(DateTime start) => LoanDraft(start: start);

  /// The draft of a saved loan [e] (its raw `loan` JSON); null when the
  /// terms don't parse.
  static LoanDraft? fromEvent(BudgetEvent e) {
    final raw = e.loan;
    if (raw == null) return null;
    final LoanTerms t;
    try {
      t = LoanTerms.fromJson(raw);
    } on FormatException {
      return null;
    }
    final start = dateOnly(e.startDate);
    return LoanDraft(
      start: start,
      principal: e.amount.toString(),
      mode: t.mode,
      interestType: t.interestType,
      termMonths: t.termMonths,
      frequency: t.repaymentFrequency,
      firstRepayment: t.firstRepaymentDate == null
          ? null
          : _local(t.firstRepaymentDate!),
      chargeSchedule: t.chargeSchedule,
      chargeDay: t.chargeDay ?? const AnniversaryChargeDay(),
      dayCount: t.dayCount,
      periods: [
        for (final p in t.ratePeriods)
          RatePeriodDraft(
            from: _local(p.from),
            rate: p.ratePctText,
            type: p.type,
            interestOnly: p.interestOnly,
            offsetApplies: p.offsetApplies,
          ),
      ],
    );
  }

  DateTime start;
  String principal;
  LoanMode mode;
  InterestType interestType;
  int termMonths;
  RepaymentFrequency frequency;

  /// Null: the default, one repayment period after [start].
  DateTime? firstRepayment;
  ChargeSchedule chargeSchedule;
  ChargeDay chargeDay;
  DayCount dayCount;
  List<RatePeriodDraft> periods;

  bool get isFlat => interestType == InterestType.flat;
  bool get advanced => mode == LoanMode.advanced;

  LoanDraft copy() => LoanDraft(
    start: start,
    principal: principal,
    mode: mode,
    interestType: interestType,
    termMonths: termMonths,
    frequency: frequency,
    firstRepayment: firstRepayment,
    chargeSchedule: chargeSchedule,
    chargeDay: chargeDay,
    dayCount: dayCount,
    periods: [for (final p in periods) p.copy()],
  );

  /// One period's length after [d].
  DateTime periodAfter(DateTime d) => switch (frequency) {
    RepaymentFrequency.weekly => DateTime(d.year, d.month, d.day + 7),
    RepaymentFrequency.fortnightly => DateTime(d.year, d.month, d.day + 14),
    RepaymentFrequency.monthly => _local(addMonthsRolled(toRuleDate(d), 1)),
  };

  /// The first repayment shown and saved (the default when unset).
  DateTime get effectiveFirstRepayment => firstRepayment ?? periodAfter(start);

  DateTime get termEnd =>
      _local(addMonthsRolled(toRuleDate(start), termMonths));

  /// The charge schedule as the simple line words it: "Interest charged
  /// monthly on the 15th".
  bool get defaultSchedule =>
      chargeSchedule == ChargeSchedule.monthly &&
      chargeDay == const AnniversaryChargeDay() &&
      dayCount == DayCount.d365;

  /// Why Advanced → Simple is not possible now (null: it is).
  String? get simpleBlocker {
    if (periods.length > 1) {
      return 'Simple mode has one rate. Remove the extra rate changes first.';
    }
    if (periods.first.interestOnly) {
      return 'Simple mode has no interest-only period. Turn interest only off '
          'first.';
    }
    if (!defaultSchedule) {
      return 'Simple mode charges interest monthly on the loan anniversary '
          'with a 365-day year. Change those back first.';
    }
    return null;
  }

  /// Rate periods sorted by date, the first pinned to [start].
  void sortPeriods() {
    if (periods.isEmpty) return;
    final first = periods.first;
    final rest = periods.skip(1).toList()
      ..sort((a, b) => a.from.compareTo(b.from));
    periods = [first, ...rest];
    first.from = start;
  }

  /// The stored `loan` JSON (spec 002 schema v1).
  Map<String, Object?> toJson() {
    final flat = isFlat;
    final simple = mode == LoanMode.simple || flat;
    return {
      'v': 1,
      'mode': mode.name,
      'interestType': interestType.name,
      'termMonths': termMonths,
      'repaymentFrequency': frequency.name,
      'firstRepaymentDate': formatDate(effectiveFirstRepayment),
      'chargeSchedule': flat
          ? ChargeSchedule.onRepaymentDates.name
          : simple
          ? ChargeSchedule.monthly.name
          : chargeSchedule.name,
      'chargeDay': flat
          ? null
          : simple
          ? 'anniversary'
          : chargeSchedule == ChargeSchedule.onRepaymentDates
          ? null
          : chargeDay.json,
      'dayCount': flat || simple ? '365' : dayCount.json,
      'ratePeriods': [
        for (final (i, p) in (simple ? periods.take(1) : periods).indexed)
          (i == 0 ? (p.copy()..from = start) : p).toJson(flat: flat)
            ..update('interestOnly', (v) => simple ? false : v),
      ],
    };
  }

  Decimal? get principalValue {
    final v = Decimal.tryParse(principal.trim().replaceAll(',', ''));
    return v == null || v <= Decimal.zero ? null : v;
  }

  /// The parsed, validated terms; throws [FormatException] (the message
  /// names the field, e.g. `loan.ratePeriods[1].from`).
  LoanTerms terms() {
    final t = LoanTerms.fromJson(toJson());
    t.validate(toRuleDate(start));
    return t;
  }

  /// [terms] or null when invalid.
  LoanTerms? get termsOrNull {
    try {
      return terms();
    } on FormatException {
      return null;
    }
  }

  /// The flat plan (null unless flat and valid).
  FlatPlan? get flatPlanOrNull {
    final p = principalValue;
    final t = termsOrNull;
    if (!isFlat || p == null || t == null) return null;
    try {
      return flatPlan(t, p, toRuleDate(start));
    } on Object {
      return null;
    }
  }

  /// The minimum at the start (reducing) / the repayment (flat).
  MinimumRepayment? get startMinimum {
    final p = principalValue;
    final t = termsOrNull;
    if (p == null || t == null) return null;
    try {
      return minimums(t, toRuleDate(start), p, const {}).first;
    } on Object {
      return null;
    }
  }
}

/// A validation message mapped to the editor field it belongs to.
enum LoanField {
  principal,
  start,
  term,
  firstRepayment,
  chargeDay,
  rate,
  rateFrom,
  other,
}

/// Which field (and rate row) [message] is about.
({LoanField field, int? row}) loanErrorField(String message) {
  final row = RegExp(r'ratePeriods\[(\d+)\]').firstMatch(message);
  final i = row == null ? null : int.parse(row.group(1)!);
  if (message.contains('.from')) return (field: LoanField.rateFrom, row: i);
  if (message.contains('ratePct')) return (field: LoanField.rate, row: i);
  if (message.contains('termMonths')) return (field: LoanField.term, row: null);
  if (message.contains('firstRepaymentDate')) {
    return (field: LoanField.firstRepayment, row: null);
  }
  if (message.contains('chargeDay')) {
    return (field: LoanField.chargeDay, row: null);
  }
  if (message.contains('amount')) {
    return (field: LoanField.principal, row: null);
  }
  return (field: LoanField.other, row: i);
}

/// Turns an engine message into words for the form ("loan.ratePeriods[1]
/// .from must be after …" → "Must be after …").
String friendlyLoanError(String message) {
  final m = RegExp(r'^loan\.[A-Za-z]+(\[\d+\])?(\.[A-Za-z]+)? ')
      .firstMatch(message);
  var t = m == null ? message : message.substring(m.end);
  t = t.replaceAllMapped(
    RegExp(r'(\d{4})-(\d{2})-(\d{2})'),
    (d) => loanDate(
      DateTime(
        int.parse(d.group(1)!),
        int.parse(d.group(2)!),
        int.parse(d.group(3)!),
      ),
    ),
  );
  t = t.replaceAll(
    RegExp(r'loan\.ratePeriods\[(\d+)\]\.from'),
    'the previous '
    'rate change',
  );
  return t.isEmpty ? message : '${t[0].toUpperCase()}${t.substring(1)}';
}

class LoanCharge {
  const LoanCharge({
    required this.date,
    required this.interest,
    required this.closingBalance,
    this.payout = false,
  });
  final DateTime date;
  final Decimal interest;
  final Decimal closingBalance;
  final bool payout;
}

class LoanMinimum {
  const LoanMinimum({
    required this.from,
    required this.frequency,
    required this.amount,
    required this.reason,
    this.finalRepayment,
  });
  final DateTime from;
  final RepaymentFrequency frequency;
  final Decimal amount;

  /// start, rateChange or interestOnlyEnd.
  final String reason;
  final Decimal? finalRepayment;
}

class LoanFlat {
  const LoanFlat({
    required this.totalInterest,
    required this.instalments,
    required this.instalmentInterest,
    required this.lastInstalmentInterest,
    required this.repayment,
    required this.finalRepayment,
    required this.equivalentReducingRatePct,
  });
  final Decimal totalInterest;
  final int instalments;
  final Decimal instalmentInterest;
  final Decimal lastInstalmentInterest;
  final Decimal repayment;
  final Decimal finalRepayment;
  final Decimal equivalentReducingRatePct;
}

class LoanRepaymentTransfer {
  const LoanRepaymentTransfer({
    required this.eventId,
    required this.peerStreamId,
    required this.amount,
    required this.frequency,
  });
  final String eventId;
  final String peerStreamId;
  final Decimal amount;

  /// The transfer's frequency JSON (rule, interval, days).
  final Map<String, dynamic> frequency;
}

/// `GET /streams/:id/loan-summary` (spec 002 §8), also returned by
/// `POST /project` with `loanSummaryFrom` for an unsaved loan.
class LoanSummary {
  const LoanSummary({
    required this.eventId,
    required this.principal,
    required this.startDate,
    required this.termEndDate,
    required this.owedAt,
    required this.owed,
    required this.charges,
    required this.totalInterest,
    required this.totalInterestToDate,
    required this.payoffDate,
    required this.owedAtTermEnd,
    required this.interestType,
    required this.chargeSchedule,
    required this.chargeDay,
    required this.repaymentFrequency,
    required this.firstRepaymentDate,
    required this.nextChargeDate,
    required this.minimums,
    required this.flat,
    required this.transfers,
    required this.warnings,
  });

  factory LoanSummary.fromJson(Map<String, dynamic> j) {
    final at = (j['balanceAt'] as Map?)?.cast<String, dynamic>() ?? const {};
    final flat = (j['flat'] as Map?)?.cast<String, dynamic>();
    RepaymentFrequency freq(Object? v) => RepaymentFrequency.values.firstWhere(
      (f) => f.name == v,
      orElse: () => RepaymentFrequency.monthly,
    );
    return LoanSummary(
      eventId: j['eventId'] as String,
      principal: _dec(j['principal']) ?? Decimal.zero,
      startDate: _parse(j['startDate'])!,
      termEndDate: _parse(j['termEndDate'])!,
      owedAt: _parse(at['date']),
      owed: _dec(at['owed']) ?? Decimal.zero,
      charges: [
        for (final c in (j['charges'] as List? ?? const []).cast<Map>())
          LoanCharge(
            date: _parse(c['date'])!,
            interest: _dec(c['interest']) ?? Decimal.zero,
            closingBalance: _dec(c['closingBalance']) ?? Decimal.zero,
            payout: c['payout'] == true,
          ),
      ],
      totalInterest: _dec(j['totalInterest']) ?? Decimal.zero,
      totalInterestToDate: _dec(j['totalInterestToDate']) ?? Decimal.zero,
      payoffDate: _parse(j['payoffDate']),
      owedAtTermEnd: _dec(j['owedAtTermEnd']),
      interestType: j['interestType'] == 'flat'
          ? InterestType.flat
          : InterestType.reducing,
      chargeSchedule: j['chargeSchedule'] == 'onRepaymentDates'
          ? ChargeSchedule.onRepaymentDates
          : ChargeSchedule.monthly,
      chargeDay: j['chargeDay'],
      repaymentFrequency: freq(j['repaymentFrequency']),
      firstRepaymentDate: _parse(j['firstRepaymentDate']),
      nextChargeDate: _parse(j['nextChargeDate']),
      minimums: [
        for (final m
            in (j['minimumRepayments'] as List? ?? const []).cast<Map>())
          LoanMinimum(
            from: _parse(m['from'])!,
            frequency: freq(m['frequency']),
            amount: _dec(m['amount']) ?? Decimal.zero,
            reason: (m['reason'] as String?) ?? 'start',
            finalRepayment: _dec(m['finalRepayment']),
          ),
      ],
      flat: flat == null
          ? null
          : LoanFlat(
              totalInterest: _dec(flat['totalInterest']) ?? Decimal.zero,
              instalments: (flat['instalments'] as num?)?.toInt() ?? 0,
              instalmentInterest:
                  _dec(flat['instalmentInterest']) ?? Decimal.zero,
              lastInstalmentInterest:
                  _dec(flat['lastInstalmentInterest']) ?? Decimal.zero,
              repayment: _dec(flat['repayment']) ?? Decimal.zero,
              finalRepayment: _dec(flat['finalRepayment']) ?? Decimal.zero,
              equivalentReducingRatePct:
                  _dec(flat['equivalentReducingRatePct']) ?? Decimal.zero,
            ),
      transfers: [
        for (final t
            in (j['repaymentTransfers'] as List? ?? const []).cast<Map>())
          LoanRepaymentTransfer(
            eventId: t['eventId'] as String,
            peerStreamId: t['peerStreamId'] as String,
            amount: _dec(t['amount']) ?? Decimal.zero,
            frequency:
                (t['frequency'] as Map?)?.cast<String, dynamic>() ?? const {},
          ),
      ],
      warnings: [for (final w in (j['warnings'] as List? ?? const [])) '$w'],
    );
  }

  final String eventId;
  final Decimal principal;
  final DateTime startDate;
  final DateTime termEndDate;
  final DateTime? owedAt;

  /// Positive: what is still owed on [owedAt].
  final Decimal owed;
  final List<LoanCharge> charges;
  final Decimal totalInterest;
  final Decimal totalInterestToDate;
  final DateTime? payoffDate;

  /// Owed at term end (negative: overpaid); null when not reached.
  final Decimal? owedAtTermEnd;
  final InterestType interestType;
  final ChargeSchedule chargeSchedule;
  final Object? chargeDay;
  final RepaymentFrequency repaymentFrequency;
  final DateTime? firstRepaymentDate;
  final DateTime? nextChargeDate;
  final List<LoanMinimum> minimums;
  final LoanFlat? flat;
  final List<LoanRepaymentTransfer> transfers;

  /// notPaidByTermEnd, repaymentsContinueAfterPayoff, belowMinimum,
  /// repaymentScheduleMismatch.
  final List<String> warnings;

  bool get isFlat => interestType == InterestType.flat;
  bool has(String warning) => warnings.contains(warning);

  /// The interest charged in [month]'s calendar month.
  Decimal interestInMonth(DateTime month) => charges
      .where((c) => c.date.year == month.year && c.date.month == month.month)
      .fold(Decimal.zero, (a, c) => a + c.interest);
}
