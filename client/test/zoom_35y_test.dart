// The 35-year zoom (spec 003 §15): zoom out stops at 12785 days, a 30-year
// saved view survives, the loaded window stays within its limit, and the
// Year row labels every 5th year when a year is too narrow.
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/saved_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('zoom out stops at 35 years', () {
    expect(maxVisibleDays, 12785);
    var view = (start: DateTime(2026, 1, 1), days: 7300.0);
    expect(canZoomOut(view.days), isTrue, reason: 'past the old 20 years');
    for (var i = 0; i < 20; i++) {
      view = zoomAboutCenter(view.start, view.days, zoomStep);
    }
    expect(view.days, 12785);
    expect(canZoomOut(view.days), isFalse);
  });

  test('a 30-year saved view loads as saved; beyond 35 years clamps', () {
    final v = SavedView.fromJson({'start': 20000, 'days': 10958})!;
    expect(v.days, 10958);
    expect(SavedView.fromJson({'start': 20000, 'days': 20000})!.days, 12785);
  });

  test('the data window at the widest zoom stays within its limit', () {
    expect(maxDataWindowDays, 3 * 12785);
    var from = DateTime(2020, 1, 1), to = DateTime(2060, 1, 1);
    var start = DateTime(2026, 1, 1);
    for (var i = 0; i < 40; i++) {
      (from, to) = nextDataWindow(from, to, start, maxVisibleDays);
      expect(to.difference(from).inDays, lessThanOrEqualTo(maxDataWindowDays));
      expect(from.isAfter(start), isFalse);
      expect(to.isBefore(start.add(const Duration(days: 12785))), isFalse);
      start = start.add(const Duration(days: 2000));
    }
  });

  test('Year row: every year while it fits, else every 5th', () {
    expect(yearLabelEvery(1200, 7300), 1);
    expect(yearLabelEvery(280, 12785), 5);
    final segs = yearSegments(
      DateTime(2026, 6, 1),
      DateTime(2061, 6, 1),
      every: 5,
    );
    expect(segs.first.start, DateTime(2025));
    expect(segs.map((s) => s.start.year % 5).toSet(), {0});
    expect(segs.last.end, DateTime(2065));
    // Every year as before.
    final one = yearSegments(DateTime(2026, 6, 1), DateTime(2028, 2, 1));
    expect([for (final s in one) s.start.year], [2026, 2027, 2028]);
  });
}
