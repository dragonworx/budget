import 'package:budget_client/features/planning/goal_models.dart';
import 'package:budget_client/features/planning/scenarios_panel.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _v(String end) => {
  'startDate': '2026-10-19',
  'endDate': end,
  'startBalance': 1000,
  'targetBalance': 1000,
  'amount': 0,
  'interval': 1,
  'unit': 'weeks',
  'count': 0,
  'oneOff': 0,
  'rate': 0,
};

void main() {
  test('shiftText', () {
    expect(shiftText(0), 'same');
    expect(shiftText(21), '+3 wks');
    expect(shiftText(-5), '−5 days');
    expect(shiftText(1), '+1 day');
  });

  test('delta: balance and alert shift vs baseline', () {
    final r = GoalResult.fromJson({
      'solveFor': 'amount',
      'baselineEndBalance': 1000,
      'endBalance': 1420,
      'alertDate': '2027-03-12',
      'values': _v('2027-03-01'),
    });
    final d = scenarioDelta(r, DateTime(2027, 2, 19));
    expect(d.balance, closeTo(420, 1e-9));
    expect(d.alertShiftDays, 21);
    expect(
      scenarioDeltaText(r, DateTime(2027, 2, 19)),
      allOf(contains('+\$420'), contains('alert +3 wks')),
    );
  });

  test('delta: alert cleared only when the window covers it', () {
    final r = GoalResult.fromJson({
      'solveFor': 'amount',
      'baselineEndBalance': 0,
      'endBalance': 0,
      'values': _v('2027-03-01'),
    });
    expect(scenarioDelta(r, DateTime(2027, 2, 1)).alertCleared, isTrue);
    expect(scenarioDelta(r, DateTime(2027, 6, 1)).alertCleared, isFalse);
  });
}
