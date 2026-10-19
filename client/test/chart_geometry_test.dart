import 'dart:ui';

import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

BalancePoint _point(DateTime date, String amount) {
  return BalancePoint(date: date, closingBalance: Decimal.parse(amount));
}

void main() {
  test('ordinalDay gives every day of the month a unique suffixed label', () {
    final labels = [for (var d = 1; d <= 31; d++) ordinalDay(d)];
    expect(labels.toSet(), hasLength(31));
    expect(labels.sublist(0, 4), ['1st', '2nd', '3rd', '4th']);
    expect(labels.sublist(10, 13), ['11th', '12th', '13th']);
    expect(labels.sublist(20, 23), ['21st', '22nd', '23rd']);
    expect(labels.last, '31st');
  });

  test('fractional pan does not snap to midnight', () {
    final start = DateTime(2026, 6, 1);
    final next = addDays(start, 0.5);
    expect(next, DateTime(2026, 6, 1, 12));
    expect(addDays(next, -0.25), DateTime(2026, 6, 1, 6));
  });

  test('y extents use only the visible window', () {
    final visible = visibleBalance(
      points: [
        _point(DateTime(2026, 1, 1), '10'),
        _point(DateTime(2026, 1, 2), '50'),
        _point(DateTime(2026, 1, 3), '40'),
        _point(DateTime(2026, 1, 10), '9999'),
      ],
      viewStart: DateTime(2026, 1, 2),
      viewEnd: DateTime(2026, 1, 4),
      seedDate: DateTime(2026, 1, 1),
    );

    expect(visible, isNotNull);
    expect(visible!.extents.min, 40);
    expect(visible.extents.max, 50);
  });

  test('previous close is held into the window', () {
    final visible = visibleBalance(
      points: [
        _point(DateTime(2026, 1, 1), '10'),
        _point(DateTime(2026, 1, 5), '80'),
      ],
      viewStart: DateTime(2026, 1, 3),
      viewEnd: DateTime(2026, 1, 4),
      seedDate: DateTime(2026, 1, 1),
    );

    expect(visible!.extents.min, 10);
    expect(visible.extents.max, 10);
  });

  test('balances before the seed date are ignored', () {
    final visible = visibleBalance(
      points: [
        _point(DateTime(2026, 1, 1), '9999'),
        _point(DateTime(2026, 1, 5), '20'),
        _point(DateTime(2026, 1, 6), '30'),
      ],
      viewStart: DateTime(2026, 1, 5),
      viewEnd: DateTime(2026, 1, 7),
      seedDate: DateTime(2026, 1, 5),
    );

    expect(visible!.extents.min, 20);
    expect(visible.extents.max, 30);
  });

  test('padded range fits the data, pulling in extras only on request', () {
    final positive = paddedRange(59000, 74000);
    expect(positive.min, inInclusiveRange(55000, 59000));
    expect(positive.max, inInclusiveRange(74000, 78000));

    final withZero = paddedRange(100, 200, include: const [0]);
    expect(withZero.min, lessThan(0));
    expect(withZero.max, greaterThan(200));

    final negative = paddedRange(-200, -40);
    expect(negative.min, lessThan(-200));
    expect(negative.max, inExclusiveRange(-40, 0));

    final mixed = paddedRange(-25, 80);
    expect(mixed.min, lessThan(-25));
    expect(mixed.max, greaterThan(80));

    final flat = paddedRange(50, 50);
    expect(flat.min, lessThan(50));
    expect(flat.max, greaterThan(50));
    expect(flat.min, greaterThan(0));

    final zero = paddedRange(0, 0);
    expect(zero.min, lessThan(0));
    expect(zero.max, greaterThan(0));
  });

  test('months, weeks, and days segment on calendar boundaries', () {
    final months = monthSegments(DateTime(2026, 1, 15), DateTime(2026, 3, 2));
    expect(months.map((segment) => segment.start), [
      DateTime(2026, 1, 1),
      DateTime(2026, 2, 1),
      DateTime(2026, 3, 1),
    ]);
    expect(months.map((segment) => segment.colorIndex).toSet().length, 3);

    final weeks = weekSegments(DateTime(2026, 1, 7), DateTime(2026, 1, 8));
    expect(weeks.first.start, DateTime(2026, 1, 5));
    expect(weeks.first.end, DateTime(2026, 1, 12));

    final days = daySegments(DateTime(2026, 1, 5), DateTime(2026, 1, 8));
    expect(days, hasLength(3));
    expect(days.map((segment) => segment.colorIndex), [1, 2, 3]);
  });

  const labelPlot = Rect.fromLTWH(0, 0, 400, 200);
  double budget(
    Offset center,
    VertexLabelSide side, {
    Rect plot = labelPlot,
    List<Rect> occupied = const [],
    List<Offset> anchors = const [],
    double radius = 4,
  }) => vertexLabelTextBudget(
    plot: plot,
    center: center,
    radius: radius,
    side: side,
    labelHeight: 16,
    maxText: 160,
    minText: 18,
    pad: 10,
    occupied: occupied,
    anchors: [center, ...anchors],
  );

  test('labels sit flush left with the dot, directly above or below', () {
    const c = Offset(40, 100);
    final above = vertexLabelRect(
      center: c,
      radius: 4,
      side: VertexLabelSide.above,
      width: 60,
      height: 16,
    );
    final below = vertexLabelRect(
      center: c,
      radius: 4,
      side: VertexLabelSide.below,
      width: 60,
      height: 16,
    );
    expect(above.left, 36);
    expect(below.left, 36);
    expect(above.bottom, 100 - 4 - vertexLabelGap);
    expect(below.top, 100 + 4 + vertexLabelGap);
    expect(VertexLabelSide.values, [
      VertexLabelSide.above,
      VertexLabelSide.below,
    ]);
  });

  test('a label runs right until the next dot in its row', () {
    // Row above the dot spans y 77..97; the dot at (120, 90) is in it.
    expect(
      budget(
        const Offset(40, 100),
        VertexLabelSide.above,
        anchors: const [Offset(120, 90)],
      ),
      117 - 36 - 10,
    );
  });

  test('dots outside the label row do not shorten it', () {
    expect(
      budget(
        const Offset(40, 100),
        VertexLabelSide.above,
        anchors: const [Offset(120, 100), Offset(80, 40)],
      ),
      160,
    );
  });

  test('a label stops before one already placed in its row', () {
    expect(
      budget(
        const Offset(40, 100),
        VertexLabelSide.above,
        occupied: const [Rect.fromLTWH(100, 70, 40, 20)],
      ),
      97 - 36 - 10,
    );
    // A label already covering the start leaves no room on that side.
    expect(
      budget(
        const Offset(40, 100),
        VertexLabelSide.above,
        occupied: const [Rect.fromLTWH(20, 80, 40, 10)],
      ),
      0,
    );
  });

  test('near the top a label has room only below; near the bottom only '
      'above', () {
    expect(budget(const Offset(40, 12), VertexLabelSide.above), 0);
    expect(budget(const Offset(40, 12), VertexLabelSide.below), 160);
    expect(budget(const Offset(40, 190), VertexLabelSide.below), 0);
    expect(budget(const Offset(40, 190), VertexLabelSide.above), 160);
  });

  test('narrow plots cap the label at the right edge', () {
    expect(
      budget(
        const Offset(10, 60),
        VertexLabelSide.above,
        plot: const Rect.fromLTWH(0, 0, 80, 120),
        radius: 3,
      ),
      79 - 7 - 10,
    );
  });

  test('a label that would cover another vertex is rejected', () {
    final rect = vertexLabelRect(
      center: const Offset(40, 100),
      radius: 4,
      side: VertexLabelSide.above,
      width: 80,
      height: 16,
    );
    expect(
      vertexLabelFits(
        rect: rect,
        plot: labelPlot,
        anchor: const Offset(40, 100),
        radius: 4,
        occupied: const [],
        anchors: const [Offset(40, 100), Offset(70, 88)],
      ),
      isFalse,
    );
    expect(
      vertexLabelFits(
        rect: rect,
        plot: labelPlot,
        anchor: const Offset(40, 100),
        radius: 4,
        occupied: const [],
        anchors: const [Offset(40, 100)],
      ),
      isTrue,
    );
  });
}
