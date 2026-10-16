import 'models.dart';

/// Frequency presets for the transaction editor and Plan sheet. Each maps to
/// the existing recurrence model (once, or every [interval] [unit]), so no
/// schema change; anything else is [custom]. Steps mirror the timeline's
/// view units (Day … Year), worded as frequencies.
enum FrequencyPreset {
  once('Once', null, null),
  daily('Daily', 1, RecurrenceUnit.days),
  weekly('Weekly', 1, RecurrenceUnit.weeks),
  fortnightly('Fortnightly', 2, RecurrenceUnit.weeks),
  weeks3('Every 3 weeks', 3, RecurrenceUnit.weeks),
  monthly('Monthly', 1, RecurrenceUnit.months),
  months2('Every 2 months', 2, RecurrenceUnit.months),
  quarterly('Quarterly', 3, RecurrenceUnit.months),
  months6('Every 6 months', 6, RecurrenceUnit.months),
  yearly('Yearly', 1, RecurrenceUnit.years),
  custom('Custom…', null, null);

  const FrequencyPreset(this.label, this.interval, this.unit);
  final String label;
  final int? interval;
  final RecurrenceUnit? unit;

  bool get repeats => interval != null;

  /// Presets that repeat (no Once / Custom).
  static List<FrequencyPreset> get repeating => [
    for (final p in values)
      if (p.repeats) p,
  ];

  /// The preset for a schedule, or [custom] when none matches.
  static FrequencyPreset of({
    required bool once,
    int? interval,
    RecurrenceUnit? unit,
  }) {
    if (once) return FrequencyPreset.once;
    final n = interval ?? 1;
    for (final p in values) {
      if (p.repeats && p.interval == n && p.unit == unit) return p;
    }
    return FrequencyPreset.custom;
  }
}
