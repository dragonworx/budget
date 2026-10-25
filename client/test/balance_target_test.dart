import 'package:budget_client/data/models.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('target balance replaces target total in the request', () {
    final json = SolveRequest(
      name: 'Save',
      direction: EventDirection.credit,
      unit: RecurrenceUnit.weeks,
      endDate: DateTime(2027, 6, 1),
      targetTotal: Decimal.parse('100'),
      targetBalance: Decimal.parse('5000'),
    ).toJson();
    expect(json['targetBalance'], isNotNull);
    expect(json.containsKey('targetTotal'), isFalse);
  });

  test('parses balance target info and on-track status', () {
    final r = SolveResult.fromJson({
      'status': 'onTrack',
      'message': 'Already on track',
      'balanceTarget': {
        'targetBalance': '500',
        'projectedBalance': '900',
        'gap': '-400',
      },
    });
    expect(r.onTrack, isTrue);
    expect(r.isComplete, isFalse);
    expect(r.balanceTarget!.gap, Decimal.parse('-400'));
  });
}
