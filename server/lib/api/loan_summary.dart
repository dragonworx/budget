import 'package:budget_loan/budget_loan.dart';
import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../domain/enums.dart';
import '../domain/models.dart';
import '../engine/loan_walk.dart';
import '../engine/occurrence_gen.dart';
import '../repo/event_repo.dart';
import '../repo/stream_repo.dart';
import 'balance.dart' show maxBalanceRangeDays;
import 'json_helpers.dart';

String _money(Decimal v) => v.toStringAsFixed(2);

/// Occurrences a year of [f] (for monthly normalisation).
double _perYear(Frequency f) {
  final k = f.days.isEmpty ? 1 : f.days.length;
  return switch (f.rule) {
    FreqRule.once => 0,
    FreqRule.daily => 365 / f.interval,
    FreqRule.weekly || FreqRule.everyNWeeks => 52 * k / f.interval,
    FreqRule.monthly || FreqRule.everyNMonths => 12 * k / f.interval,
  };
}

/// Whether [f] repeats at the loan's [freq].
bool _sameFrequency(Frequency f, RepaymentFrequency freq) {
  if (f.days.length > 1) return false;
  return switch (freq) {
    RepaymentFrequency.weekly => (f.rule == FreqRule.weekly) ||
        (f.rule == FreqRule.daily && f.interval == 7),
    RepaymentFrequency.fortnightly => (f.rule.weekFamily && f.interval == 2) ||
        (f.rule == FreqRule.daily && f.interval == 14),
    RepaymentFrequency.monthly => f.rule == FreqRule.monthly,
  };
}

