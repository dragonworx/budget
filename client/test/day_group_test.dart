import 'package:flutter_test/flutter_test.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/data/models.dart';
import 'package:decimal/decimal.dart';

Occurrence occ(DateTime d, int v, {bool skipped = false}) => Occurrence(
  eventId: 't$v',
  date: d,
  signedDelta: Decimal.fromInt(v),
  skipped: skipped,
);

void main() {
  test('groups same-day occurrences, skipped excluded from count/net', () {
    final d = DateTime(2026, 11, 3);
    final gs = groupByDay([
      occ(d, 1200),
      occ(DateTime(2026, 11, 1), -50),
      occ(d, -200),
      occ(d, -999, skipped: true),
    ]);
    expect(gs.length, 2);
    expect(gs.first.day, DateTime(2026, 11, 1));
    final g = gs[1];
    expect(g.all.length, 3);
    expect(g.count, 2);
    expect(g.net, 1000);
    expect(g.mixed, isTrue);
    expect(g.allSkipped, isFalse);
  });
  test('all skipped day', () {
    final g = groupByDay([occ(DateTime(2026, 1, 1), 5, skipped: true)]).single;
    expect(g.allSkipped, isTrue);
    expect(g.mixed, isFalse);
  });
  test('count pill width: round minimum, padded for wide numbers', () {
    expect(countPillWidth(6), 18);
    expect(countPillWidth(20), 30);
  });
}
