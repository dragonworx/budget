import 'package:decimal/decimal.dart';

import 'enums.dart';

class Account {
  Account({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.seedBalance,
    required this.seedDate,
    required this.lossThreshold,
    required this.displayOrder,
    required this.transactionOrder,
    this.currencyScale = defaultCurrencyScale,
    this.version = 1,
  });

  final int version;

  /// Allowed y-axis units (currency units per grid step).
  static const currencyScales = [1, 10, 100, 1000, 10000, 100000, 1000000];
  static const defaultCurrencyScale = 100;

  final String id;

  /// The user who owns the account (accounts are top level).
  final String ownerId;
  final String name;
  final Decimal seedBalance;
  final DateTime seedDate;
  final Decimal lossThreshold;
  final int displayOrder;
  final List<String> transactionOrder;
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
        'transactionOrder': transactionOrder,
        'version': version,
      };
}

class Transaction {
  Transaction({
    required this.id,
    required this.accountId,
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
  });

  final int version;

  /// Once-off overrides of single occurrences (date-only UTC keys).
  final Map<DateTime, AmountOverride> overrides;

  /// Signed amount of the occurrence on [date]: its override, else the
  /// series amount.
  Decimal signedAmountOn(DateTime date) {
    final o = overrides[DateTime.utc(date.year, date.month, date.day)];
    return o == null ? signedAmount : o.signed;
  }

  final String id;
  final String accountId;
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
        'accountId': accountId,
        'name': name,
        'direction': direction.name,
        'amount': amount.toString(),
        'startDate': formatDate(startDate),
        'recurrenceMode': recurrenceMode.name,
        'interval': interval,
        'unit': unit?.name,
        'endMode': endMode.apiName,
        'endDate': endDate == null ? null : formatDate(endDate!),
        'occurrenceCount': occurrenceCount,
        'enabled': enabled,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'transfer': transfer?.toJson(),
        'version': version,
        'overrides': [
          for (final e
              in (overrides.entries.toList()
                ..sort((a, b) => a.key.compareTo(b.key))))
            {'date': formatDate(e.key), ...e.value.toJson()},
        ],
      };

  Transaction copyWith({
    String? id,
    String? accountId,
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
  }) {
    return Transaction(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
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
    );
  }

  Transaction withOverrides(Map<DateTime, AmountOverride> overrides) =>
      Transaction(
        id: id,
        accountId: accountId,
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
      );
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
    this.peerAccountId,
    this.peerAccountName,
  });

  final String id;
  final String? peerId;
  final String? peerAccountId;
  final String? peerAccountName;

  Map<String, Object?> toJson() => {
        'id': id,
        'peerTransactionId': peerId,
        'peerAccountId': peerAccountId,
        'peerAccountName': peerAccountName,
      };
}

class Occurrence {
  Occurrence({
    required this.transactionId,
    required this.date,
    required this.signedDelta,
    required this.skipped,
  });

  final String transactionId;
  final DateTime date;
  final Decimal signedDelta;
  final bool skipped;

  Map<String, Object?> toJson() => {
        'transactionId': transactionId,
        'date': formatDate(date),
        'signedDelta': signedDelta.toString(),
        'skipped': skipped,
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
/// throws [FormatException] for values outside [Account.currencyScales].
int? parseCurrencyScale(Map<String, Object?> body) {
  final raw = body['currencyScale'];
  if (raw == null) return null;
  final v = raw is int ? raw : int.tryParse(raw.toString());
  if (v == null || !Account.currencyScales.contains(v)) {
    throw FormatException(
        'currencyScale must be one of ${Account.currencyScales.join(', ')}');
  }
  return v;
}

/// Smallest currency scale whose ~10-unit default view holds [span] (the
/// distance from the lowest of balance/zero to the highest) in 9 units,
/// clamped to $1..$1M. E.g. 3500 → 1000, 800 → 100, 0 → 1.
int autoCurrencyScale(double span) {
  final s = span.abs();
  for (final unit in Account.currencyScales) {
    if (s <= 9 * unit) return unit;
  }
  return Account.currencyScales.last;
}
