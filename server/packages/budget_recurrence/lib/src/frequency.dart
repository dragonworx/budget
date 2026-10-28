/// The six frequency rules (plus N), stored as `freq_rule` / `freq_interval`
/// / `freq_days`.
///
/// * [once]: the start date only.
/// * [daily]: every N days from the start (N is 1 in the picker; N > 1 only
///   for events saved before the structured model, kept losslessly).
/// * [weekly] / [everyNWeeks]: every week / every N weeks. Weeks are counted
///   from the Monday-based week that contains the start date: the live
///   weeks are that week + k·N. No days: the start date's own weekday in
///   each live week (so start + 7·k·N, as before). Days (ISO weekdays
///   1 = Mon … 7 = Sun): those weekdays in each live week, never before the
///   start date.
/// * [monthly] / [everyNMonths]: every month / every N months counted from
///   the start month. No days: the start date's day-of-month each live month
///   (rolled to the month's last day when short, always measured from the
///   start's own day, so 31 Jan → 29 Feb → 31 Mar). Days (1–31): those
///   days in each live month, a day past the month's end rolling to its last
///   day (two days rolling to the same date fire once), never before the
///   start date.
enum FreqRule {
  once('once'),
  daily('daily'),
  weekly('weekly'),
  everyNWeeks('every_n_weeks'),
  monthly('monthly'),
  everyNMonths('every_n_months');

  const FreqRule(this.apiName);

  /// The wire / DB value.
  final String apiName;

  bool get weekFamily => this == weekly || this == everyNWeeks;
  bool get monthFamily => this == monthly || this == everyNMonths;

  /// Whether the rule takes day chips (weekdays or month-days).
  bool get takesDays => weekFamily || monthFamily;

  /// Whether the rule carries N (> 1) in the picker.
  bool get takesInterval => this == everyNWeeks || this == everyNMonths;

  static FreqRule parse(String value) {
    final v = value.trim();
    for (final r in values) {
      if (r.apiName == v || r.name == v) return r;
    }
    throw FormatException('Invalid frequency rule: $value');
  }
}

/// Largest N accepted for every N days / weeks / months.
const int maxFrequencyInterval = 999;

/// One canonical frequency: [rule], [interval] (N, 1 for the plain rules)
/// and [days] (sorted ascending, unique; empty = the rule's natural cadence
/// from the start date, no day restriction).
class Frequency {
  const Frequency._(this.rule, this.interval, this.days);

  /// Validated and canonicalised: weekly with N > 1 becomes every N weeks
  /// (and every N weeks with N = 1 becomes weekly; likewise months); days
  /// are deduplicated and sorted. Throws [FormatException] for days on a
  /// rule that takes none, out-of-range days or N.
  factory Frequency(
    FreqRule rule, {
    int interval = 1,
    Iterable<int> days = const [],
  }) {
    if (interval < 1 || interval > maxFrequencyInterval) {
      throw FormatException(
        'Frequency interval must be 1–$maxFrequencyInterval',
      );
    }
    final sorted = days.toSet().toList()..sort();
    switch (rule) {
      case FreqRule.once:
        if (interval != 1) {
          throw const FormatException('A one-off has no interval');
        }
      case FreqRule.daily:
        break;
      case FreqRule.weekly:
      case FreqRule.everyNWeeks:
        rule = interval == 1 ? FreqRule.weekly : FreqRule.everyNWeeks;
        if (sorted.any((d) => d < 1 || d > 7)) {
          throw const FormatException('Weekdays must be 1 (Mon) – 7 (Sun)');
        }
      case FreqRule.monthly:
      case FreqRule.everyNMonths:
        rule = interval == 1 ? FreqRule.monthly : FreqRule.everyNMonths;
        if (sorted.any((d) => d < 1 || d > 31)) {
          throw const FormatException('Month days must be 1–31');
        }
    }
    if (!rule.takesDays && sorted.isNotEmpty) {
      throw FormatException('Days are only allowed for weekly and monthly '
          'rules, not ${rule.apiName}');
    }
    return Frequency._(rule, interval, List.unmodifiable(sorted));
  }

  static const Frequency once = Frequency._(FreqRule.once, 1, []);

  final FreqRule rule;
  final int interval;
  final List<int> days;

  bool get repeats => rule != FreqRule.once;

  /// From the pre-structured model: `recurrence_mode` once / every with
  /// `interval` + `unit` (days, weeks, months, years). Years become every
  /// 12·N months (the same dates: both step from the start's own day).
  factory Frequency.fromLegacy({
    required bool once,
    int? interval,
    String? unit,
    Iterable<int> days = const [],
  }) {
    if (once) return Frequency(FreqRule.once, days: days);
    final n = interval ?? 1;
    return switch (unit) {
      'days' => Frequency(FreqRule.daily, interval: n, days: days),
      'weeks' => Frequency(FreqRule.weekly, interval: n, days: days),
      'months' => Frequency(FreqRule.monthly, interval: n, days: days),
      'years' => Frequency(FreqRule.monthly, interval: n * 12, days: days),
      _ => throw FormatException('Invalid unit: $unit'),
    };
  }

  /// The legacy columns kept in sync for older readers: unit "days",
  /// "weeks" or "months" (null for a one-off).
  String? get legacyUnit => switch (rule) {
        FreqRule.once => null,
        FreqRule.daily => 'days',
        FreqRule.weekly || FreqRule.everyNWeeks => 'weeks',
        FreqRule.monthly || FreqRule.everyNMonths => 'months',
      };

  /// The legacy interval (null for a one-off).
  int? get legacyInterval => repeats ? interval : null;

  /// A copy with other days (same rule and N), canonicalised.
  Frequency withDays(Iterable<int> d) =>
      Frequency(rule, interval: interval, days: d);

  /// `{"rule": "every_n_weeks", "interval": 2, "days": [1, 3]}`.
  Map<String, Object> toJson() => {
        'rule': rule.apiName,
        'interval': interval,
        'days': days,
      };

  /// Reads [toJson]'s shape (a rule name, optional interval and days).
  factory Frequency.fromJson(Map<String, dynamic> json) {
    final rawDays = json['days'];
    if (rawDays != null && rawDays is! List) {
      throw const FormatException('frequency.days must be a list');
    }
    final rule = json['rule'];
    if (rule is! String) {
      throw const FormatException('frequency.rule must be a rule name');
    }
    return Frequency(
      FreqRule.parse(rule),
      interval: _int(json['interval']) ?? 1,
      days: [
        for (final d in (rawDays as List?) ?? const [])
          _int(d) ?? (throw const FormatException('Days must be numbers')),
      ],
    );
  }

  static int? _int(Object? v) => switch (v) {
        null => null,
        final int i => i,
        final num n when n == n.roundToDouble() => n.toInt(),
        final String s => int.tryParse(s.trim()) ??
            (throw FormatException('Not a whole number: $s')),
        _ => throw FormatException('Not a whole number: $v'),
      };

  @override
  bool operator ==(Object other) =>
      other is Frequency &&
      other.rule == rule &&
      other.interval == interval &&
      _sameList(other.days, days);

  @override
  int get hashCode => Object.hash(rule, interval, Object.hashAll(days));

  @override
  String toString() => 'Frequency(${rule.apiName}, $interval, $days)';
}

bool _sameList(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
