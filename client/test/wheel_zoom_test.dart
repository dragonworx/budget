import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('wheel up zooms in, down zooms out, symmetric', () {
    expect(wheelZoomFactor(-100), lessThan(1));
    expect(wheelZoomFactor(100), greaterThan(1));
    expect(wheelZoomFactor(100) * wheelZoomFactor(-100), closeTo(1, 1e-9));
    expect(wheelZoomFactor(0), 1);
  });
  test('per-event delta is clamped', () {
    expect(wheelZoomFactor(10000), wheelZoomFactor(240));
  });
}
