import 'package:budget_loan/budget_loan.dart';
import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:decimal/decimal.dart';

import 'enums.dart';

class BudgetStream {
  BudgetStream({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.seedBalance,
    required this.seedDate,
    required this.lossThreshold,
    required this.displayOrder,
    required this.eventOrder,
    this.currencyScale = defaultCurrencyScale,
    this.version = 1,
    this.hasLoan = false,
  });

  final int version;

  /// The stream holds a loan event (enabled or not; migration 026).
  final bool hasLoan;

  /// Allowed y-axis units (currency units per grid step).
  static const currencyScales = [1, 10, 100, 1000, 10000, 100000, 1000000];
  static const defaultCurrencyScale = 100;

  final String id;

  /// The user who owns the stream (streams are top level).
  final String ownerId;
  final String name;
  final Decimal seedBalance;
  final DateTime seedDate;
  final Decimal lossThreshold;
  final int displayOrder;
  final List<String> eventOrder;
  final int currencyScale;

  Map<String, Object?> toJson() => {
        'id': id,
        'ownerId': ownerId,
        'currencyScale': currencyScale,
        'name': name,
        'seedBalance': seedBalance.toString(),
        'seedDate': formatDate(seedDate),
        'lossThreshold': lossThreshold.toString(),
        'displayOrder': displayOrder,
        'eventOrder': eventOrder,
        'version': version,
        'hasLoan': hasLoan,
      };
}

class BudgetEvent {
  BudgetEvent({
    required this.id,
    required this.streamId,
    required this.name,
    required this.direction,
    required this.amount,
    required this.startDate,
    required this.recurrenceMode,
    this.interval,
    this.unit,
    required this.endMode,
    this.endDate,
    this.occurrenceCount,
    required this.enabled,
    required this.createdAt,
    this.transfer,
    this.version = 1,
    this.overrides = const {},
    this.color,
    this.days = const [],
    this.categoryId,
    this.categoryHidden = false,
    this.kind = EventKind.standard,
    this.loan,
    this.offsetStreamIds = const [],
  });

  final int version;

  /// A loan's offset streams (spec 004, migration 027; at most one now):
  /// their balance above their alert threshold reduces the interest base.
  /// Always empty for a standard event.
  final List<String> offsetStreamIds;

  /// [EventKind.loan]: a once-off debit drawdown with [loan] terms.
  final EventKind kind;

  /// The loan terms (defaults filled) when [kind] is [EventKind.loan].
  final LoanTerms? loan;

  bool get isLoan => kind == EventKind.loan;

  /// The event's category (every stored event has one; previews have none).
  /// [name] is the category's name and [color] its colour.
  final String? categoryId;

  /// The category is hidden: the event counts like a disabled one (no
  /// occurrences, no balance effect) while its own [enabled] is kept.
  final bool categoryHidden;

  /// Counts on the timeline and in the balance.
  bool get active => enabled && !categoryHidden;

  /// The rule's days (sorted, unique): weekdays 1 (Mon) – 7 (Sun) for the
  /// week rules, month days 1–31 for the month rules; empty = the plain
  /// cadence from the start date.
  final List<int> days;

  /// The structured rule (rule, interval, days) this event fires on; the
  /// legacy (recurrenceMode, interval, unit) fields are its cadence view
  /// (years read as 12·N months).
  Frequency get frequency => Frequency.fromLegacy(
        once: recurrenceMode == RecurrenceMode.once,
        interval: interval,
        unit: unit?.name,
        days: days,
      );

  /// The event's colour as "#RRGGBB" (its timeline lane); null = the
  /// client's positional palette colour.
  final String? color;

  /// Once-off overrides of single occurrences (date-only UTC keys).
  final Map<DateTime, AmountOverride> overrides;

  /// Signed amount of the occurrence on [date]: its override, else the
  /// series amount.
  Decimal signedAmountOn(DateTime date) {
    final o = overrides[DateTime.utc(date.year, date.month, date.day)];
    return o == null ? signedAmount : o.signed;
  }

  final String id;
  final String streamId;
  final String name;
  final Direction direction;
  final Decimal amount;
  final DateTime startDate;
  final RecurrenceMode recurrenceMode;
  final int? interval;
  final RecurrenceUnit? unit;
  final EndMode endMode;
  final DateTime? endDate;
  final int? occurrenceCount;
  final bool enabled;
  final DateTime createdAt;

