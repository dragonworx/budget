import 'package:budget_client/data/frequency.dart';
import 'package:budget_client/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every repeating preset maps to interval + unit and back', () {
    for (final p in FrequencyPreset.repeating) {
      expect(
        FrequencyPreset.of(once: false, interval: p.interval, unit: p.unit),
        p,
        reason: p.label,
      );
    }
  });

  test('specific mappings', () {
    expect(FrequencyPreset.fortnightly.interval, 2);
    expect(FrequencyPreset.fortnightly.unit, RecurrenceUnit.weeks);
    expect(FrequencyPreset.quarterly.interval, 3);
    expect(FrequencyPreset.quarterly.unit, RecurrenceUnit.months);
    expect(FrequencyPreset.months6.interval, 6);
    expect(FrequencyPreset.yearly.unit, RecurrenceUnit.years);
  });

  test('once, defaults and custom', () {
    expect(FrequencyPreset.of(once: true), FrequencyPreset.once);
    expect(
      FrequencyPreset.of(once: false, unit: RecurrenceUnit.months),
      FrequencyPreset.monthly,
    );
    expect(
      FrequencyPreset.of(once: false, interval: 5, unit: RecurrenceUnit.weeks),
      FrequencyPreset.custom,
    );
    expect(
      FrequencyPreset.of(once: false, interval: 2, unit: RecurrenceUnit.days),
      FrequencyPreset.custom,
    );
    expect(
      FrequencyPreset.of(
        once: false,
        interval: 12,
        unit: RecurrenceUnit.months,
      ),
      FrequencyPreset.custom,
    );
  });
}
