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

  test('padded range always includes zero and the data extremes', () {
    final positive = paddedRange(100, 200);
    expect(positive.min, lessThan(0));
    expect(positive.max, greaterThan(200));

    final negative = paddedRange(-200, -40);
    expect(negative.min, lessThan(-200));
    expect(negative.max, greaterThan(0));

    final mixed = paddedRange(-25, 80);
    expect(mixed.min, lessThan(-25));
    expect(mixed.max, greaterThan(80));

    final flat = paddedRange(50, 50);
    expect(flat.min, lessThan(0));
    expect(flat.max, greaterThan(50));

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

  test('vertex labels keep a readable gap before the next name', () {
    final budget = vertexLabelTextBudget(
      plot: const Rect.fromLTWH(0, 0, 400, 200),
      center: const Offset(40, 100),
      radius: 4,
      side: VertexLabelSide.aboveRight,
      labelHeight: 16,
      maxText: 160,
      minText: 18,
      pad: 10,
      occupied: const [],
      anchors: const [Offset(40, 100), Offset(180, 100)],
    );

    expect(budget, 115);
  });

  test('vertices too close to label separately share one name width', () {
    final budget = vertexLabelTextBudget(
      plot: const Rect.fromLTWH(0, 0, 400, 200),
      center: const Offset(40, 100),
      radius: 4,
      side: VertexLabelSide.aboveRight,
      labelHeight: 16,
      maxText: 80,
      minText: 18,
      pad: 10,
      occupied: const [],
      anchors: const [Offset(40, 100), Offset(52, 100)],
    );

    expect(budget, 80);
  });

  test('labels on different steps do not shorten each other', () {
    final budget = vertexLabelTextBudget(
      plot: const Rect.fromLTWH(0, 0, 400, 200),
      center: const Offset(40, 100),
      radius: 4,
      side: VertexLabelSide.aboveRight,
      labelHeight: 16,
      maxText: 160,
      minText: 18,
      pad: 10,
      occupied: const [],
      anchors: const [Offset(40, 100), Offset(80, 40)],
    );

    expect(budget, 160);
  });

  test('narrow plots cap the transaction name width', () {
    final budget = vertexLabelTextBudget(
      plot: const Rect.fromLTWH(0, 0, 80, 120),
      center: const Offset(10, 60),
      radius: 3,
      side: VertexLabelSide.aboveRight,
      labelHeight: 14,
      maxText: 160,
      minText: 18,
      pad: 10,
      occupied: const [],
      anchors: const [Offset(10, 60)],
    );

    expect(budget, 53);
  });

  test('a label stops before one already placed on its band', () {
    final budget = vertexLabelTextBudget(
      plot: const Rect.fromLTWH(0, 0, 400, 200),
      center: const Offset(40, 100),
      radius: 4,
      side: VertexLabelSide.aboveRight,
      labelHeight: 16,
      maxText: 160,
      minText: 18,
      pad: 10,
      occupied: const [Rect.fromLTWH(100, 70, 40, 20)],
      anchors: const [Offset(40, 100)],
    );

    expect(budget, 40);
  });

  test('a label blocked by a marker slides along the vertex row', () {
    final nudged = nudgeVertexLabel(
      rect: const Rect.fromLTWH(40, 20, 50, 16),
      plot: const Rect.fromLTWH(0, 0, 400, 200),
      anchor: const Offset(30, 40),
      radius: 4,
      occupied: const [Rect.fromLTWH(20, 8, 40, 20)],
      anchors: const [Offset(30, 40)],
    );

    expect(nudged, const Rect.fromLTWH(63, 20, 50, 16));
    expect(
      vertexLabelFits(
        rect: nudged!,
        plot: const Rect.fromLTWH(0, 0, 400, 200),
        anchor: const Offset(30, 40),
        radius: 4,
        occupied: const [Rect.fromLTWH(20, 8, 40, 20)],
        anchors: const [Offset(30, 40)],
        attachReach: 96,
      ),
      isTrue,
    );
  });

  test('a label that would cover another vertex is rejected', () {
    final rect = vertexLabelRect(
      center: const Offset(40, 100),
      radius: 4,
      side: VertexLabelSide.besideRight,
      width: 80,
      height: 16,
    );

    expect(
      vertexLabelFits(
        rect: rect,
        plot: const Rect.fromLTWH(0, 0, 400, 200),
        anchor: const Offset(40, 100),
        radius: 4,
        occupied: const [],
        anchors: const [Offset(40, 100), Offset(70, 100)],
      ),
      isFalse,
    );
  });

  test('vertex labels stay inside the plot and next to their dot', () {
    const plot = Rect.fromLTWH(0, 0, 400, 200);
    final outside = vertexLabelRect(
      center: const Offset(390, 10),
      radius: 4,
      side: VertexLabelSide.aboveRight,
      width: 40,
      height: 16,
    );
    expect(
      vertexLabelFits(
        rect: outside,
        plot: plot,
        anchor: const Offset(390, 10),
        radius: 4,
        occupied: const [],
        anchors: const [Offset(390, 10)],
      ),
      isFalse,
    );

    final beside = vertexLabelRect(
      center: const Offset(40, 100),
      radius: 4,
      side: VertexLabelSide.aboveRight,
      width: 60,
      height: 16,
    );
    expect(beside.left, greaterThan(40));
    expect(beside.bottom, lessThan(100));
    expect(
      vertexLabelFits(
        rect: beside,
        plot: plot,
        anchor: const Offset(40, 100),
        radius: 4,
        occupied: const [],
        anchors: const [Offset(40, 100)],
      ),
      isTrue,
    );
  });
}