  /// Set when this row is one side of a transfer (linked pair).
  final TransferLink? transfer;

  Decimal get signedAmount => direction == Direction.credit ? amount : -amount;

  Map<String, Object?> toJson() => {
        'id': id,
        'streamId': streamId,
        'name': name,
        'direction': direction.name,
        'amount': amount.toString(),
        'startDate': formatDate(startDate),
        'recurrenceMode': recurrenceMode.name,
        'interval': interval,
        'unit': unit?.name,
        'frequency': frequency.toJson(),
        'days': frequency.days,
        'endMode': endMode.apiName,
        'endDate': endDate == null ? null : formatDate(endDate!),
        'occurrenceCount': occurrenceCount,
        'enabled': enabled,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'transfer': transfer?.toJson(),
        'color': color,
        'categoryId': categoryId,
        'categoryHidden': categoryHidden,
        'version': version,
        'kind': kind.name,
        'loan': loan?.toJson(),
        // Loans only, so a standard event's JSON is unchanged.
        if (isLoan) 'offsetStreamIds': offsetStreamIds,
        'overrides': [
          for (final e
              in (overrides.entries.toList()
                ..sort((a, b) => a.key.compareTo(b.key))))
            {'date': formatDate(e.key), ...e.value.toJson()},
        ],
      };

  BudgetEvent copyWith({
    String? id,
    String? streamId,
    String? name,
    Direction? direction,
    Decimal? amount,
    DateTime? startDate,
    RecurrenceMode? recurrenceMode,
    int? interval,
    RecurrenceUnit? unit,
    EndMode? endMode,
    DateTime? endDate,
    int? occurrenceCount,
    bool? enabled,
    DateTime? createdAt,
    bool clearInterval = false,
    bool clearUnit = false,
    bool clearEndDate = false,
    bool clearOccurrenceCount = false,
    String? color,
    bool clearColor = false,
    List<int>? days,
  }) {
    return BudgetEvent(
      days: days ?? this.days,
      color: clearColor ? null : (color ?? this.color),
      id: id ?? this.id,
      streamId: streamId ?? this.streamId,
      name: name ?? this.name,
      direction: direction ?? this.direction,
      amount: amount ?? this.amount,
      startDate: startDate ?? this.startDate,
      recurrenceMode: recurrenceMode ?? this.recurrenceMode,
      interval: clearInterval ? null : (interval ?? this.interval),
      unit: clearUnit ? null : (unit ?? this.unit),
      endMode: endMode ?? this.endMode,
      endDate: clearEndDate ? null : (endDate ?? this.endDate),
      occurrenceCount: clearOccurrenceCount
          ? null
          : (occurrenceCount ?? this.occurrenceCount),
      enabled: enabled ?? this.enabled,
      createdAt: createdAt ?? this.createdAt,
      transfer: transfer,
      version: version,
      overrides: overrides,
      categoryId: categoryId,
      categoryHidden: categoryHidden,
      kind: kind,
      loan: loan,
      offsetStreamIds: offsetStreamIds,
    );
  }

  BudgetEvent withOverrides(Map<DateTime, AmountOverride> overrides) =>
      BudgetEvent(
        days: days,
        color: color,
        id: id,
        streamId: streamId,
        name: name,
        direction: direction,
        amount: amount,
        startDate: startDate,
        recurrenceMode: recurrenceMode,
        interval: interval,
        unit: unit,
        endMode: endMode,
        endDate: endDate,
        occurrenceCount: occurrenceCount,
        enabled: enabled,
        createdAt: createdAt,
        transfer: transfer,
        version: version,
        overrides: overrides,
        categoryId: categoryId,
        categoryHidden: categoryHidden,
        kind: kind,
        loan: loan,
        offsetStreamIds: offsetStreamIds,
      );
}

/// An event category of one owner (global: every stream the owner has,
/// migration 025): unique name (case-insensitive) in the owner's set, the
/// lane colour of its events, and a shared hidden flag.
class Category {
  Category({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.color,
    required this.hidden,
    required this.createdAt,
    this.version = 1,
    this.eventCount = 0,
  });

  final String id;
  final String ownerId;
  final String name;
  final String color;
  final bool hidden;
  final DateTime createdAt;
  final int version;

  /// Events in the category across all the owner's streams (the events a
  /// delete removes, before transfer counterparts).
  final int eventCount;

  Map<String, Object?> toJson() => {
        'id': id,
        'ownerId': ownerId,
        'name': name,
        'color': color,
        'hidden': hidden,
        'eventCount': eventCount,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'version': version,
      };
}

