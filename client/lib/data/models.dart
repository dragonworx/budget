import 'package:decimal/decimal.dart';

DateTime? _parseDateTime(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  return DateTime.tryParse(value.toString());
}

DateTime parseDate(dynamic value) {
  final s = value.toString();
  final parts = s.split('T').first.split('-');
  if (parts.length != 3) {
    throw FormatException('Invalid date: $value');
  }
  return DateTime(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
}

String formatDate(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

Decimal parseMoney(dynamic value) {
  if (value is Decimal) return value;
  return Decimal.parse(value.toString());
}

String moneyToJson(Decimal value) => value.toString();

/// Sharing role, lowest to highest.
enum Role {
  viewer,
  editor,
  owner;

  static Role parse(dynamic v, [Role fallback = Role.owner]) => switch (v) {
    'viewer' => Role.viewer,
    'editor' => Role.editor,
    'owner' => Role.owner,
    _ => fallback,
  };

  bool get canEdit => index >= Role.editor.index;
  bool get isOwner => this == Role.owner;
  String get label => switch (this) {
    Role.viewer => 'Viewer',
    Role.editor => 'Editor',
    Role.owner => 'Owner',
  };
}

/// A user as embedded in sharing payloads.
class UserRef {
  const UserRef({required this.id, required this.email, this.name, this.pictureUrl});

  final String id;
  final String email;
  final String? name;
  final String? pictureUrl;

  String get displayName =>
      (name != null && name!.trim().isNotEmpty) ? name! : email;

  String get initials {
    final parts = displayName
        .trim()
        .split(RegExp(r'[\s@._-]+'))
        .where((p) => p.isNotEmpty);
    final t = parts.take(2).map((p) => p[0].toUpperCase()).join();
    return t.isEmpty ? '?' : t;
  }

  static UserRef? maybe(dynamic j) {
    if (j is! Map) return null;
    return UserRef(
      id: (j['id'] ?? j['userId'] ?? '').toString(),
      email: (j['email'] ?? '').toString(),
      name: j['name']?.toString(),
      pictureUrl: j['pictureUrl']?.toString(),
    );
  }
}

class Project {
  const Project({
    required this.id,
    required this.name,
    this.createdAt,
    this.version,
    this.role = Role.owner,
    this.limited = false,
    this.shared = false,
    this.owner,
    this.sharedAccountIds = const [],
  });

  final String id;
  final String name;
  final DateTime? createdAt;
  final int? version;

  /// The signed-in user's role on the project (owner when not reported).
  final Role role;

  /// Only some accounts are shared with this user (`access: "account"`).
  final bool limited;

  /// Someone else owns this project and shared it (or some accounts) with me.
  final bool shared;
  final UserRef? owner;
  final List<String> sharedAccountIds;

  factory Project.fromJson(Map<String, dynamic> json) {
    return Project(
      id: json['id'] as String,
      name: json['name'] as String,
      createdAt: _parseDateTime(json['createdAt'] ?? json['created_at']),
      version: (json['version'] as num?)?.toInt(),
      role: Role.parse(json['role'], json['access'] == 'account' ? Role.viewer : Role.owner),
      limited: json['access'] == 'account',
      shared: json['shared'] == true,
      owner: UserRef.maybe(json['owner']),
      sharedAccountIds: [
        for (final a in (json['sharedAccountIds'] as List?) ?? const []) a.toString(),
      ],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (createdAt != null) 'createdAt': createdAt!.toUtc().toIso8601String(),
  };

  Project copyWith({String? id, String? name, DateTime? createdAt}) {
    return Project(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      version: version,
      role: role,
      limited: limited,
      shared: shared,
      owner: owner,
      sharedAccountIds: sharedAccountIds,
    );
  }
}

class Account {
  const Account({
    required this.id,
    required this.projectId,
    required this.name,
    required this.currency,
    required this.seedBalance,
    required this.seedDate,
    required this.lossThreshold,
    this.transactionOrder = const [],
    this.displayOrder = 0,
    this.currencyScale = defaultCurrencyScale,
    this.version,
    this.role = Role.owner,
  });

  final int? version;

  /// Effective role on this account (max of project role and account share).
  final Role role;

  /// Currency scale choices: dollars per y-axis grid step, with labels.
  static const currencyScales = <int, String>{
    1: 'Dollars (\$1)',
    10: 'Tens (\$10)',
    100: 'Hundreds (\$100)',
    1000: 'Thousands (\$1k)',
    10000: 'Tens of thousands (\$10k)',
    100000: 'Hundreds of thousands (\$100k)',
    1000000: 'Millions (\$1M)',
  };
  static const defaultCurrencyScale = 100;

  /// Smallest scale whose ~10-unit view holds [span] in 9 units ($1..$1M).
  /// Mirrors the server's autoCurrencyScale.
  static int autoCurrencyScale(double span) {
    final s = span.abs();
    for (final unit in currencyScales.keys) {
      if (s <= 9 * unit) return unit;
    }
    return currencyScales.keys.last;
  }

  /// Dollars per y grid step; the timeline's default vertical view is ~10.
  final int currencyScale;

  final String id;
  final String projectId;
  final String name;
  final String currency;
  final Decimal seedBalance;
  final DateTime seedDate;

  /// Closing balances below this value are a loss (equal is not).
  final Decimal lossThreshold;
  final List<String> transactionOrder;
  final int displayOrder;

  factory Account.fromJson(Map<String, dynamic> json) {
    final order =
        json['transactionOrder'] ?? json['transaction_order'] ?? const [];
    final loss = json['lossThreshold'] ?? json['loss_threshold'];
    return Account(
      id: json['id'] as String,
      projectId: (json['projectId'] ?? json['project_id']) as String,
      name: json['name'] as String,
      currency: json['currency'] as String,
      seedBalance: parseMoney(json['seedBalance'] ?? json['seed_balance']),
      seedDate: parseDate(json['seedDate'] ?? json['seed_date']),
      lossThreshold: loss == null ? Decimal.zero : parseMoney(loss),
      transactionOrder: (order as List).map((e) => e.toString()).toList(),
      displayOrder: (json['displayOrder'] ?? json['display_order'] ?? 0) as int,
      currencyScale:
          (json['currencyScale'] ??
                  json['currency_scale'] ??
                  defaultCurrencyScale)
              as int,
      version: (json['version'] as num?)?.toInt(),
      role: Role.parse(json['role']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'projectId': projectId,
    'name': name,
    'currency': currency,
    'seedBalance': moneyToJson(seedBalance),
    'seedDate': formatDate(seedDate),
    'lossThreshold': moneyToJson(lossThreshold),
    'currencyScale': currencyScale,
    'transactionOrder': transactionOrder,
    'displayOrder': displayOrder,
  };

  Map<String, dynamic> toCreateJson() => {
    'name': name,
    'currency': currency,
    'seedBalance': moneyToJson(seedBalance),
    'seedDate': formatDate(seedDate),
    'lossThreshold': moneyToJson(lossThreshold),
    'currencyScale': currencyScale,
  };

  Map<String, dynamic> toPatchJson() => {
    'name': name,
    'currency': currency,
    'seedBalance': moneyToJson(seedBalance),
    'seedDate': formatDate(seedDate),
    'lossThreshold': moneyToJson(lossThreshold),
    'currencyScale': currencyScale,
    'transactionOrder': transactionOrder,
    if (version != null) 'version': version,
  };

  Account copyWith({
    String? id,
    String? projectId,
    String? name,
    String? currency,
    Decimal? seedBalance,
    DateTime? seedDate,
    Decimal? lossThreshold,
    List<String>? transactionOrder,
    int? displayOrder,
    int? currencyScale,
    int? version,
    bool clearVersion = false,
    Role? role,
  }) {
    return Account(
      version: clearVersion ? null : (version ?? this.version),
      role: role ?? this.role,
      id: id ?? this.id,
      projectId: projectId ?? this.projectId,
      name: name ?? this.name,
      currency: currency ?? this.currency,
      seedBalance: seedBalance ?? this.seedBalance,
      seedDate: seedDate ?? this.seedDate,
      lossThreshold: lossThreshold ?? this.lossThreshold,
      transactionOrder: transactionOrder ?? this.transactionOrder,
      displayOrder: displayOrder ?? this.displayOrder,
      currencyScale: currencyScale ?? this.currencyScale,
    );
  }
}

enum TransactionDirection {
  credit,
  debit;

  static TransactionDirection fromJson(String value) {
    return TransactionDirection.values.byName(value);
  }

  String toJson() => name;
}

enum RecurrenceMode {
  once,
  every;

  static RecurrenceMode fromJson(String value) {
    return RecurrenceMode.values.byName(value);
  }

  String toJson() => name;
}

enum RecurrenceUnit {
  days,
  weeks,
  months,
  years;

  static RecurrenceUnit fromJson(String value) {
    return RecurrenceUnit.values.byName(value);
  }

  String toJson() => name;
}

enum EndMode {
  never,
  untilDate,
  count;

  static EndMode fromJson(String value) {
    switch (value) {
      case 'until_date':
      case 'untilDate':
        return EndMode.untilDate;
      case 'count':
        return EndMode.count;
      case 'never':
        return EndMode.never;
      default:
        throw FormatException('Unknown end mode: $value');
    }
  }

  String toJson() {
    switch (this) {
      case EndMode.never:
        return 'never';
      case EndMode.untilDate:
        return 'untilDate';
      case EndMode.count:
        return 'count';
    }
  }
}

class Transaction {
  const Transaction({
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
    this.enabled = true,
    this.transfer,
    this.version,
  });

  /// Row version for optimistic concurrency (null: last write wins).
  final int? version;

  final String id;
  final String accountId;
  final String name;
  final TransactionDirection direction;

  /// Set when this series is one side of a transfer between accounts.
  final TransferLink? transfer;
  bool get isTransfer => transfer != null;
  final Decimal amount;
  final DateTime startDate;
  final RecurrenceMode recurrenceMode;
  final int? interval;
  final RecurrenceUnit? unit;
  final EndMode endMode;
  final DateTime? endDate;
  final int? occurrenceCount;
  final bool enabled;

  factory Transaction.fromJson(Map<String, dynamic> json) {
    final recurrence = json['recurrence'];
    final endRule = json['endRule'] ?? json['end_rule'];

    RecurrenceMode recurrenceMode;
    int? interval;
    RecurrenceUnit? unit;

    if (recurrence is Map<String, dynamic>) {
      recurrenceMode = RecurrenceMode.fromJson(recurrence['mode'] as String);
      interval = recurrence['interval'] as int?;
      final unitRaw = recurrence['unit'];
      unit = unitRaw == null
          ? null
          : RecurrenceUnit.fromJson(unitRaw as String);
    } else {
      recurrenceMode = RecurrenceMode.fromJson(
        (json['recurrenceMode'] ?? json['recurrence_mode']) as String,
      );
      interval = json['interval'] as int?;
      final unitRaw = json['unit'];
      unit = unitRaw == null
          ? null
          : RecurrenceUnit.fromJson(unitRaw as String);
    }

    EndMode endMode;
    DateTime? endDate;
    int? occurrenceCount;

    if (endRule is Map<String, dynamic>) {
      endMode = EndMode.fromJson(endRule['mode'] as String);
      endDate = endRule['endDate'] != null || endRule['end_date'] != null
          ? parseDate(endRule['endDate'] ?? endRule['end_date'])
          : null;
      occurrenceCount =
          (endRule['occurrenceCount'] ?? endRule['occurrence_count']) as int?;
    } else {
      endMode = EndMode.fromJson(
        (json['endMode'] ?? json['end_mode'] ?? 'never') as String,
      );
      final endDateRaw = json['endDate'] ?? json['end_date'];
      endDate = endDateRaw == null ? null : parseDate(endDateRaw);
      occurrenceCount =
          (json['occurrenceCount'] ?? json['occurrence_count']) as int?;
    }

    return Transaction(
      id: json['id'] as String,
      accountId: (json['accountId'] ?? json['account_id']) as String,
      name: (json['name'] as String?) ?? '',
      direction: TransactionDirection.fromJson(json['direction'] as String),
      amount: parseMoney(json['amount']),
      startDate: parseDate(json['startDate'] ?? json['start_date']),
      recurrenceMode: recurrenceMode,
      interval: interval,
      unit: unit,
      endMode: endMode,
      endDate: endDate,
      occurrenceCount: occurrenceCount,
      enabled: (json['enabled'] as bool?) ?? true,
      transfer: json['transfer'] is Map<String, dynamic>
          ? TransferLink.fromJson(json['transfer'] as Map<String, dynamic>)
          : null,
      version: (json['version'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'accountId': accountId,
    'name': name,
    'direction': direction.toJson(),
    'amount': moneyToJson(amount),
    'startDate': formatDate(startDate),
    'recurrenceMode': recurrenceMode.toJson(),
    'interval': interval,
    'unit': unit?.toJson(),
    'endMode': endMode.toJson(),
    'endDate': endDate == null ? null : formatDate(endDate!),
    'occurrenceCount': occurrenceCount,
    'enabled': enabled,
    'transfer': transfer?.toJson(),
  };

  Map<String, dynamic> toCreateJson() => {
    'name': name,
    'direction': direction.toJson(),
    'amount': moneyToJson(amount),
    'startDate': formatDate(startDate),
    'recurrenceMode': recurrenceMode.toJson(),
    if (interval != null) 'interval': interval,
    if (unit != null) 'unit': unit!.toJson(),
    'endMode': endMode.toJson(),
    if (endDate != null) 'endDate': formatDate(endDate!),
    if (occurrenceCount != null) 'occurrenceCount': occurrenceCount,
    'enabled': enabled,
    // Always sent: null on a patch turns a transfer back into a plain series.
    'transferToAccountId': transfer?.peerAccountId,
  };

  Transaction copyWith({
    String? id,
    String? accountId,
    String? name,
    TransactionDirection? direction,
    Decimal? amount,
    DateTime? startDate,
    RecurrenceMode? recurrenceMode,
    int? interval,
    RecurrenceUnit? unit,
    EndMode? endMode,
    DateTime? endDate,
    int? occurrenceCount,
    bool? enabled,
    TransferLink? transfer,
    bool clearTransfer = false,
    bool clearInterval = false,
    bool clearUnit = false,
    bool clearEndDate = false,
    bool clearOccurrenceCount = false,
    int? version,
    bool clearVersion = false,
  }) {
    return Transaction(
      version: clearVersion ? null : (version ?? this.version),
      transfer: clearTransfer ? null : (transfer ?? this.transfer),
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
    );
  }
}

/// The other side of a transfer, as seen from one series.
class TransferLink {
  const TransferLink({
    this.id,
    this.peerTransactionId,
    required this.peerAccountId,
    this.peerAccountName,
    this.peerProjectId,
    this.peerProjectName,
    this.peerReadable = true,
  });

  /// False when I can't see the other account (its names are withheld).
  final bool peerReadable;

  final String? id;
  final String? peerTransactionId;
  final String peerAccountId;
  final String? peerAccountName;
  final String? peerProjectId;
  final String? peerProjectName;

  factory TransferLink.fromJson(Map<String, dynamic> json) => TransferLink(
    id: json['id'] as String?,
    peerTransactionId: json['peerTransactionId'] as String?,
    peerAccountId: (json['peerAccountId'] as String?) ?? '',
    peerAccountName: json['peerAccountName'] as String?,
    peerProjectId: json['peerProjectId'] as String?,
    peerProjectName: json['peerProjectName'] as String?,
    peerReadable: json['peerReadable'] as bool? ?? true,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'peerTransactionId': peerTransactionId,
    'peerAccountId': peerAccountId,
    'peerAccountName': peerAccountName,
    'peerProjectId': peerProjectId,
    'peerProjectName': peerProjectName,
    'peerReadable': peerReadable,
  };

  String get accountLabel => !peerReadable
      ? 'Private account'
      : (peerAccountName ?? 'another account');
}

/// "to Savings" / "from Savings" for one side of a transfer.
String transferPhrase(Transaction t) {
  final link = t.transfer;
  if (link == null) return '';
  final dir = t.direction == TransactionDirection.debit ? 'to' : 'from';
  return '$dir ${link.accountLabel}';
}

/// Timeline / popup label: transfers show their direction and the other
/// account, e.g. "Savings → Joint" (out) / "Savings ← Everyday" (in).
/// (Plain arrows: the chart font has no ⇄ glyph.)
String transactionLabel(Transaction t) {
  final link = t.transfer;
  if (link == null) return t.name;
  final arrow = t.direction == TransactionDirection.debit ? '→' : '←';
  final name = t.name.trim();
  final tail = '$arrow ${link.accountLabel}';
  return name.isEmpty ? 'Transfer $tail' : '$name $tail';
}

class BalancePoint {
  const BalancePoint({required this.date, required this.closingBalance});

  final DateTime date;
  final Decimal closingBalance;

  factory BalancePoint.fromJson(Map<String, dynamic> json) {
    return BalancePoint(
      date: parseDate(json['date']),
      closingBalance: parseMoney(
        json['closingBalance'] ??
            json['closing_balance'] ??
            json['balance'] ??
            json['closing'],
      ),
    );
  }
}

class Occurrence {
  const Occurrence({
    required this.transactionId,
    required this.date,
    required this.signedDelta,
    this.skipped = false,
  });

  final String transactionId;
  final DateTime date;
  final Decimal signedDelta;
  final bool skipped;

  factory Occurrence.fromJson(Map<String, dynamic> json) {
    return Occurrence(
      transactionId:
          (json['transactionId'] ?? json['transaction_id']) as String,
      date: parseDate(json['date']),
      signedDelta: parseMoney(
        json['signedDelta'] ?? json['signed_delta'] ?? '0',
      ),
      skipped: (json['skipped'] as bool?) ?? false,
    );
  }
}

class BalanceSeries {
  const BalanceSeries({required this.points, this.occurrences = const []});

  final List<BalancePoint> points;
  final List<Occurrence> occurrences;

  factory BalanceSeries.fromJson(dynamic data) {
    if (data is List) {
      return BalanceSeries(
        points: data
            .cast<Map<String, dynamic>>()
            .map(BalancePoint.fromJson)
            .toList(),
      );
    }
    if (data is Map<String, dynamic>) {
      final pointsRaw =
          data['points'] ?? data['balances'] ?? data['data'] ?? const [];
      final occRaw = data['occurrences'] ?? const [];
      return BalanceSeries(
        points: (pointsRaw as List)
            .cast<Map<String, dynamic>>()
            .map(BalancePoint.fromJson)
            .toList(),
        occurrences: (occRaw as List)
            .cast<Map<String, dynamic>>()
            .map(Occurrence.fromJson)
            .toList(),
      );
    }
    throw FormatException('Unexpected balance response shape');
  }
}

enum RoundingMode {
  nearest,
  atLeast,
  atMost;

  String toJson() {
    switch (this) {
      case RoundingMode.nearest:
        return 'nearest';
      case RoundingMode.atLeast:
        return 'atLeast';
      case RoundingMode.atMost:
        return 'atMost';
    }
  }
}

/// The six transaction-planning variables the solver can fill in (§4.1).
enum SolveVar {
  startDate,
  endDate,
  amount,
  total,
  interval,
  count;

  String get label => switch (this) {
    SolveVar.startDate => 'start date',
    SolveVar.endDate => 'end date',
    SolveVar.amount => 'increment amount',
    SolveVar.total => 'total amount',
    SolveVar.interval => 'frequency',
    SolveVar.count => 'count',
  };

  static SolveVar? tryParse(String value) {
    for (final v in SolveVar.values) {
      if (v.name == value) return v;
    }
    return null;
  }
}

/// Any subset of the planning variables; the server fills in the rest.
class SolveRequest {
  const SolveRequest({
    required this.name,
    required this.direction,
    required this.unit,
    this.startDate,
    this.endDate,
    this.amount,
    this.interval,
    this.occurrenceCount,
    this.targetTotal,
    this.targetBalance,
    this.rounding = RoundingMode.nearest,
  });

  /// Balance target mode: the account balance wanted on [endDate]; the
  /// server sets the total to `target − projected balance`.
  final Decimal? targetBalance;

  final String name;
  final TransactionDirection direction;
  final RecurrenceUnit unit;
  final DateTime? startDate;
  final DateTime? endDate;
  final Decimal? amount;
  final int? interval;
  final int? occurrenceCount;
  final Decimal? targetTotal;
  final RoundingMode rounding;

  SolveRequest withDefaults({DateTime? startDate, int? interval}) =>
      SolveRequest(
        name: name,
        direction: direction,
        unit: unit,
        startDate: startDate ?? this.startDate,
        endDate: endDate,
        amount: amount,
        interval: interval ?? this.interval,
        occurrenceCount: occurrenceCount,
        targetTotal: targetTotal,
        targetBalance: targetBalance,
        rounding: rounding,
      );

  Map<String, dynamic> toJson() => {
    'name': name,
    'direction': direction.toJson(),
    'unit': unit.toJson(),
    if (startDate != null) 'startDate': formatDate(startDate!),
    if (endDate != null) 'endDate': formatDate(endDate!),
    if (amount != null) 'amount': moneyToJson(amount!),
    if (interval != null) 'interval': interval,
    if (occurrenceCount != null) 'occurrenceCount': occurrenceCount,
    if (targetTotal != null && targetBalance == null)
      'targetTotal': moneyToJson(targetTotal!),
    if (targetBalance != null) 'targetBalance': moneyToJson(targetBalance!),
    'rounding': rounding.toJson(),
  };
}

class SolveValues {
  const SolveValues({
    this.startDate,
    this.endDate,
    this.lastOccurrenceDate,
    this.amount,
    this.total,
    this.actualTotal,
    this.interval,
    this.count,
  });

  final DateTime? startDate;
  final DateTime? endDate;
  final DateTime? lastOccurrenceDate;
  final Decimal? amount;
  final Decimal? total;

  /// `amount × count`; differs from [total] when rounding was needed.
  final Decimal? actualTotal;
  final int? interval;
  final int? count;

  factory SolveValues.fromJson(Map<String, dynamic> json) {
    DateTime? date(String key) =>
        json[key] == null ? null : parseDate(json[key]);
    Decimal? money(String key) =>
        json[key] == null ? null : parseMoney(json[key]);
    return SolveValues(
      startDate: date('startDate'),
      endDate: date('endDate'),
      lastOccurrenceDate: date('lastOccurrenceDate'),
      amount: money('amount'),
      total: money('total'),
      actualTotal: money('actualTotal'),
      interval: json['interval'] as int?,
      count: json['count'] as int?,
    );
  }
}

class SolveResult {
  const SolveResult({
    this.transaction,
    this.previewOccurrences = const [],
    this.values = const SolveValues(),
    this.solved = const {},
    this.needsMore = 0,
    this.needsOneOf = const [],
    this.message,
    this.balanceTarget,
    this.onTrack = false,
  });

  /// Set in balance target mode: projected balance on the end date and the
  /// gap the plan covers.
  final BalanceTargetInfo? balanceTarget;

  /// Balance target already met without a new transaction.
  final bool onTrack;

  /// Null while the inputs are not yet enough to determine a transaction.
  final Transaction? transaction;
  final List<Occurrence> previewOccurrences;
  final SolveValues values;

  /// Variables the server calculated rather than received.
  final Set<SolveVar> solved;

  /// How many more values the user must fill in, when [transaction] is null.
  final int needsMore;
  final List<SolveVar> needsOneOf;
  final String? message;

  bool get isComplete => transaction != null;

  factory SolveResult.fromJson(Map<String, dynamic> json) {
    List<SolveVar> vars(String key) => [
      for (final raw in (json[key] as List? ?? const []))
        ?SolveVar.tryParse(raw.toString()),
    ];
    final transactionJson = json['transaction'];
    final valuesJson = json['values'];
    final previewRaw = json['previewOccurrences'] as List? ?? const [];
    return SolveResult(
      transaction: transactionJson is Map<String, dynamic>
          ? Transaction.fromJson(transactionJson)
          : null,
      previewOccurrences: previewRaw
          .cast<Map<String, dynamic>>()
          .map(Occurrence.fromJson)
          .toList(),
      values: valuesJson is Map<String, dynamic>
          ? SolveValues.fromJson(valuesJson)
          : const SolveValues(),
      solved: vars('solved').toSet(),
      needsMore: (json['needsMore'] as int?) ?? 0,
      needsOneOf: vars('needsOneOf'),
      message: json['message'] as String?,
      balanceTarget: json['balanceTarget'] is Map<String, dynamic>
          ? BalanceTargetInfo.fromJson(json['balanceTarget'])
          : null,
      onTrack: json['status'] == 'onTrack',
    );
  }
}

class BalanceTargetInfo {
  const BalanceTargetInfo({
    required this.targetBalance,
    required this.projectedBalance,
    required this.gap,
  });

  final Decimal targetBalance;
  final Decimal projectedBalance;
  final Decimal gap;

  factory BalanceTargetInfo.fromJson(Map<String, dynamic> json) =>
      BalanceTargetInfo(
        targetBalance: parseMoney(json['targetBalance']),
        projectedBalance: parseMoney(json['projectedBalance']),
        gap: parseMoney(json['gap']),
      );
}

/// Lowest point and runway from `GET /accounts/:id/insights`.
class BalanceInsights {
  const BalanceInsights({
    this.lowestDate,
    this.lowestBalance,
    this.alertDate,
    this.zeroDate,
    this.horizonDays = 1825,
    this.days = 365,
  });

  final DateTime? lowestDate;
  final double? lowestBalance;

  /// First day below the alert threshold (null: not within horizon).
  final DateTime? alertDate;

  /// First day below zero (null: not within horizon).
  final DateTime? zeroDate;
  final int horizonDays;
  final int days;

  factory BalanceInsights.fromJson(Map<String, dynamic> json) {
    final low = json['lowest'];
    DateTime? date(Object? v) => v == null ? null : parseDate(v);
    return BalanceInsights(
      lowestDate: low is Map ? date(low['date']) : null,
      lowestBalance: low is Map
          ? double.tryParse(low['balance'].toString())
          : null,
      alertDate: date(json['alertDate']),
      zeroDate: date(json['zeroDate']),
      horizonDays: (json['horizonDays'] as int?) ?? 1825,
      days: (json['days'] as int?) ?? 365,
    );
  }
}
