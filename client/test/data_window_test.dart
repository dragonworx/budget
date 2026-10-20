import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nextDataWindow grows near the edges, keeps it otherwise', () {
    final from = DateTime(2026, 1, 1), to = DateTime(2026, 12, 31);
    expect(nextDataWindow(from, to, DateTime(2026, 6, 1), 30), (from, to));
    final (f, t) = nextDataWindow(from, to, DateTime(2026, 12, 10), 30);
    expect(f, from);
    expect(t, DateTime(2027, 3, 10));
  });

  test('a long pan never loads more than maxDataWindowDays', () {
    var (from, to) = (DateTime(2026, 1, 1), DateTime(2026, 3, 1));
    var start = DateTime(2026, 1, 15);
    var maxSpan = 0;
    // Pan right a week at a time for 150 years.
    for (var i = 0; i < 52 * 150; i++) {
      start = DateTime(start.year, start.month, start.day + 7);
      (from, to) = nextDataWindow(from, to, start, 30);
      final span = to.difference(from).inDays;
      if (span > maxSpan) maxSpan = span;
      expect(!from.isAfter(start), isTrue);
      expect(!to.isBefore(addDays(start, 30)), isTrue);
    }
    expect(maxSpan, lessThanOrEqualTo(maxDataWindowDays + 60));
    expect(to.difference(from).inDays, lessThanOrEqualTo(maxDataWindowDays));
  });
}