/// The loan summary of a stream (spec 002, `GET /<id>/loan-summary`).
/// Walks from the seed to max(term end, [from]) + 10 years (capped by
/// [maxBalanceRangeDays]); null when the stream has no loan.
Map<String, Object?>? loanSummary({
  required BudgetStream stream,
  required List<BudgetEvent> events,
  required Map<String, Set<DateTime>> skipped,
  required DateTime from,
}) {
  final loan = events.where((e) => e.isLoan && e.loan != null).firstOrNull;
  if (loan == null) return null;
  final terms = loan.loan!;
  final start = civil(loan.startDate);
  final termEnd = terms.termEnd(start);
  final seed = civil(stream.seedDate);
  final base = from.isAfter(termEnd) ? from : termEnd;
  var end = addMonthsRolled(base, 120);
  final cap = seed.add(const Duration(days: maxBalanceRangeDays));
  if (end.isAfter(cap)) end = cap;
  final walk = LoanWalk.compute(
    seedBalance: stream.seedBalance,
    seedDate: seed,
    events: events,
    eventOrder: stream.eventOrder,
    from: seed,
    to: end,
    loan: loan,
    skipped: skipped,
  );
  final closes = {
    for (final p in walk.series.points) p.date: p.closingBalance,
  };
  Decimal owedOn(DateTime d) {
    final c = closes[d];
    return c == null || c >= Decimal.zero ? Decimal.zero : -c;
  }

  final total = walk.charges.fold(Decimal.zero, (a, c) => a + c.amount);
  final toDate = walk.charges
      .where((c) => !c.date.isAfter(from))
      .fold(Decimal.zero, (a, c) => a + c.amount);
  final next = walk.charges.where((c) => c.date.isAfter(from)).firstOrNull;
  final closeAtEnd = closes[termEnd];
  final owedAtTermEnd = closeAtEnd == null ? null : -closeAtEnd;
  final mins = minimums(terms, start, loan.amount, walk.owedAtBoundary);

  final transfers = [
    for (final e in events)
      if (e.transfer != null && e.direction == Direction.credit && e.active) e
  ];

  // Warnings.
  final warnings = <String>[];
  if (owedAtTermEnd != null && owedAtTermEnd > Decimal.zero) {
    warnings.add('notPaidByTermEnd');
  }
  final payoff = walk.payoffDate;
  if (payoff != null &&
      end.isAfter(payoff) &&
      OccurrenceGenerator.generate(
        events: transfers,
        from: payoff.add(const Duration(days: 1)),
        to: end,
        skipped: skipped,
      ).any((o) => !o.skipped)) {
    warnings.add('repaymentsContinueAfterPayoff');
  }
  // The minimum in effect at max(from, start), against what the transfers
  // still running then pay a month (both normalised by occurrences a year).
  final at = from.isBefore(start) ? start : from;
  final current =
      mins.lastWhere((m) => !m.from.isAfter(at), orElse: () => mins.first);
  double monthlyOf(Decimal amount, RepaymentFrequency f) =>
      amount.toDouble() * f.perYear / 12;
  var paidMonthly = 0.0;
  for (final t in transfers) {
    final running = OccurrenceGenerator.generate(
      events: [t],
      from: at,
      to: end,
      skipped: skipped,
    ).isNotEmpty;
    if (running) {
      paidMonthly += t.amount.toDouble() * _perYear(t.frequency) / 12;
    }
  }
  if (transfers.isNotEmpty &&
      paidMonthly + 0.005 < monthlyOf(current.amount, current.frequency)) {
    warnings.add('belowMinimum');
  }
  final firstRepayment = terms.firstRepayment(start);
  final matches = transfers.any((t) =>
      _sameFrequency(t.frequency, terms.repaymentFrequency) &&
      OccurrenceGenerator.generate(
        events: [t],
        from: firstRepayment,
        to: firstRepayment,
      ).isNotEmpty);
  if (!matches) warnings.add('repaymentScheduleMismatch');

  final plan = walk.accrual.flat;
  return {
    'eventId': loan.id,
    'principal': _money(loan.amount),
    'startDate': formatDate(start),
    'termEndDate': formatDate(termEnd),
    'balanceAt': {'date': formatDate(from), 'owed': _money(owedOn(from))},
    'charges': [
      for (final c in walk.charges)
        {
          'date': formatDate(c.date),
          'interest': _money(c.amount),
          'closingBalance': _money(c.closingBalance),
          'payout': c.payout,
        }
    ],
    'totalInterest': _money(total),
    'totalInterestToDate': _money(toDate),
    'payoffDate': payoff == null ? null : formatDate(payoff),
    'owedAtTermEnd': owedAtTermEnd == null ? null : _money(owedAtTermEnd),
    'interestType': terms.interestType.name,
    'chargeSchedule': terms.chargeSchedule.name,
    'chargeDay': terms.chargeDay?.json,
    'repaymentFrequency': terms.repaymentFrequency.name,
    'firstRepaymentDate': formatDate(firstRepayment),
    'nextChargeDate': next == null ? null : formatDate(next.date),
    'minimumRepayments': [for (final m in mins) m.toJson()],
    'flat': plan == null
        ? null
        : {
            'totalInterest': _money(plan.totalInterest),
            'instalments': plan.dates.length,
            'instalmentInterest': _money(plan.instalments.first),
            'lastInstalmentInterest': _money(plan.instalments.last),
            'repayment': _money(plan.repayment),
            'finalRepayment': _money(plan.finalRepayment),
            'equivalentReducingRatePct': equivalentReducingRate(loan.amount,
                    plan.repayment, plan.dates.length, terms.repaymentFrequency)
                .toStringAsFixed(2),
          },
    'repaymentTransfers': [
      for (final t in transfers)
        {
          'eventId': t.id,
          'peerStreamId': t.transfer!.peerStreamId,
          'amount': _money(t.amount),
          'frequency': t.frequency.toJson(),
        }
    ],
    'warnings': warnings,
  };
}

/// Registers `GET /<id>/loan-summary?from=YYYY-MM-DD` (viewer).
void attachLoanSummaryRoute(Router router, Session conn) {
  final streams = StreamRepo(conn);
  final events = EventRepo(conn);
  router.get('/<id>/loan-summary', (Request request, String id) async {
    try {
      final stream = await streams.get(id);
      if (stream == null) return jsonError(404, 'stream not found');
      if (!stream.hasLoan) return jsonError(404, 'stream has no loan');
      final q = request.url.queryParameters['from'];
      final now = DateTime.now().toUtc();
      final from = q == null ? civil(now) : parseDate(q);
      final out = loanSummary(
        stream: stream,
        events: await events.listByStream(id),
        skipped: await events.skipsForStream(id),
        from: from,
      );
      if (out == null) return jsonError(404, 'stream has no loan');
      return jsonOk(out);
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on ArgumentError catch (e) {
      return jsonError(400, e.message.toString());
    }
  });
}
