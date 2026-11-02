import '../domain/enums.dart';

/// The 400 message for event operations and fields a sync does not
/// support (spec 015 S9).
const syncNotAvailable = 'Not available for a sync';

/// A sync's forced category (S6): the trigger maps the name to the owner's
/// "Sync" category, creating it with [syncCategoryColor] on first use.
const syncCategoryName = 'Sync';
const syncCategoryColor = '#5AA9A3';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "3 Mar 2027".
String dayMonthYear(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

/// The kind a body names, leniently (formula prep runs before the strict
/// [EventKind.parse] in `parseCreateKind`).
EventKind kindOfBody(Map<String, dynamic> body) => switch (body['kind']) {
      'loan' => EventKind.loan,
      'sync' => EventKind.sync,
      _ => EventKind.standard,
    };

bool _nonEmptyList(Object? v) => v is List && v.isNotEmpty;

/// Checks a sync create (or preview) body and normalises it in place:
/// direction "credit", category "Sync". A sync is a once-off with no
/// transfer, loan, offsets, skips, end or category of its own. Throws
/// [FormatException] (a 400).
void prepareSyncCreate(Map<String, dynamic> body) {
  final freq = body['frequency'];
  final bad = (body['direction'] != null && body['direction'] != 'credit') ||
      body['transferToStreamId'] != null ||
      body['loan'] != null ||
      _nonEmptyList(body['offsetStreamIds']) ||
      _nonEmptyList(body['skippedDates']) ||
      (body['recurrenceMode'] != null && body['recurrenceMode'] != 'once') ||
      (freq != null &&
          (freq is! Map || (freq['rule'] != null && freq['rule'] != 'once'))) ||
      body['interval'] != null ||
      body['unit'] != null ||
      _nonEmptyList(body['days']) ||
      (body['endMode'] != null && body['endMode'] != 'never') ||
      body['endDate'] != null ||
      body['occurrenceCount'] != null;
  if (bad) throw const FormatException(syncNotAvailable);
  if (body['amount'] == null) {
    throw const FormatException('A sync needs an actual balance');
  }
  body
    ..['direction'] = 'credit'
    ..['name'] = syncCategoryName
    ..['color'] = syncCategoryColor
    ..remove('categoryId')
    ..remove('newCategory')
    ..remove('frequency')
    ..remove('recurrenceMode')
    ..remove('endMode');
}

/// S7: a sync on or after the stream's seed date.
void checkSyncDate(DateTime date, DateTime seed) {
  if (date.isBefore(DateTime.utc(seed.year, seed.month, seed.day))) {
    throw FormatException("A sync must be on or after the stream's start date "
        '(${dayMonthYear(seed)})');
  }
}

/// Keys a sync PATCH may carry. Others are refused unless they restate
/// the sync's fixed shape (an editor sending its full form).
const _syncPatchKeys = {
  'startDate',
  'amount',
  'amountExpr',
  'enabled',
  'kind',
  'version',
};

/// A sync PATCH (S9, S13): only the date, amount (or its formula) and
/// enabled change. Throws [FormatException] (a 400).
void checkSyncPatch(Map<String, dynamic> body) {
  for (final MapEntry(:key, :value) in body.entries) {
    if (_syncPatchKeys.contains(key)) continue;
    final same = switch (key) {
      'name' => value == syncCategoryName,
      'direction' => value == 'credit',
      'recurrenceMode' => value == 'once',
      'endMode' => value == 'never',
      'frequency' => value is Map && (value['rule'] ?? 'once') == 'once',
      'endDate' ||
      'occurrenceCount' ||
      'interval' ||
      'unit' ||
      'transferToStreamId' =>
        value == null,
      'days' ||
      'offsetStreamIds' =>
        value == null || value is List && value.isEmpty,
      _ => false,
    };
    if (!same) throw const FormatException(syncNotAvailable);
  }
  if (body.containsKey('amount') && body['amount'] == null) {
    throw const FormatException('A sync needs an actual balance');
  }
  // The fixed shape is never rewritten (nor its interval_expr cleared).
  for (final k in body.keys.toList()) {
    if (!_syncPatchKeys.contains(k)) body.remove(k);
  }
}
