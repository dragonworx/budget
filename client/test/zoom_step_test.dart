// Also run under TZ=Australia/Sydney to cover DST spans.
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

double centerOf(DateTime start, double days) => dayCoord(start) + days / 2;

void main() {
  test('one step zooms by 1.25x and keeps the centre date fixed', () {
    final start = DateTime(2026, 9, 28, 6); // spans the AU DST change
    const days = 14.0;
    final c0 = centerOf(start, days);
    final out = zoomAboutCenter(start, days, zoomStep);
    expect(out.days, closeTo(17.5, 1e-9));
    expect(centerOf(out.start, out.days), closeTo(c0, 1e-6));
    final back = zoomAboutCenter(out.start, out.days, 1 / zoomStep);
    expect(back.days, closeTo(days, 1e-9));
    expect(centerOf(back.start, back.days), closeTo(c0, 1e-6));
  });

  test('many in/out steps never drift the centre', () {
    var v = (start: DateTime(2026, 3, 30), days: 60.0);
    final c0 = centerOf(v.start, v.days);
    for (var i = 0; i < 40; i++) {
      v = zoomAboutCenter(
        v.start,
        v.days,
        i % 3 == 0 ? zoomStep : 1 / zoomStep,
      );
      expect(centerOf(v.start, v.days), closeTo(c0, 1e-5));
    }
  });

  test('clamps to the 3 day / 20 year limits around the same centre', () {
    var v = (start: DateTime(2026, 1, 1), days: 7.0);
    final c0 = centerOf(v.start, v.days);
    for (var i = 0; i < 10; i++) {
      v = zoomAboutCenter(v.start, v.days, 1 / zoomStep);
    }
    expect(v.days, minVisibleDays);
    expect(canZoomIn(v.days), isFalse);
    expect(centerOf(v.start, v.days), closeTo(c0, 1e-6));
    for (var i = 0; i < 60; i++) {
      v = zoomAboutCenter(v.start, v.days, zoomStep);
    }
    expect(v.days, maxVisibleDays);
    expect(canZoomOut(v.days), isFalse);
    expect(centerOf(v.start, v.days), closeTo(c0, 1e-5));
  });
}
