import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:decimal/decimal.dart';

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
  const UserRef({
    required this.id,
    required this.email,
    this.name,
    this.pictureUrl,
  });

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

class BudgetStream {
  const BudgetStream({
    required this.id,
    this.ownerId = '',
    required this.name,
    required this.seedBalance,
    required this.seedDate,
    required this.lossThreshold,
    this.eventOrder = const [],
    this.displayOrder = 0,
    this.currencyScale = defaultCurrencyScale,
    this.version,
    this.role = Role.owner,
    this.shared = false,
    this.owner,
    this.hasLoan = false,
  });

  final int? version;

  /// The stream holds a loan event (its balance can run far negative by
  /// design, so it gets no red alert badge).
  final bool hasLoan;

  /// Effective role: owner for my own streams, else the share's role.
  final Role role;

  /// Someone else owns this stream and shared it with me.
  final bool shared;

  /// Who owns it (reported in stream lists).
  final UserRef? owner;

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

  /// The owning user's id (streams are top level).
  final String ownerId;
  final String name;
  final Decimal seedBalance;
  final DateTime seedDate;

  /// Closing balances below this value are a loss (equal is not).
  final Decimal lossThreshold;
  final List<String> eventOrder;
  final int displayOrder;

  factory BudgetStream.fromJson(Map<String, dynamic> json) {
    final order = json['eventOrder'] ?? json['event_order'] ?? const [];
    final loss = json['lossThreshold'] ?? json['loss_threshold'];
    return BudgetStream(
      id: json['id'] as String,
      ownerId: (json['ownerId'] ?? json['owner_id'] ?? '') as String,
      name: json['name'] as String,
      seedBalance: parseMoney(json['seedBalance'] ?? json['seed_balance']),
      seedDate: parseDate(json['seedDate'] ?? json['seed_date']),
      lossThreshold: loss == null ? Decimal.zero : parseMoney(loss),
      eventOrder: (order as List).map((e) => e.toString()).toList(),
      displayOrder: (json['displayOrder'] ?? json['display_order'] ?? 0) as int,
      currencyScale:
          (json['currencyScale'] ??
                  json['currency_scale'] ??
                  defaultCurrencyScale)
              as int,
      version: (json['version'] as num?)?.toInt(),
      role: Role.parse(json['role']),
      shared: json['shared'] == true,
      owner: UserRef.maybe(json['owner']),
      hasLoan: json['hasLoan'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'ownerId': ownerId,
    'name': name,
    'seedBalance': moneyToJson(seedBalance),
    'seedDate': formatDate(seedDate),
    'lossThreshold': moneyToJson(lossThreshold),
    'currencyScale': currencyScale,
    'eventOrder': eventOrder,
    'displayOrder': displayOrder,
  };

  Map<String, dynamic> toCreateJson() => {
    'name': name,
    'seedBalance': moneyToJson(seedBalance),
    'seedDate': formatDate(seedDate),
    'lossThreshold': moneyToJson(lossThreshold),
    'currencyScale': currencyScale,
  };

  Map<String, dynamic> toPatchJson() => {
    'name': name,
    'seedBalance': moneyToJson(seedBalance),
    'seedDate': formatDate(seedDate),
    'lossThreshold': moneyToJson(lossThreshold),
    'currencyScale': currencyScale,
    'eventOrder': eventOrder,
    if (version != null) 'version': version,
  };

  BudgetStream copyWith({
    String? id,
    String? ownerId,
    String? name,
    Decimal? seedBalance,
    DateTime? seedDate,
    Decimal? lossThreshold,
    List<String>? eventOrder,
    int? displayOrder,
    int? currencyScale,
    int? version,
    bool clearVersion = false,
    Role? role,
  }) {
    return BudgetStream(
      version: clearVersion ? null : (version ?? this.version),
      role: role ?? this.role,
      shared: shared,
      owner: owner,
      hasLoan: hasLoan,
      id: id ?? this.id,
      ownerId: ownerId ?? this.ownerId,
      name: name ?? this.name,
      seedBalance: seedBalance ?? this.seedBalance,
      seedDate: seedDate ?? this.seedDate,
      lossThreshold: lossThreshold ?? this.lossThreshold,
      eventOrder: eventOrder ?? this.eventOrder,
      displayOrder: displayOrder ?? this.displayOrder,
      currencyScale: currencyScale ?? this.currencyScale,
    );
  }
}

extension StreamSharing on BudgetStream {
  /// [this] with the sharing fields (shared, owner) of [from].
  BudgetStream withSharing(BudgetStream from) => BudgetStream(
    id: id,
    ownerId: ownerId,
    name: name,
    seedBalance: seedBalance,
    seedDate: seedDate,
    lossThreshold: lossThreshold,
    eventOrder: eventOrder,
    displayOrder: displayOrder,
    currencyScale: currencyScale,
    version: version,
    role: role,
    shared: from.shared,
    owner: from.owner,
    hasLoan: hasLoan,
  );
}

enum EventDirection {
  credit,
  debit;

  static EventDirection fromJson(String value) {
    return EventDirection.values.byName(value);
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

class BudgetEvent {
  const BudgetEvent({
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
    this.enabled = true,
    this.transfer,
    this.version,
    this.overrides = const {},
    this.color,
    this.days = const [],
    this.categoryId,
    this.categoryHidden = false,
    this.kind = 'standard',
    this.loan,
  });

  /// "standard" or "loan" (spec 002). Loans are read-only in this client.
  final String kind;

  /// The loan terms as sent by the server (kept raw until loan editing).
  final Map<String, dynamic>? loan;

  bool get isLoan => kind == 'loan';

  /// The event's category (every saved event has one). [name] is the
  /// category's name and [color] its colour, kept in sync by the server.
  final String? categoryId;

  /// The category is hidden (eye menu): the event counts like a disabled
  /// one while its own [enabled] flag is kept.
  final bool categoryHidden;

  /// Counts on the timeline and in the balance: its own eye is on and its
  /// category is shown.
  bool get active => enabled && !categoryHidden;

  /// The rule's days (weekdays 1 = Mon … 7 = Sun for the week rules, month
  /// days 1–31 for the month rules); empty = the plain cadence from the
  /// start date.
  final List<int> days;

  /// The structured rule this series fires on (shared with the server,
  /// package:budget_recurrence). The legacy [recurrenceMode] / [interval] /
  /// [unit] fields are its cadence view; days that do not fit the cadence
  /// (mid-edit) are dropped.
  Frequency get frequency {
    final once = recurrenceMode == RecurrenceMode.once;
    try {
      return Frequency.fromLegacy(
        once: once,
        interval: once ? null : (interval ?? 1).clamp(1, maxFrequencyInterval),
        unit: once ? null : (unit ?? RecurrenceUnit.days).name,
        days: days,
      );
    } on FormatException {
      if (once) return Frequency.once;
      try {
        return Frequency.fromLegacy(
          once: false,
          interval: (interval ?? 1).clamp(1, maxFrequencyInterval),
          unit: (unit ?? RecurrenceUnit.days).name,
        );
      } on FormatException {
        return Frequency(FreqRule.daily);
      }
    }
  }

  /// The graph line's colour, "#RRGGBB"; null: the lane's positional
  /// palette colour (see `eventColor`).
  final String? color;

  /// Row version for optimistic concurrency (null: last write wins).
  final int? version;

  /// Once-off overrides of single occurrences, by (local, date-only) day.
  final Map<DateTime, OccurrenceOverride> overrides;

  /// The override on [date], if any.
  OccurrenceOverride? overrideOn(DateTime date) =>
      overrides[DateTime(date.year, date.month, date.day)];

  /// Signed amount of the series (positive in, negative out).
  Decimal get signedAmount =>
      direction == EventDirection.credit ? amount : -amount;

  /// Signed amount of the occurrence on [date] (its override, else the
  /// series amount).
  Decimal signedAmountOn(DateTime date) =>
      overrideOn(date)?.signed ?? signedAmount;

  final String id;
  final String streamId;
  final String name;
  final EventDirection direction;

  /// Set when this series is one side of a transfer between streams.
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

  factory BudgetEvent.fromJson(Map<String, dynamic> json) {
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
      // Absent when only the structured `frequency` is sent (below).
      final mode = json['recurrenceMode'] ?? json['recurrence_mode'];
      recurrenceMode = mode == null
          ? RecurrenceMode.once
          : RecurrenceMode.fromJson(mode as String);
      interval = json['interval'] as int?;
      final unitRaw = json['unit'];
      unit = unitRaw == null
          ? null
          : RecurrenceUnit.fromJson(unitRaw as String);
    }

    // The structured rule (newer servers) wins over the cadence fields.
    var days = <int>[
      for (final d in (json['days'] as List?) ?? const []) (d as num).toInt(),
    ];
    final freqRaw = json['frequency'];
    if (freqRaw is Map) {
      try {
        final f = Frequency.fromJson(freqRaw.cast<String, dynamic>());
        recurrenceMode = f.repeats ? RecurrenceMode.every : RecurrenceMode.once;
        interval = f.legacyInterval;
        unit = f.repeats ? RecurrenceUnit.fromJson(f.legacyUnit!) : null;
        days = f.days;
      } on FormatException {
        // Unknown rule: keep the cadence fields.
      }
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

    return BudgetEvent(
      id: json['id'] as String,
      streamId: (json['streamId'] ?? json['stream_id']) as String,
      name: (json['name'] as String?) ?? '',
      direction: EventDirection.fromJson(json['direction'] as String),
      amount: parseMoney(json['amount']),
      startDate: parseDate(json['startDate'] ?? json['start_date']),
      recurrenceMode: recurrenceMode,
      interval: interval,
      unit: unit,
      days: days,
      endMode: endMode,
      endDate: endDate,
      occurrenceCount: occurrenceCount,
      enabled: (json['enabled'] as bool?) ?? true,
      transfer: json['transfer'] is Map<String, dynamic>
          ? TransferLink.fromJson(json['transfer'] as Map<String, dynamic>)
          : null,
      version: (json['version'] as num?)?.toInt(),
      color: normalizeEventColor(json['color'] ?? json['colour']),
      categoryId: json['categoryId'] as String?,
      categoryHidden: (json['categoryHidden'] as bool?) ?? false,
      kind: (json['kind'] as String?) ?? 'standard',
      loan: (json['loan'] as Map?)?.cast<String, dynamic>(),
      overrides: {
        for (final o in (json['overrides'] as List?) ?? const [])
          parseDate((o as Map)['date']): OccurrenceOverride(
            direction: EventDirection.fromJson(o['direction'] as String),
            amount: parseMoney(o['amount']),
          ),
      },
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'streamId': streamId,
    'name': name,
    'direction': direction.toJson(),
    'amount': moneyToJson(amount),
    'startDate': formatDate(startDate),
    'recurrenceMode': recurrenceMode.toJson(),
    'interval': interval,
    'unit': unit?.toJson(),
    'frequency': frequency.toJson(),
    'days': frequency.days,
    'endMode': endMode.toJson(),
    'endDate': endDate == null ? null : formatDate(endDate!),
    'occurrenceCount': occurrenceCount,
    'enabled': enabled,
    'transfer': transfer?.toJson(),
    'color': color,
    'categoryId': categoryId,
    'categoryHidden': categoryHidden,
    if (isLoan) 'kind': kind,
    if (isLoan) 'loan': loan,
  };

  Map<String, dynamic> toCreateJson() => {
    'name': name,
    'direction': direction.toJson(),
    'amount': moneyToJson(amount),
    'startDate': formatDate(startDate),
    'recurrenceMode': recurrenceMode.toJson(),
    if (interval != null) 'interval': interval,
    if (unit != null) 'unit': unit!.toJson(),
    // The structured rule (rule, interval, days); the server prefers it.
    'frequency': frequency.toJson(),
    'endMode': endMode.toJson(),
    if (endDate != null) 'endDate': formatDate(endDate!),
    if (occurrenceCount != null) 'occurrenceCount': occurrenceCount,
    'enabled': enabled,
    // Always sent: null on a patch turns a transfer back into a plain series.
    'transferToStreamId': transfer?.peerStreamId,
    // The category (its name and colour come from it); the name above is
    // its legacy alias for older servers. No `color`: on the server that
    // would recolour the whole category.
    if (categoryId != null) 'categoryId': categoryId,
  };

  BudgetEvent copyWith({
    String? id,
    String? streamId,
    String? name,
    EventDirection? direction,
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
    String? color,
    bool clearColor = false,
    List<int>? days,
    String? categoryId,
    bool? categoryHidden,
  }) {
    return BudgetEvent(
      categoryId: categoryId ?? this.categoryId,
      categoryHidden: categoryHidden ?? this.categoryHidden,
      days: days ?? this.days,
      color: clearColor ? null : (color ?? this.color),
      version: clearVersion ? null : (version ?? this.version),
      transfer: clearTransfer ? null : (transfer ?? this.transfer),
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
      overrides: overrides,
      kind: kind,
      loan: loan,
    );
  }
}

/// "#RRGGBB" (uppercase) from "#rrggbb" / "rrggbb"; null for anything
/// else (an unknown value falls back to the positional colour).
String? normalizeEventColor(Object? raw) {
  if (raw is! String) return null;
  final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(raw.trim());
  return m == null ? null : '#${m[1]!.toUpperCase()}';
}

/// A once-off override of one occurrence's amount and direction.
class OccurrenceOverride {
  const OccurrenceOverride({required this.direction, required this.amount});

  final EventDirection direction;
  final Decimal amount;

  Decimal get signed => direction == EventDirection.credit ? amount : -amount;

  @override
  bool operator ==(Object other) =>
      other is OccurrenceOverride &&
      other.direction == direction &&
      other.amount == amount;

  @override
  int get hashCode => Object.hash(direction, amount);
}

/// The other side of a transfer, as seen from one series.
class TransferLink {
  const TransferLink({
    this.id,
    this.peerEventId,
    required this.peerStreamId,
    this.peerStreamName,
    this.peerReadable = true,
  });

  /// False when I can't see the other stream (its names are withheld).
  final bool peerReadable;

  final String? id;
  final String? peerEventId;
  final String peerStreamId;
  final String? peerStreamName;

  factory TransferLink.fromJson(Map<String, dynamic> json) => TransferLink(
    id: json['id'] as String?,
    peerEventId: json['peerEventId'] as String?,
    peerStreamId: (json['peerStreamId'] as String?) ?? '',
    peerStreamName: json['peerStreamName'] as String?,
    peerReadable: json['peerReadable'] as bool? ?? true,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'peerEventId': peerEventId,
    'peerStreamId': peerStreamId,
    'peerStreamName': peerStreamName,
    'peerReadable': peerReadable,
  };

  String get streamLabel =>
      !peerReadable ? 'Private stream' : (peerStreamName ?? 'another stream');
}

/// The other stream of a transfer, from this side: "From: Everyday"
/// (money in) / "To: Savings" (money out).
String transferPhrase(BudgetEvent t) {
  final link = t.transfer;
  if (link == null) return '';
  final dir = t.direction == EventDirection.debit ? 'To' : 'From';
  return '$dir: ${link.streamLabel}';
}

/// Timeline / popup label: transfers add the other stream, e.g.
/// "Top up · From: Everyday" (in) / "Top up · To: Savings" (out); an
/// unnamed transfer is just "From: Everyday".
String eventLabel(BudgetEvent t) {
  if (t.transfer == null) return t.name;
  final name = t.name.trim();
  final tail = transferPhrase(t);
  return name.isEmpty ? tail : '$name · $tail';
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
    required this.eventId,
    required this.date,
    required this.signedDelta,
    this.skipped = false,
    this.streamId,
    this.netted = false,
    this.component,
    this.derived = false,
    this.payout = false,
    this.flat = false,
  });

  final String eventId;
  final DateTime date;
  final Decimal signedDelta;
  final bool skipped;

  /// "interest" for a loan's interest charge.
  final String? component;

  /// Computed by the server's loan walk, not a stored occurrence: no skip,
  /// override or trim actions.
  final bool derived;

  /// The interest charged on the day a loan was paid off.
  final bool payout;

  /// A flat-rate loan's interest instalment.
  final bool flat;

  /// Combined view: the other stream this occurrence belongs to (null: the
  /// stream being viewed).
  final String? streamId;

  /// Combined view: a transfer between two included streams. It still shows,
  /// but nets out of the day's money in / out.
  final bool netted;

  Occurrence tagged({String? streamId, bool netted = false}) => Occurrence(
    eventId: eventId,
    date: date,
    signedDelta: signedDelta,
    skipped: skipped,
    streamId: streamId,
    netted: netted,
    component: component,
    derived: derived,
    payout: payout,
    flat: flat,
  );

  factory Occurrence.fromJson(Map<String, dynamic> json) {
    return Occurrence(
      eventId: (json['eventId'] ?? json['event_id']) as String,
      date: parseDate(json['date']),
      signedDelta: parseMoney(
        json['signedDelta'] ?? json['signed_delta'] ?? '0',
      ),
      skipped: (json['skipped'] as bool?) ?? false,
      component: json['component'] as String?,
      derived: json['derived'] == true,
      payout: json['payout'] == true,
      flat: json['flat'] == true,
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

/// The six event-planning variables the solver can fill in (§4.1).
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
    SolveVar.amount => 'amount each time',
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

  /// Balance target mode: the stream balance wanted on [endDate]; the
  /// server sets the total to `target − projected balance`.
  final Decimal? targetBalance;

  final String name;
  final EventDirection direction;
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
    this.event,
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

  /// Balance target already met without a new event.
  final bool onTrack;

  /// Null while the inputs are not yet enough to determine an event.
  final BudgetEvent? event;
  final List<Occurrence> previewOccurrences;
  final SolveValues values;

  /// Variables the server calculated rather than received.
  final Set<SolveVar> solved;

  /// How many more values the user must fill in, when [event] is null.
  final int needsMore;
  final List<SolveVar> needsOneOf;
  final String? message;

  bool get isComplete => event != null;

  factory SolveResult.fromJson(Map<String, dynamic> json) {
    List<SolveVar> vars(String key) => [
      for (final raw in (json[key] as List? ?? const []))
        ?SolveVar.tryParse(raw.toString()),
    ];
    final eventJson = json['event'];
    final valuesJson = json['values'];
    final previewRaw = json['previewOccurrences'] as List? ?? const [];
    return SolveResult(
      event: eventJson is Map<String, dynamic>
          ? BudgetEvent.fromJson(eventJson)
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

/// Lowest point and runway from `GET /streams/:id/insights`.
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

/// An event category of a stream (the server's `categories`): every event
/// has exactly one; its name is the events' name and its colour their
/// graph lines'. Names are unique per stream (case-insensitive, trimmed).
class Category {
  const Category({
    required this.id,
    required this.streamId,
    required this.name,
    required this.color,
    this.hidden = false,
    this.eventCount = 0,
    this.version,
  });

  final String id;
  final String streamId;
  final String name;

  /// "#RRGGBB".
  final String color;

  /// Hidden from the timeline and left out of the balance (eye menu).
  final bool hidden;

  /// Events in it when listed (the live count comes from the events).
  final int eventCount;
  final int? version;

  factory Category.fromJson(Map<String, dynamic> j) => Category(
    id: j['id'] as String,
    streamId: (j['streamId'] ?? '') as String,
    name: (j['name'] ?? '') as String,
    color: normalizeEventColor(j['color']) ?? '#3D6FD8',
    hidden: (j['hidden'] as bool?) ?? false,
    eventCount: (j['eventCount'] as num?)?.toInt() ?? 0,
    version: (j['version'] as num?)?.toInt(),
  );

  Category copyWith({String? name, String? color, bool? hidden}) => Category(
    id: id,
    streamId: streamId,
    name: name ?? this.name,
    color: color ?? this.color,
    hidden: hidden ?? this.hidden,
    eventCount: eventCount,
    version: version,
  );
}

/// Longest category name (the server's limit).
const int maxCategoryNameLength = 60;

/// [raw] as the server stores a category name: trimmed, inner runs of
/// spaces collapsed.
String normalizeCategoryName(String raw) =>
    raw.trim().replaceAll(RegExp(r'\s+'), ' ');

/// Natural, case-insensitive order of category names ("Bill 2" before
/// "Bill 10", "apple" beside "Apple"); ties fall back to the exact text.
int compareCategoryNames(String a, String b) {
  final x = a.toLowerCase(), y = b.toLowerCase();
  var i = 0, j = 0;
  bool digit(int c) => c >= 0x30 && c <= 0x39;
  while (i < x.length && j < y.length) {
    final cx = x.codeUnitAt(i), cy = y.codeUnitAt(j);
    if (digit(cx) && digit(cy)) {
      var ei = i, ej = j;
      while (ei < x.length && digit(x.codeUnitAt(ei))) {
        ei++;
      }
      while (ej < y.length && digit(y.codeUnitAt(ej))) {
        ej++;
      }
      final nx = x.substring(i, ei).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      final ny = y.substring(j, ej).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      if (nx.length != ny.length) return nx.length - ny.length;
      final c = nx.compareTo(ny);
      if (c != 0) return c;
      i = ei;
      j = ej;
      continue;
    }
    if (cx != cy) return cx - cy;
    i++;
    j++;
  }
  final rest = (x.length - i) - (y.length - j);
  if (rest != 0) return rest;
  return a.compareTo(b);
}

/// [list] sorted by name with [compareCategoryNames] (a new list): the
/// order every category list shows.
List<Category> sortedCategories(Iterable<Category> list) =>
    [...list]..sort((a, b) => compareCategoryNames(a.name, b.name));

/// Why [raw] can't name a new (or renamed, [except] = its id) category of
/// [existing]; null when it can.
String? categoryNameProblem(
  String raw,
  Iterable<Category> existing, {
  String? except,
}) {
  final name = normalizeCategoryName(raw);
  if (name.isEmpty) return 'Enter a name';
  if (name.length > maxCategoryNameLength) {
    return 'At most $maxCategoryNameLength characters';
  }
  final lower = name.toLowerCase();
  for (final c in existing) {
    if (c.id != except && c.name.toLowerCase() == lower) {
      return 'A category named "${c.name}" already exists';
    }
  }
  return null;
}