/// A once-off override of one occurrence's amount and direction.
class AmountOverride {
  const AmountOverride({required this.direction, required this.amount});

  final Direction direction;
  final Decimal amount;

  Decimal get signed => direction == Direction.credit ? amount : -amount;

  Map<String, Object?> toJson() => {
        'direction': direction.name,
        'amount': amount.toString(),
      };
}

/// The other side of a transfer, as seen from one row.
class TransferLink {
  TransferLink({
    required this.id,
    this.peerId,
    this.peerStreamId,
    this.peerStreamName,
  });

  final String id;
  final String? peerId;
  final String? peerStreamId;
  final String? peerStreamName;

  Map<String, Object?> toJson() => {
        'id': id,
        'peerEventId': peerId,
        'peerStreamId': peerStreamId,
        'peerStreamName': peerStreamName,
      };
}

class Occurrence {
  Occurrence({
    required this.eventId,
    required this.date,
    required this.signedDelta,
    required this.skipped,
    this.component,
    this.derived = false,
    this.payout = false,
    this.flat = false,
  });

  final String eventId;
  final DateTime date;
  final Decimal signedDelta;
  final bool skipped;

  /// `"interest"` for a loan's derived interest charge; null otherwise.
  final String? component;

  /// Computed by the loan walk (not a stored event occurrence).
  final bool derived;

  /// The interest charged on the day the loan was paid off.
  final bool payout;

  /// A flat-rate loan's interest instalment.
  final bool flat;

  /// The optional keys appear only when set, so non-loan JSON is unchanged.
  Map<String, Object?> toJson() => {
        'eventId': eventId,
        'date': formatDate(date),
        'signedDelta': signedDelta.toString(),
        'skipped': skipped,
        if (component != null) 'component': component,
        if (derived) 'derived': true,
        if (payout) 'payout': true,
        if (flat) 'flat': true,
      };
}

class BalancePoint {
  BalancePoint({
    required this.date,
    required this.closingBalance,
  });

  final DateTime date;
  final Decimal closingBalance;

  Map<String, Object?> toJson() => {
        'date': formatDate(date),
        'closingBalance': closingBalance.toString(),
      };
}

String formatDate(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

DateTime parseDate(String value) {
  final parts = value.split('-');
  if (parts.length != 3) {
    throw FormatException('Invalid date: $value');
  }
  final y = int.parse(parts[0]);
  final m = int.parse(parts[1]);
  final d = int.parse(parts[2]);
  return DateTime.utc(y, m, d);
}

Decimal parseDecimal(Object? value) {
  if (value == null) throw FormatException('Missing decimal');
  return Decimal.parse(value.toString());
}

/// Reads an optional `currencyScale` from a request body. Null when absent;
/// throws [FormatException] for values outside [Stream.currencyScales].
int? parseCurrencyScale(Map<String, Object?> body) {
  final raw = body['currencyScale'];
  if (raw == null) return null;
  final v = raw is int ? raw : int.tryParse(raw.toString());
  if (v == null || !BudgetStream.currencyScales.contains(v)) {
    throw FormatException(
        'currencyScale must be one of ${BudgetStream.currencyScales.join(', ')}');
  }
  return v;
}

/// Smallest currency scale whose ~10-unit default view holds [span] (the
/// distance from the lowest of balance/zero to the highest) in 9 units,
/// clamped to $1..$1M. E.g. 3500 → 1000, 800 → 100, 0 → 1.
int autoCurrencyScale(double span) {
  final s = span.abs();
  for (final unit in BudgetStream.currencyScales) {
    if (s <= 9 * unit) return unit;
  }
  return BudgetStream.currencyScales.last;
}

final _hexColor = RegExp(r'^#?([0-9a-fA-F]{6})$');

/// An event colour from JSON: "#RRGGBB" (or "RRGGBB"), normalised to
/// upper case with the "#"; null / "" = none (the positional colour).
/// Throws [FormatException] for anything else.
String? parseEventColor(Object? raw) {
  if (raw == null) return null;
  if (raw is! String) throw FormatException('color must be "#RRGGBB"');
  final v = raw.trim();
  if (v.isEmpty) return null;
  final m = _hexColor.firstMatch(v);
  if (m == null) throw FormatException('color must be "#RRGGBB"');
  return '#${m.group(1)!.toUpperCase()}';
}
