import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

BalancePoint _p(DateTime d, int v) =>
    BalancePoint(date: d, closingBalance: Decimal.fromInt(v));

void main() {
  group('balanceExtentsFrom (global min/max)', () {
    final points = [
      _p(DateTime(2025, 1, 1), -999), // before seed: ignored
      _p(DateTime(2025, 2, 1), 100),
      _p(DateTime(2025, 6, 1), 5000),
      _p(DateTime(2025, 9, 1), -40),
      _p(DateTime(2025, 12, 1), 300),
    ];

    test('spans the whole series from the seed, not a view window', () {
      final e = balanceExtentsFrom(points, DateTime(2025, 2, 1))!;
      expect(e.min, -40);
      expect(e.max, 5000);
      // A narrow window around December would only see 300 / -40.
      final v = visibleBalance(
        points: points,
        viewStart: DateTime(2025, 11, 20),
        viewEnd: DateTime(2025, 12, 10),
        seedDate: DateTime(2025, 2, 1),
      )!;
      expect(v.extents.max, lessThan(e.max));
    });

    test('null when nothing on/after the seed', () {
      expect(balanceExtentsFrom(points, DateTime(2026, 1, 1)), isNull);
      expect(balanceExtentsFrom(const [], DateTime(2025, 1, 1)), isNull);
    });
  });

  group('day label plan', () {
    // Measured widths: "Wed"/"28th" ~ 26px, "W"/"28" ~ 13px.
    DayLabelPlan plan(double cell) =>
        dayLabelPlan(cellWidth: cell, fullWidth: 26, compactWidth: 13);

    test('full when weekday and ordinal fit', () {
      expect(plan(30), const DayLabelPlan(DayLabelForm.full));
      expect(plan(80), const DayLabelPlan(DayLabelForm.full));
    });
    test('compact (single letter, bare numeral) when narrower', () {
      expect(plan(29.9), const DayLabelPlan(DayLabelForm.compact));
      expect(plan(17), const DayLabelPlan(DayLabelForm.compact));
    });
    test('sparse numerals, never overlapping, when too narrow', () {
      expect(plan(16.9), const DayLabelPlan(DayLabelForm.sparse, 2));
      expect(plan(8.5), const DayLabelPlan(DayLabelForm.sparse, 2));
      expect(plan(6), const DayLabelPlan(DayLabelForm.sparse, 3));
      expect(plan(3), const DayLabelPlan(DayLabelForm.sparse, 7));
      for (final cell in [3.0, 6.0, 9.0, 16.0]) {
        final p = plan(cell);
        expect(cell * p.every, greaterThanOrEqualTo(13 + 4));
      }
    });
    test('thinned days are pan-stable; weekly thinning picks Mondays', () {
      final days = [for (var i = 0; i < 14; i++) DateTime(2026, 10, 1 + i)];
      final every2 = days.where((d) => dayLabelled(d, 2)).toList();
      expect(every2.length, 7);
      for (var i = 1; i < every2.length; i++) {
        expect(every2[i].difference(every2[i - 1]).inHours, closeTo(48, 1));
      }
      final weekly = days.where((d) => dayLabelled(d, 7));
      expect(weekly.every((d) => d.weekday == DateTime.monday), isTrue);
      expect(weekly.length, 2);
      expect(days.every((d) => dayLabelled(d, 1)), isTrue);
    });
    test('lane height is compact and constant', () {
      expect(dayLaneLabelHeight, 30);
    });
  });
}
