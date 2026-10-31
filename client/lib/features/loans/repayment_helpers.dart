import 'package:budget_loan/budget_loan.dart';
import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:decimal/decimal.dart';

import '../../data/models.dart';
import '../timeline/occurrence_dates.dart';
import '../timeline/zoom_level.dart';
import 'loan_models.dart';

/// Spec 003 §7 warning actions: the pure parts (drafts, dates), so the
/// summary panel only wires them to the API.

/// The legacy cadence fields of a repayment [f]requency: weekly, every 2
/// weeks, or monthly (on the first repayment's day of month).
({int interval, RecurrenceUnit unit}) repaymentCadence(RepaymentFrequency f) =>
    switch (f) {
      RepaymentFrequency.weekly => (interval: 1, unit: RecurrenceUnit.weeks),
      RepaymentFrequency.fortnightly => (
        interval: 2,
        unit: RecurrenceUnit.weeks,
      ),
      RepaymentFrequency.monthly => (interval: 1, unit: RecurrenceUnit.months),
    };

/// "Set up repayments": a transfer out of [fromStreamId] into the loan's
/// stream [loanStreamId] of [amount] at the loan's frequency from its first
/// repayment. A flat loan's ends after its [count] instalments.
BudgetEvent repaymentTransferDraft({
  required String fromStreamId,
  required String loanStreamId,
  required Decimal amount,
  required RepaymentFrequency frequency,
  required DateTime first,
  String? categoryId,
  String name = 'Loan repayment',
  int? count,
}) {
  final c = repaymentCadence(frequency);
  return BudgetEvent(
    id: '',
    streamId: fromStreamId,
    name: name,
    direction: EventDirection.debit,
    amount: amount,
    startDate: dateOnly(first),
    recurrenceMode: RecurrenceMode.every,
    interval: c.interval,
    unit: c.unit,
    endMode: count == null ? EndMode.never : EndMode.count,
    occurrenceCount: count,
    categoryId: categoryId,
    transfer: TransferLink(peerStreamId: loanStreamId),
  );
}

/// The [count]-th (1-based) occurrence of a repayment schedule from
/// [first] (the flat loan's final instalment date).
DateTime nthRepayment(RepaymentFrequency f, DateTime first, int count) {
  final start = toRuleDate(first);
  final k = count - 1;
  return fromRuleDate(switch (f) {
    RepaymentFrequency.weekly => DateTime.utc(
      start.year,
      start.month,
      start.day + 7 * k,
    ),
    RepaymentFrequency.fortnightly => DateTime.utc(
      start.year,
      start.month,
      start.day + 14 * k,
    ),
    RepaymentFrequency.monthly => addMonthsRolled(start, k),
  });
}

/// The first occurrence of [t] on or after [day] (null: none, e.g. it
/// ended before).
DateTime? firstOccurrenceOnOrAfter(BudgetEvent t, DateTime day) {
  final lo = dateOnly(day);
  final dates = occurrenceDatesIn(t, lo, addMonthsSafe(lo, 15));
  return dates.firstOrNull;
}

DateTime addMonthsSafe(DateTime d, int months) =>
    fromRuleDate(addMonthsRolled(toRuleDate(d), months));

/// The loan repayment frequency a transfer [t] runs at: weekly, every two
/// weeks or monthly with no extra days; null otherwise (then "Match the
/// loan" is not offered).
RepaymentFrequency? loanFrequencyOf(BudgetEvent t) {
  if (t.recurrenceMode != RecurrenceMode.every || t.days.isNotEmpty) {
    return null;
  }
  final f = t.frequency;
  if (f.days.isNotEmpty) return null;
  return switch ((f.rule, f.interval)) {
    (FreqRule.weekly, 1) => RepaymentFrequency.weekly,
    (FreqRule.everyNWeeks, 2) => RepaymentFrequency.fortnightly,
    (FreqRule.monthly, 1) => RepaymentFrequency.monthly,
    _ => null,
  };
}

/// "Match the loan to my repayments": the loan's repayment frequency and
/// first repayment date taken from transfer [t] for a loan starting
/// [loanStart]: the transfer's cadence projected to its first date after
/// the start (within one period, as the terms require). Null when [t]'s
/// frequency has no loan equivalent.
({RepaymentFrequency frequency, DateTime first})? scheduleFromTransfer(
  BudgetEvent t,
  DateTime loanStart,
) {
  final freq = loanFrequencyOf(t);
  if (freq == null) return null;
  final s = dateOnly(loanStart);
  final anchor = dateOnly(t.startDate);
  switch (freq) {
    case RepaymentFrequency.weekly:
    case RepaymentFrequency.fortnightly:
      final step = freq == RepaymentFrequency.weekly ? 7 : 14;
      // The day after the start, moved forward to the transfer's cadence.
      final diff = toRuleDate(anchor)
          .difference(toRuleDate(s.add(const Duration(days: 1))))
          .inDays;
      final offset = ((diff % step) + step) % step;
      return (
        frequency: freq,
        first: DateTime(s.year, s.month, s.day + 1 + offset),
      );
    case RepaymentFrequency.monthly:
      final day = anchor.day;
      for (var m = 0; m <= 1; m++) {
        final month = DateTime(s.year, s.month + m);
        final dim = daysInMonth(month.year, month.month);
        final d = DateTime(month.year, month.month, day > dim ? dim : day);
        if (d.isAfter(s)) return (frequency: freq, first: d);
      }
      return null;
  }
}

/// [draft] with its repayment schedule replaced by [schedule].
Map<String, Object?> loanWithSchedule(
  Map<String, dynamic> loan,
  ({RepaymentFrequency frequency, DateTime first}) schedule,
) => {
  ...loan,
  'repaymentFrequency': schedule.frequency.name,
  'firstRepaymentDate': formatDate(schedule.first),
};

/// The transfer [t] ending on [payoff] (it continued past it).
BudgetEvent endedAt(BudgetEvent t, DateTime payoff) => t.copyWith(
  endMode: EndMode.untilDate,
  endDate: dateOnly(payoff),
  clearOccurrenceCount: true,
);

/// The words for a transfer's frequency: "monthly", "every 2 weeks".
String describeTransferFrequency(LoanRepaymentTransfer t) {
  try {
    final f = Frequency.fromJson(t.frequency);
    return switch ((f.rule, f.interval)) {
      (FreqRule.weekly, _) => 'weekly',
      (FreqRule.everyNWeeks, 2) => 'fortnightly',
      (FreqRule.everyNWeeks, final n) => 'every $n weeks',
      (FreqRule.monthly, _) => 'monthly',
      (FreqRule.everyNMonths, final n) => 'every $n months',
      (FreqRule.daily, 1) => 'daily',
      (FreqRule.daily, final n) => 'every $n days',
      (FreqRule.once, _) => 'once',
    };
  } on FormatException {
    return '';
  }
}
