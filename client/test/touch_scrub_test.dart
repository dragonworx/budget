import 'dart:ui';

import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('nearestPointIndex', () {
    const pts = [Offset(10, 10), Offset(50, 10), Offset(50, 60)];

    test('empty list gives null', () {
      expect(nearestPointIndex(const [], Offset.zero), isNull);
    });

    test('picks nearest by 2D distance, not just x', () {
      // Same x as two points; y decides.
      expect(nearestPointIndex(pts, const Offset(50, 50)), 2);
      expect(nearestPointIndex(pts, const Offset(48, 20)), 1);
      expect(nearestPointIndex(pts, const Offset(0, 0)), 0);
    });

    test('respects max distance', () {
      expect(
        nearestPointIndex(pts, const Offset(10, 40), maxDistance: 28),
        isNull,
      );
      expect(nearestPointIndex(pts, const Offset(10, 30), maxDistance: 28), 0);
      // Exactly on the boundary counts.
      expect(nearestPointIndex(pts, const Offset(10, 38), maxDistance: 28), 0);
    });

    test('ties keep the earlier point', () {
      expect(nearestPointIndex(pts, const Offset(30, 10)), 0);
    });

    test('touch hit radius is a fingertip; mouse stays precise', () {
      expect(vertexHitRadius(PointerDeviceKind.touch), 44);
      expect(vertexHitRadius(PointerDeviceKind.stylus), 44);
      expect(
        vertexHitRadius(PointerDeviceKind.mouse),
        inInclusiveRange(16, 20),
      );
      expect(
        vertexHitRadius(PointerDeviceKind.trackpad),
        inInclusiveRange(16, 20),
      );
      expect(scrubStartRadius, touchVertexHitRadius);
      expect(scrubMaxDistance, greaterThan(scrubStartRadius));
    });

    test('a touch 38px off still picks the closest dot; 50px misses', () {
      const dots = [Offset(100, 100), Offset(200, 100)];
      final r = vertexHitRadius(PointerDeviceKind.touch);
      expect(
        nearestPointIndex(dots, const Offset(138, 100), maxDistance: r),
        0,
      );
      expect(
        nearestPointIndex(dots, const Offset(162, 100), maxDistance: r),
        1,
      );
      expect(
        nearestPointIndex(dots, const Offset(100, 150), maxDistance: r),
        isNull,
      );
      final m = vertexHitRadius(PointerDeviceKind.mouse);
      expect(
        nearestPointIndex(dots, const Offset(130, 100), maxDistance: m),
        isNull,
      );
    });
  });

  group('touchTooltipOrigin', () {
    const bounds = Size(400, 700);
    const size = Size(260, 120);

    test('sits above the finger, centred, clear of it', () {
      final o = touchTooltipOrigin(
        finger: const Offset(200, 400),
        size: size,
        bounds: bounds,
        lift: 48,
      );
      expect(o.dx, 70);
      expect(o.dy + size.height, lessThanOrEqualTo(400 - 48));
    });

    test('flips below when no room above', () {
      final o = touchTooltipOrigin(
        finger: const Offset(200, 60),
        size: size,
        bounds: bounds,
        lift: 48,
      );
      expect(o.dy, greaterThanOrEqualTo(60 + 48));
    });

    test('clamps horizontally inside bounds', () {
      final l = touchTooltipOrigin(
        finger: const Offset(5, 400),
        size: size,
        bounds: bounds,
      );
      final r = touchTooltipOrigin(
        finger: const Offset(398, 400),
        size: size,
        bounds: bounds,
      );
      expect(l.dx, 4);
      expect(r.dx + size.width, 396);
    });

    test('never escapes a tiny viewport', () {
      final o = touchTooltipOrigin(
        finger: const Offset(100, 100),
        size: size,
        bounds: const Size(200, 150),
      );
      expect(o.dx, 4);
      expect(o.dy, greaterThanOrEqualTo(4));
    });
  });
}
