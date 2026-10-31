import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

import '../../data/models.dart';
import '../timeline/zoom_level.dart' show dateOnly;
import 'loan_models.dart';

/// The planner's notice on loan streams (the server answers 409 too).
const loanPlanningMessage = "Planning isn't available for loan streams yet";

/// The stream's alert threshold field helper on loan streams.
const loanThresholdHelper = 'Not used for loan streams';

/// A loan stream: the server's flag, or a loan among [events] (a loan
/// just created, before the stream list refreshes).
bool streamHasLoan(BudgetStream? stream, Iterable<BudgetEvent> events) =>
    (stream?.hasLoan ?? false) || events.any((e) => e.isLoan);

/// Whole dollars when whole ("\$500,000"), else cents.
String _principal(Decimal v) {
  final whole = v == v.truncate();
  return NumberFormat.currency(
    symbol: '\$',
    decimalDigits: whole ? 0 : 2,
  ).format(v.toDouble());
}

/// The loan's rate period on [on] (the first before its start).
RatePeriodDraft? loanRateOn(LoanDraft d, DateTime on) {
  final day = dateOnly(on);
  RatePeriodDraft? hit;
  for (final p in d.periods) {
    if (!p.from.isAfter(day) || hit == null) hit = p;
  }
  return hit;
}

/// "Loan \$500,000 · 6.00%" (the rate on [on], default today), "Loan
/// \$10,000 · 10.00% flat"; null for a non-loan.
String? loanLabel(BudgetEvent t, {DateTime? on}) {
  if (!t.isLoan) return null;
  final d = LoanDraft.fromEvent(t);
  final money = _principal(t.amount);
  if (d == null) return 'Loan $money';
  final p = loanRateOn(d, on ?? DateTime.now());
  final rate = Decimal.tryParse(p?.rate ?? '');
  if (rate == null) return 'Loan $money';
  return 'Loan $money · ${rate.toStringAsFixed(2)}%'
      '${d.isFlat ? ' flat' : ''}';
}

/// A loan's derived interest occurrence, in words ("Interest charged",
/// "Flat interest instalment", "Payout interest", "Remaining flat interest
/// (no rebate)"); null for anything else.
String? derivedOccurrenceName(Occurrence o) {
  if (!o.derived || o.component != 'interest') return null;
  if (o.payout) {
    return o.flat ? 'Remaining flat interest (no rebate)' : 'Payout interest';
  }
  return o.flat ? 'Flat interest instalment' : 'Interest charged';
}

/// Where a loan's lane ends: [payoff] when known, else its term end.
DateTime? loanLaneEnd(BudgetEvent t, {DateTime? payoff}) {
  if (!t.isLoan) return null;
  if (payoff != null) return dateOnly(payoff);
  final d = LoanDraft.fromEvent(t);
  return d == null ? null : dateOnly(d.termEnd);
}
