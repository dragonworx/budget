import 'package:budget_loan/budget_loan.dart';
import 'package:decimal/decimal.dart';

import '../domain/enums.dart';
import '../domain/models.dart';
import 'events.dart';

/// The 400 message for event operations a loan does not support.
const loanNotSupported = 'not supported for a loan';

/// The 409 message when a stream already holds its one loan.
const streamHasLoan = 'stream already has a loan';

/// Parses `loan` terms and checks them against [start]; returns them with
/// defaults (firstRepaymentDate) filled, ready to store.
LoanTerms parseLoanTerms(Object? raw, DateTime start) {
  if (raw == null) throw const FormatException('a loan needs loan terms');
  final terms = LoanTerms.fromJson(raw)..validate(start);
  return terms.withDefaults(start);
}

/// The kind and loan terms of a create body. A loan defaults to a debit,
/// must be a positive once-off, and may not be a transfer or carry skips.
/// Mutates [body] to default `direction` to "debit" for loans (call before
/// [parseEventBody]). Throws [FormatException] (a 400).
({EventKind kind, LoanTerms? Function(ParsedEventBody) terms}) parseCreateKind(
    Map<String, dynamic> body) {
  final rawKind = body['kind'];
  if (rawKind != null && rawKind is! String) {
    throw const FormatException('kind must be standard or loan');
  }
  final kind = EventKind.parse((rawKind as String?) ?? 'standard');
  if (kind == EventKind.standard) {
    if (body['loan'] != null) {
      throw const FormatException('loan terms need kind "loan"');
    }
    return (kind: kind, terms: (_) => null);
  }
  body['direction'] ??= 'debit';
  if (body['transferToStreamId'] != null) {
    throw const FormatException('a loan cannot be a transfer');
  }
  final skips = body['skippedDates'];
  if (skips is List && skips.isNotEmpty) {
    throw const FormatException('skipped dates are $loanNotSupported');
  }
  return (
    kind: kind,
    terms: (p) {
      checkLoanShape(p.direction, p.recurrenceMode, p.amount);
      return parseLoanTerms(body['loan'], p.startDate);
    },
  );
}

/// A loan is a once-off debit drawdown of a positive amount.
void checkLoanShape(Direction direction, RecurrenceMode mode, Decimal amount) {
  if (direction != Direction.debit) {
    throw const FormatException('a loan is a debit');
  }
  if (mode != RecurrenceMode.once) {
    throw const FormatException('a loan is a once-off event');
  }
  if (amount <= Decimal.zero) {
    throw const FormatException('a loan amount must be more than zero');
  }
}

/// Validates a PATCH body against [existing]: the kind cannot change, a
/// standard event takes no loan terms, and a loan keeps its direction,
/// once-off frequency, end and transfer fields. Returns the loan terms to
/// store (null = unchanged). Throws [FormatException] (a 400).
LoanTerms? parsePatchLoan(Map<String, dynamic> body, BudgetEvent existing) {
  if (body.containsKey('kind') && body['kind'] != existing.kind.name) {
    throw const FormatException('kind cannot change');
  }
  if (!existing.isLoan) {
    if (body['loan'] != null) {
      throw const FormatException('loan terms need kind "loan"');
    }
    return null;
  }
  if (body.containsKey('direction') && body['direction'] != 'debit') {
    throw const FormatException('a loan is a debit');
  }
  final mode = body['recurrenceMode'];
  final freq = body['frequency'];
  if ((mode != null && mode != 'once') ||
      (freq is Map && freq['rule'] != null && freq['rule'] != 'once') ||
      (freq != null && freq is! Map) ||
      body['interval'] != null ||
      body['unit'] != null ||
      (body['days'] is List && (body['days'] as List).isNotEmpty)) {
    throw const FormatException('a loan is a once-off event');
  }
  if ((body['endMode'] != null && body['endMode'] != 'never') ||
      body['endDate'] != null ||
      body['occurrenceCount'] != null) {
    throw const FormatException('end fields are $loanNotSupported');
  }
  if (body['transferToStreamId'] != null) {
    throw const FormatException('a loan cannot be a transfer');
  }
  if (body.containsKey('amount')) {
    checkLoanShape(
        Direction.debit, RecurrenceMode.once, parseDecimal(body['amount']));
  }
  final start = body['startDate'] == null
      ? existing.startDate
      : parseDate(body['startDate'].toString());
  if (body['loan'] != null) return parseLoanTerms(body['loan'], start);
  if (start != existing.startDate) {
    // The stored terms must still fit the new start (ratePeriods[0].from).
    existing.loan!.validate(start);
  }
  return null;
}

/// Spec 002 §8: the planner does not model loans yet.
const planningNotSupported = "Planning isn't available for loan streams yet";
