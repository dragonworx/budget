import 'package:budget_client/features/timeline/category_chart_layout.dart';
import 'package:budget_client/features/timeline/category_totals.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

CategoryBucket bucket(
  String id,
  String name,
  int outCents, {
  int count = 1,
  Color color = const Color(0xFF4CAF50),
}) => CategoryBucket(
  id: id,
  name: name,
  color: color,
  inCents: 0,
  outCents: outCents,
  count: count,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('layoutPieChart', () {
    test('labels every slice, splits sides, and never overlaps at 320', () {
      final slices = [
        bucket('g', 'Groceries', -6000, count: 12),
        bucket('r', 'Rent', -2500, count: 1),
        bucket('t', 'Transport', -1300, count: 8),
        bucket('o', 'Other', -200, count: 3),
      ];
      const total = 10000;
      final layout = layoutPieChart(
        size: const Size(304, 220),
        slices: slices,
        total: total,
        moneyOut: true,
      );
      expect(layout.labels, hasLength(4));
      expect(layout.labels.map((l) => l.id).toSet(), {'g', 'r', 't', 'o'});
      expect(layout.labels.any((l) => l.left), isTrue);
      expect(layout.labels.any((l) => !l.left), isTrue);
      for (final lab in layout.labels) {
        expect(lab.rect.left, greaterThanOrEqualTo(-0.01));
        expect(lab.rect.top, greaterThanOrEqualTo(-0.01));
        expect(lab.rect.right, lessThanOrEqualTo(304.01));
        expect(lab.rect.bottom, lessThanOrEqualTo(220.01));
        if (lab.left) {
          expect(lab.rect.right, lessThanOrEqualTo(layout.center.dx + 0.5));
        } else {
          expect(lab.rect.left, greaterThanOrEqualTo(layout.center.dx - 0.5));
        }
      }
      expect(anyRectsOverlap(layout.labels.map((l) => l.rect)), isFalse);
      expect(layout.labelOf('g')!.caption, 'Groceries · 12 · 60%');
    });

    test('tiny slices still get a label at 320, 412 and 560', () {
      final slices = [
        bucket('a', 'Alpha', -8000, count: 20),
        bucket('b', 'Beta', -1500, count: 4),
        bucket('c', 'Gamma', -400, count: 2),
        bucket('d', 'Tiny A', -50, count: 1),
        bucket('e', 'Tiny B', -50, count: 1),
      ];
      const total = 10000;
      for (final size in const [
        Size(304, 200),
        Size(380, 240),
        Size(528, 280),
      ]) {
        final layout = layoutPieChart(
          size: size,
          slices: slices,
          total: total,
          moneyOut: true,
        );
        expect(layout.labels, hasLength(5), reason: '$size');
        expect(layout.labelOf('d')!.caption, 'Tiny A · 1 · 1%');
        expect(layout.labelOf('e')!.caption, 'Tiny B · 1 · 1%');
        expect(
          anyRectsOverlap(layout.labels.map((l) => l.rect)),
          isFalse,
          reason: '$size',
        );
        for (final lab in layout.labels) {
          expect(lab.rect.left, greaterThanOrEqualTo(-0.01), reason: lab.id);
          expect(
            lab.rect.right,
            lessThanOrEqualTo(size.width + 0.01),
            reason: lab.id,
          );
          expect(
            lab.rect.bottom,
            lessThanOrEqualTo(size.height + 0.01),
            reason: lab.id,
          );
        }
      }
    });

    test('hit-test prefers a label, then the slice under the point', () {
      final slices = [
        bucket('g', 'Groceries', -6000, count: 1),
        bucket('r', 'Rent', -4000, count: 1),
      ];
      final layout = layoutPieChart(
        size: const Size(400, 240),
        slices: slices,
        total: 10000,
        moneyOut: true,
      );
      final groc = layout.labelOf('g')!;
      expect(hitTestPie(groc.rect.center, layout), 'g');
      // Dead centre of the pie is excluded (donut hole / too close).
      expect(hitTestPie(layout.center, layout), isNull);
      final onRim =
          layout.center +
          Offset(0, -layout.radius * 0.6); // 12 o'clock, first slice
      expect(hitTestPie(onRim, layout), 'g');
    });
  });

  group('layoutColumnBars', () {
    test('columns sit on a horizontal axis and can scroll at 320', () {
      final slices = [
        for (var i = 0; i < 8; i++)
          bucket('c$i', 'Category $i', -1000 - i * 100, count: 2 + i),
      ];
      final layout = layoutColumnBars(
        viewport: const Size(280, 200),
        slices: slices,
        total: slices.fold(0, (s, b) => s + b.outCents.abs()),
        moneyOut: true,
      );
      expect(layout.bars, hasLength(8));
      expect(
        layout.contentWidth,
        greaterThan(layout.viewport.width - layout.axisWidth),
      );
      for (var i = 1; i < layout.bars.length; i++) {
        expect(
          layout.bars[i].bar.left,
          greaterThan(layout.bars[i - 1].bar.right - 0.5),
        );
      }
      expect(
        layout.bars.first.caption,
        'Category 0 · 2 · ${categoryPercent(1000, 10800)}%',
      );
      // Tilted labels along the bottom stay in the label band and do not
      // overlap one another.
      const style = TextStyle(fontSize: 10, height: 1.1);
      final labelRects = <Rect>[];
      for (final b in layout.bars) {
        final size = _textSize(b.name, style);
        labelRects.add(rotatedLabelBounds(b.labelOrigin, size));
      }
      expect(anyRectsOverlap(labelRects, slop: 1), isFalse);
      expect(layout.bars.first.valueText, isNotEmpty);
    });

    test('centred tilted labels stay inside the scroll content', () {
      final slices = [
        bucket('r', 'Rent', -682000, count: 620),
        bucket('m', 'Mortgage repayment', -679015, count: 977),
        bucket('g', 'Groceries', -496800, count: 1242),
      ];
      final total = slices.fold(0, (s, b) => s + b.outCents.abs());
      final layout = layoutColumnBars(
        viewport: const Size(276, 200),
        slices: slices,
        total: total,
        moneyOut: true,
      );
      const style = TextStyle(fontSize: 10, height: 1.1);
      for (final b in layout.bars) {
        expect(b.labelOrigin.dx, lessThan(b.bar.center.dx + 0.5));
        final size = _textSize(b.name, style);
        final rect = rotatedLabelBounds(b.labelOrigin, size);
        expect(rect.left, greaterThanOrEqualTo(-1), reason: b.name);
        expect(
          rect.right,
          lessThanOrEqualTo(layout.contentWidth + 1),
          reason: b.name,
        );
      }
    });

    test('values sit above the columns', () {
      final slices = [
        bucket('g', 'Groceries', -6000, count: 12),
        bucket('r', 'Rent', -2500, count: 1),
      ];
      final layout = layoutColumnBars(
        viewport: const Size(400, 220),
        slices: slices,
        total: 8500,
        moneyOut: true,
      );
      expect(layout.bars.first.bar.bottom, closeTo(layout.plot.bottom, 0.6));
      expect(layout.bars.first.bar.top, lessThan(layout.bars.last.bar.top));
    });
  });
}

Size _textSize(String text, TextStyle style) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  return tp.size;
}
