import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const range = BalanceExtents(-1000, 9000);

  test('vertical pan keeps the span and moves by the dragged fraction', () {
    final down = panBalanceRange(range, 50, 500); // drag down 10%
    expect(down.min, closeTo(0, 1e-9));
    expect(down.max, closeTo(10000, 1e-9));
    final back = panBalanceRange(down, -50, 500);
    expect(back.min, closeTo(range.min, 1e-9));
    expect(back.max, closeTo(range.max, 1e-9));
  });

  test('vertical zoom keeps the anchored balance fixed', () {
    // Anchor at 0.1 of the range = balance 0.
    final zoomed = zoomBalanceRange(range, 0.5, 0.1);
    expect(zoomed.max - zoomed.min, closeTo(5000, 1e-9));
    expect(zoomed.min + 0.1 * (zoomed.max - zoomed.min), closeTo(0, 1e-9));
  });

  test('vertical zoom is clamped', () {
    final tiny = zoomBalanceRange(range, 1e-12, 0.5);
    expect(tiny.max - tiny.min, closeTo(minBalanceSpan, 1e-12));
    final huge = zoomBalanceRange(range, 1e12, 0.5);
    expect(huge.max - huge.min, closeTo(maxBalanceSpan, 1));
  });

  test('a time pan alone never changes the balance range', () {
    // The range is view state: panning time feeds it through untouched.
    var r = range;
    for (var i = 0; i < 20; i++) {
      r = panBalanceRange(r, 0, 500);
    }
    expect(r.min, range.min);
    expect(r.max, range.max);
  });
}
