import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

import '../../data/models.dart';
import '../../widgets/money_text.dart';

/// Spec 015 texts shared by the editor, the events list and the chart.

final _cents = NumberFormat.currency(symbol: moneySymbol, decimalDigits: 2);

/// A sync's actual balance: "\$1,234.56", "−\$1,234.56".
String formatSyncBalance(Decimal v) {
  final d = v.toDouble();
  final text = _cents.format(d.abs());
  return d < 0 ? '−$text' : text;
}

/// A drift: "+\$12.34", "−\$12.34", "\$0.00".
String formatDrift(Decimal v) {
  final d = v.toDouble();
  final text = _cents.format(d.abs());
  if (d == 0) return text;
  return '${d < 0 ? '−' : '+'}$text';
}

/// "+\$12.34 drift".
String driftLabel(Decimal v) => '${formatDrift(v)} drift';

/// "Sync \$1,234.56".
String syncLabel(Decimal balance) => 'Sync ${formatSyncBalance(balance)}';

/// "Calculated: \$1,222.22 · Drift +\$12.34".
String calculatedLine(Decimal calculated, Decimal balance) =>
    'Calculated: ${formatSyncBalance(calculated)} · '
    'Drift ${formatDrift(balance - calculated)}';

/// The editor's warning about other syncs on the same day, from the
/// `/project` records of that day ([self] is the draft's record).
String? sameDaySyncNote(SyncRecord self, List<SyncRecord> sameDay) {
  if (self.beforeSeed) return null;
  if (self.superseded) {
    return 'Another sync on this day comes later in your list, so this one '
        'will be overridden.';
  }
  final earlier = sameDay
      .where((r) => r.eventId != self.eventId && r.superseded)
      .length;
  if (earlier == 0) return null;
  return 'Overrides $earlier earlier sync${earlier == 1 ? '' : 's'} on this '
      'day.';
}

/// S8: a sync dated after today.
const futureSyncHint =
    'This date is in the future: a sync records a balance your bank '
    'already shows.';

const syncBalanceHint = 'Balance shown by your bank at the end of this day';

/// An events-list sync row's second line ([date] already formatted).
String syncRowDetail(String date, SyncRecord? r) {
  if (r?.beforeSeed ?? false) return 'Before start date – has no effect';
  if (r?.superseded ?? false) return 'This sync is overridden by a later one';
  return '$date · Actual balance';
}
