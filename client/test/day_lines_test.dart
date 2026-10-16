import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('day lines hidden under 10px per day', () {
    expect(dayLineOpacity(0), 0);
    expect(dayLineOpacity(9.99), 0);
    expect(dayLineOpacity(double.nan), 0);
  });
  test('day lines fade in from 10px to full at 16px', () {
    expect(dayLineOpacity(10), greaterThan(0));
    expect(dayLineOpacity(13), greaterThan(dayLineOpacity(10)));
    expect(dayLineOpacity(13), lessThan(1));
    expect(dayLineOpacity(16), 1);
    expect(dayLineOpacity(200), 1);
  });
}
