import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pinchAxisFor', () {
    test('vertical fingers scale balance', () {
      expect(pinchAxisFor(const Offset(5, 200)), PinchAxis.balance);
      expect(pinchAxisFor(const Offset(-50, -120)), PinchAxis.balance);
    });
    test('horizontal fingers scale time', () {
      expect(pinchAxisFor(const Offset(200, 10)), PinchAxis.time);
      expect(pinchAxisFor(const Offset(-150, 60)), PinchAxis.time);
    });
    test('diagonal scales both', () {
      expect(pinchAxisFor(const Offset(100, 100)), PinchAxis.both);
      expect(pinchAxisFor(Offset.zero), PinchAxis.time);
    });
  });

  group('includeZero', () {
    test('keeps ranges already spanning zero', () {
      final r = includeZero(const BalanceExtents(-10, 50));
      expect([r.min, r.max], [-10, 50]);
    });
    test('extends all-positive and all-negative ranges past zero', () {
      final p = includeZero(const BalanceExtents(1000, 5000));
      expect(p.min, lessThan(0));
      expect(p.max, 5000);
      final n = includeZero(const BalanceExtents(-800, -200));
      expect(n.min, -800);
      expect(n.max, greaterThan(0));
    });
    test('fits include the origin', () {
      final r = paddedRange(4000, 9000, include: const [0]);
      expect(r.min, lessThan(0));
      expect(r.max, greaterThan(9000));
    });
  });

  test('y-scale buttons zoom around the centre', () {
    const r = BalanceExtents(0, 100);
    final zin = zoomBalanceRange(r, 1 / yScaleStep, 0.5);
    expect((zin.min + zin.max) / 2, closeTo(50, 1e-9));
    expect(zin.max - zin.min, closeTo(80, 1e-9));
    final zout = zoomBalanceRange(r, yScaleStep, 0.5);
    expect(zout.max - zout.min, closeTo(125, 1e-9));
  });

  test('eased ranges keep the centre fixed every frame', () {
    const a = BalanceExtents(-100, 300), b = BalanceExtents(50, 150);
    for (final t in [0.0, 0.25, 0.5, 0.9, 1.0]) {
      final r = lerpBalanceRange(a, b, t);
      expect((r.min + r.max) / 2, closeTo(100, 1e-9));
    }
    expect(lerpBalanceRange(a, b, 1).min, closeTo(50, 1e-9));
    expect(lerpVisibleDays(21, 365, 0), closeTo(21, 1e-9));
    expect(lerpVisibleDays(21, 365, 1), closeTo(365, 1e-9));
  });
}
