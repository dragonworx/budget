import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/loans/loan_models.dart';
import 'package:decimal/decimal.dart';

import 'fake_streams.dart';

/// Simple reducing loan terms (spec 002 §4) for tests.
Map<String, dynamic> loanTermsJson({
  String start = '2027-01-15',
  String rate = '5.89',
  String interestType = 'reducing',
  String mode = 'simple',
  int termMonths = 360,
  List<Map<String, dynamic>>? periods,
}) => {
  'v': 1,
  'mode': mode,
  'interestType': interestType,
  'termMonths': termMonths,
  'repaymentFrequency': 'monthly',
  'chargeSchedule': interestType == 'flat' ? 'onRepaymentDates' : 'monthly',
  'chargeDay': interestType == 'flat' ? null : 'anniversary',
  'dayCount': '365',
  'ratePeriods':
      periods ??
      [
        {
          'from': start,
          'ratePct': rate,
          'type': 'fixed',
          'interestOnly': false,
          'offsetApplies': false,
        },
      ],
};

BudgetEvent loanEvent({
  String id = 'loan1',
  String streamId = 'acc',
  String amount = '600000',
  String start = '2027-01-15',
  Map<String, dynamic>? terms,
}) => BudgetEvent.fromJson({
  'id': id,
  'streamId': streamId,
  'name': 'Home loan',
  'direction': 'debit',
  'amount': amount,
  'startDate': start,
  'recurrenceMode': 'once',
  'endMode': 'never',
  'enabled': true,
  'version': 1,
  'kind': 'loan',
  'loan': terms ?? loanTermsJson(start: start),
  'overrides': <Object>[],
});

/// A `/loan-summary` body (spec 002 §8).
Map<String, dynamic> loanSummaryJson({
  String eventId = 'loan1',
  List<String> warnings = const [],
  List<Map<String, dynamic>> transfers = const [],
  String? payoffDate = '2057-01-15',
  Map<String, dynamic>? flat,
}) => {
  'eventId': eventId,
  'principal': '600000.00',
  'startDate': '2027-01-15',
  'termEndDate': '2057-01-15',
  'balanceAt': {'date': '2027-03-01', 'owed': '598765.43'},
  'charges': [
    {
      'date': '2027-02-15',
      'interest': '2902.68',
      'closingBalance': '-600000.00',
      'payout': false,
    },
  ],
  'totalInterest': '679854.21',
  'totalInterestToDate': '2902.68',
  'payoffDate': payoffDate,
  'owedAtTermEnd': '0.00',
  'interestType': flat == null ? 'reducing' : 'flat',
  'chargeSchedule': 'monthly',
  'chargeDay': 'anniversary',
  'repaymentFrequency': 'monthly',
  'firstRepaymentDate': '2027-02-15',
  'nextChargeDate': '2027-03-15',
  'minimumRepayments': [
    {
      'from': '2027-02-15',
      'frequency': 'monthly',
      'amount': '3555.00',
      'reason': 'start',
    },
  ],
  'flat': flat,
  'repaymentTransfers': transfers,
  'warnings': warnings,
};

/// Streams plus a canned loan preview / summary, recording each preview.
class FakeLoanStreamRepository extends FakeStreamRepository {
  FakeLoanStreamRepository({super.streams, this.summary});

  Map<String, dynamic>? summary;
  final previews = <({String streamId, BudgetEvent draft, String? replaces})>[];

  /// A 400 message the next preview fails with.
  String? previewError;

  @override
  Future<LoanSummary?> previewLoan(
    String streamId,
    BudgetEvent draft, {
    String? replacesEventId,
    DateTime? today,
  }) async {
    previews.add((streamId: streamId, draft: draft, replaces: replacesEventId));
    if (previewError case final e?) {
      previewError = null;
      throw ApiException(e, statusCode: 400);
    }
    final s = summary;
    return s == null ? null : LoanSummary.fromJson(s);
  }

  @override
  Future<LoanSummary?> loanSummary(String streamId, {DateTime? from}) async {
    final s = summary;
    return s == null ? null : LoanSummary.fromJson(s);
  }
}

/// In-memory events by stream, recording writes.
class FakeLoanEventRepository extends EventRepository {
  FakeLoanEventRepository(this.byStream) : super(ApiClient());

  final Map<String, List<BudgetEvent>> byStream;
  final calls = <String>[];
  final created = <BudgetEvent>[];
  final updated = <BudgetEvent>[];

  /// A 400 message the next create / update fails with.
  String? saveError;

  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async =>
      List.of(byStream[streamId] ?? const []);

  @override
  Future<BudgetEvent> create(
    String streamId,
    BudgetEvent draft, {
    ({String name, String? color})? newCategory,
  }) async {
    if (saveError case final e?) {
      saveError = null;
      throw ApiException(e, statusCode: 400);
    }
    calls.add('create $streamId ${draft.name} ${draft.amount}');
    final e = draft.copyWith(streamId: streamId, version: 1);
    created.add(e);
    (byStream[streamId] ??= []).add(e);
    return e;
  }

  @override
  Future<BudgetEvent> update(BudgetEvent event, {bool force = false}) async {
    if (saveError case final e?) {
      saveError = null;
      throw ApiException(e, statusCode: 400);
    }
    calls.add('update ${event.id} ${event.amount}');
    updated.add(event);
    final list = byStream[event.streamId] ??= [];
    list.removeWhere((x) => x.id == event.id);
    list.add(event);
    return event;
  }

  @override
  Future<({BudgetEvent original, BudgetEvent? created})> split(
    BudgetEvent edited,
    DateTime date, {
    bool force = false,
  }) async {
    calls.add('split ${edited.id} ${edited.amount} ${formatDate(date)}');
    return (original: edited, created: null);
  }

  @override
  Future<BudgetEvent> setOverride(
    String eventId,
    DateTime date, {
    required EventDirection direction,
    required Decimal amount,
    int? version,
  }) async {
    calls.add('override $eventId ${formatDate(date)} $amount');
    final e = byStream.values
        .expand((l) => l)
        .firstWhere((x) => x.id == eventId);
    return e;
  }
}
