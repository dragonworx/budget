import 'dart:ui';

import 'package:budget_client/features/timeline/alert_fill.dart';
import 'package:flutter_test/flutter_test.dart';

// The balance line's runs as the chart builds them: low = below the alert
// (strictly; see belowAlert). Screen y grows downwards.
FillPlateau run(double x0, double x1, double y, {double alertY = 100}) =>
    (x0: x0, x1: x1, y: y, low: y > alertY);

const plot = Rect.fromLTRB(0, 0, 300, 200);

void main() {
  test('crossing down then up: red only under the alert, split at its y', () {
    final f = alertFillOf(
      [run(0, 100, 60), run(100, 200, 140), run(200, 300, 40)],
      alertY: 100,
      plot: plot,
    );
    expect(f.crossings, const [Offset(100, 100), Offset(200, 100)]);
    expect(f.safe, const [
      Rect.fromLTRB(0, 60, 100, 200),
      Rect.fromLTRB(200, 40, 300, 200),
    ]);
    // The band from the alert line down to the balance line, then the
    // column under the line: together exactly the run below the alert.
    expect(f.deficit, const [Rect.fromLTRB(100, 100, 200, 140)]);
    expect(f.under, const [Rect.fromLTRB(100, 140, 200, 200)]);
    expect(f.deficit.single.top, 100);
    expect(AlertFill.area(f.deficit) + AlertFill.area(f.under), 100 * 100);
    expect(AlertFill.area(f.safe), 100 * 140 + 100 * 160);
  });

  test('entirely above: no red, no crossings', () {
    final f = alertFillOf(
      [run(0, 150, 20), run(150, 300, 90)],
      alertY: 100,
      plot: plot,
    );
    expect(f.deficit, isEmpty);
    expect(f.under, isEmpty);
    expect(f.crossings, isEmpty);
    expect(AlertFill.area(f.safe), 150 * 180 + 150 * 110);
  });

  test('touching the alert (equal) stays green', () {
    final f = alertFillOf(
      [run(0, 100, 50), run(100, 200, 100), run(200, 300, 50)],
      alertY: 100,
      plot: plot,
    );
    expect(f.deficit, isEmpty);
    expect(f.under, isEmpty);
    expect(f.crossings, isEmpty);
  });

  test('entirely below: all red, the band starts at the alert line', () {
    final f = alertFillOf(
      [run(0, 100, 150), run(100, 300, 180)],
      alertY: 100,
      plot: plot,
    );
    expect(f.safe, isEmpty);
    expect(f.crossings, isEmpty);
    expect(f.deficit.map((r) => r.top), everyElement(100));
    expect(AlertFill.area(f.deficit) + AlertFill.area(f.under), 300 * 100);
  });

  test('several crossings, including negative balances off the bottom', () {
    final f = alertFillOf(
      [
        run(0, 50, 80),
        run(50, 100, 260), // a negative balance below the plot
        run(100, 150, 90),
        run(150, 200, 120),
        run(200, 300, 10),
      ],
      alertY: 100,
      plot: plot,
    );
    expect(f.crossings.map((o) => o.dx), [50, 100, 150, 200]);
    expect(f.crossings.map((o) => o.dy), everyElement(100));
    // Off the bottom: the band reaches the plot bottom, nothing under it.
    expect(f.deficit.first, const Rect.fromLTRB(50, 100, 100, 200));
    expect(f.under, const [Rect.fromLTRB(150, 120, 200, 200)]);
  });

  test('alert above the plot: low runs are red from the plot top', () {
    final f = alertFillOf(
      [
        (x0: 0, x1: 100, y: 50, low: true),
        (x0: 100, x1: 300, y: 120, low: true),
      ],
      alertY: -40,
      plot: plot,
    );
    expect(f.safe, isEmpty);
    expect(f.crossings, isEmpty);
    expect(f.deficit.map((r) => r.top), everyElement(0));
    expect(AlertFill.area(f.deficit) + AlertFill.area(f.under), 300 * 200);
  });

  test('alert below the plot: nothing visible is red', () {
    final f = alertFillOf(
      [run(0, 100, 30, alertY: 400), run(100, 300, 190, alertY: 400)],
      alertY: 400,
      plot: plot,
    );
    expect(f.deficit, isEmpty);
    expect(f.under, isEmpty);
    expect(f.crossings, isEmpty);
    expect(AlertFill.area(f.safe), 100 * 170 + 200 * 10);
  });

  test('the split follows the alert y as the axis pans / zooms', () {
    final runs = [
      (x0: 0.0, x1: 100.0, y: 60.0, low: false),
      (x0: 100.0, x1: 200.0, y: 140.0, low: true),
    ];
    for (final alertY in [100.0, 120.0, 70.0]) {
      final f = alertFillOf(runs, alertY: alertY, plot: plot);
      expect(f.crossings, [Offset(100, alertY)]);
      expect(f.deficit.single.top, alertY);
      expect(f.deficit.single.bottom, 140);
    }
  });

  test('runs past the plot edges are clipped to it', () {
    final f = alertFillOf(
      [run(-50, 120, 150), run(120, 400, 50)],
      alertY: 100,
      plot: plot,
    );
    expect(f.deficit.single.left, 0);
    expect(f.safe.single.right, 300);
    expect(f.crossings, const [Offset(120, 100)]);
  });
}
