import 'package:decimal/decimal.dart';

import 'enums.dart';

class Project {
  Project({
    required this.id,
    required this.name,
    required this.createdAt,
  });

  final String id;
  final String name;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };
}

class Account {
  Account({
    required this.id,
    required this.projectId,
    required this.name,
    required this.currency,
    required this.seedBalance,
    required this.seedDate,
    required this.lossThreshold,
    required this.displayOrder,
    required this.transactionOrder,
  });

  final String id;
  final String projectId;
  final String name;
  final String currency;
  final Decimal seedBalance;
  final DateTime seedDate;
  final Decimal lossThreshold;
  final int displayOrder;
  final List<String> transactionOrder;

  Map<String, Object?> toJson() => {
        'id': id,
        'projectId': projectId,
        'name': name,
        'currency': currency,
        'seedBalance': seedBalance.toString(),
        'seedDate': formatDate(seedDate),
        'lossThreshold': lossThreshold.toString(),
        'displayOrder': displayOrder,
        'transactionOrder': transactionOrder,
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
  });

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
    );
  }
}

/// The other side of a transfer, as seen from one row.
class TransferLink {
  TransferLink({
    required this.id,
    this.peerId,
    this.peerAccountId,
    this.peerAccountName,
    this.peerProjectId,
    this.peerProjectName,
  });

  final String id;
  final String? peerId;
  final String? peerAccountId;
  final String? peerAccountName;
  final String? peerProjectId;
  final String? peerProjectName;

  Map<String, Object?> toJson() => {
        'id': id,
        'peerTransactionId': peerId,
        'peerAccountId': peerAccountId,
        'peerAccountName': peerAccountName,
        'peerProjectId': peerProjectId,
        'peerProjectName': peerProjectName,
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
