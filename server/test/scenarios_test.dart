import 'package:budget_server/api/scenarios.dart';
import 'package:test/test.dart';

void main() {
  final req = {
    'solveFor': 'amount',
    'mode': 'onDate',
    'targetBalance': 5000,
    'endDate': '2027-03-01',
    'today': '2026-10-18',
  };

  test('create requires name and request; strips today', () {
    final b = parseScenarioBody({'name': ' Save for car ', 'request': req},
        create: true);
    expect(b.name, 'Save for car');
    expect(b.request!.containsKey('today'), isFalse);
    expect(b.request!['solveFor'], 'amount');
    expect(() => parseScenarioBody({'request': req}, create: true),
        throwsFormatException);
    expect(() => parseScenarioBody({'name': 'x'}, create: true),
        throwsFormatException);
  });

  test('patch fields are optional but validated', () {
    final b = parseScenarioBody({'included': false}, create: false);
    expect(b.included, isFalse);
    expect(b.name, isNull);
    expect(b.request, isNull);
    expect(() => parseScenarioBody({'colorIndex': 9}, create: false),
        throwsFormatException);
    expect(() => parseScenarioBody({'name': 'x' * 81}, create: false),
        throwsFormatException);
  });

  test('an invalid goal request is rejected', () {
    expect(
      () => parseScenarioBody({
        'name': 'bad',
        'request': {'solveFor': 'nonsense'},
      }, create: true),
      throwsA(anything),
    );
  });
}
