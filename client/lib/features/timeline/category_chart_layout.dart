import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/money_text.dart';
import 'category_totals.dart';

/// One-line label: "Groceries · 12 · 34%".
String pieLabelCaption(String name, int count, int percent) =>
    '$name · $count · $percent%';

int categoryPercent(int centsAbs, int total) =>
    total == 0 ? 0 : (centsAbs * 100 / total).round();

const pieLabelFontSize = 11.0;
const pieLabelLineHeight = 1.2;
const _pieLabelGap = 3.0;
const _pieLeader = 10.0;
const _pieMinRadius = 44.0;
const _pieInset = 2.0;
const _pieMaxRadius = 140.0;

const barLabelAngle = 40 * math.pi / 180; // clockwise; y is down
const minBarWidth = 36.0;
const barGap = 10.0;
const barAxisWidth = 44.0;
const barLabelPad = 6.0;

/// A laid-out outside label for one pie slice.
class PieLabelBox {
  const PieLabelBox({
    required this.id,
    required this.caption,
    required this.text,
    required this.rect,
    required this.left,
    required this.rim,
    required this.elbow,
    required this.anchor,
  });

  final String id;

  /// One-line caption used in semantics and tests.
  final String caption;

  /// Painted string (may contain a newline when the column is narrow).
  final String text;
  final Rect rect;
  final bool left;

  /// Where the leader meets the slice.
  final Offset rim;

  /// Bend of the leader, just outside the pie.
  final Offset elbow;

  /// Leader end at the label's inner edge.
  final Offset anchor;
}

/// Geometry for a labelled pie that fills [size].
class PieChartLayout {
  const PieChartLayout({
    required this.size,
    required this.center,
    required this.radius,
    required this.labels,
    required this.slices,
    required this.total,
    required this.moneyOut,
  });

  final Size size;
  final Offset center;
  final double radius;
  final List<PieLabelBox> labels;
  final List<CategoryBucket> slices;
  final int total;
  final bool moneyOut;

  PieLabelBox? labelOf(String id) {
    for (final l in labels) {
      if (l.id == id) return l;
    }
    return null;
  }
}

/// Lays every slice's label out to the left or right of the pie, stacked
/// so boxes never overlap and stay inside [size].
PieChartLayout layoutPieChart({
  required Size size,
  required List<CategoryBucket> slices,
  required int total,
  required bool moneyOut,
  TextStyle? style,
}) {
  final textStyle =
      style ??
      const TextStyle(
        fontSize: pieLabelFontSize,
        height: pieLabelLineHeight,
        color: AppTheme.textMuted,
        fontWeight: FontWeight.w500,
      );
  final w = math.max(size.width, 1.0);
  final h = math.max(size.height, 1.0);
  final area = Size(w, h);

  if (slices.isEmpty || total == 0) {
    final r = math.min(w, h) / 2 - 8;
    return PieChartLayout(
      size: area,
      center: Offset(w / 2, h / 2),
      radius: math.max(r, 1),
      labels: const [],
      slices: slices,
      total: total,
      moneyOut: moneyOut,
    );
  }

  // First pass: measure one-line labels to size the pie.
  final captions = [
    for (final b in slices)
      pieLabelCaption(
        b.name,
        b.count,
        categoryPercent(b.centsOn(moneyOut: moneyOut).abs(), total),
      ),
  ];
  var colW = 0.0;
  for (final c in captions) {
    colW = math.max(colW, _measure(c, textStyle, w).width);
  }
  colW = colW.clamp(48.0, w * 0.38);

  double radiusFor(double column) {
    final inner = w - 2 * (_pieInset + column + _pieLeader + 4);
    final byW = inner / 2;
    final byH = h / 2 - _pieInset - 4;
    return math
        .min(math.min(byW, byH), _pieMaxRadius)
        .clamp(_pieMinRadius, _pieMaxRadius);
  }

  var radius = radiusFor(colW);
  // If the pie would eat the label columns, shrink the column and wrap.
  if (2 * radius + 2 * colW + 2 * _pieLeader + 8 > w) {
    colW = ((w - 2 * radius - 2 * _pieLeader - 8) / 2).clamp(40.0, colW);
    radius = radiusFor(colW);
  }

  final center = Offset(w / 2, h / 2);

  // Build slice mid-angles and preferred Y.
  final items = <_PieItem>[];
  var start = -math.pi / 2;
  for (var i = 0; i < slices.length; i++) {
    final b = slices[i];
    final share = b.centsOn(moneyOut: moneyOut).abs();
    final sweep = 2 * math.pi * share / total;
    final mid = start + sweep / 2;
    final caption = captions[i];
    final twoLine = _measure(caption, textStyle, w).width > colW + 0.5;
    final text = twoLine
        ? '${b.name}\n${b.count} · ${categoryPercent(share, total)}%'
        : caption;
    final box = _measure(text, textStyle, colW);
    final left = math.cos(mid) < 0;
    final rim = center + Offset(math.cos(mid), math.sin(mid)) * radius;
    final preferredY =
        center.dy + math.sin(mid) * (radius + _pieLeader) - box.height / 2;
    items.add(
      _PieItem(
        id: b.id,
        caption: caption,
        text: text,
        size: box,
        left: left,
        mid: mid,
        rim: rim,
        preferredY: preferredY,
      ),
    );
    start += sweep;
  }

  final lefts = items.where((e) => e.left).toList();
  final rights = items.where((e) => !e.left).toList();
  _stackColumn(lefts, _pieInset, h - _pieInset);
  _stackColumn(rights, _pieInset, h - _pieInset);

  final labels = <PieLabelBox>[
    for (final it in items) _toLabel(it, center, radius, colW, w),
  ];

  return PieChartLayout(
    size: area,
    center: center,
    radius: radius,
    labels: labels,
    slices: slices,
    total: total,
    moneyOut: moneyOut,
  );
}

class _PieItem {
  _PieItem({
    required this.id,
    required this.caption,
    required this.text,
    required this.size,
    required this.left,
    required this.mid,
    required this.rim,
    required this.preferredY,
  });

  final String id;
  final String caption;
  final String text;
  final Size size;
  final bool left;
  final double mid;
  final Offset rim;
  double preferredY;
  double y = 0;
}

void _stackColumn(List<_PieItem> labs, double minY, double maxY) {
  if (labs.isEmpty) return;
  labs.sort((a, b) => a.preferredY.compareTo(b.preferredY));
  final avail = maxY - minY;
  final totalH =
      labs.fold<double>(0, (s, l) => s + l.size.height) +
      _pieLabelGap * (labs.length - 1);

  if (totalH >= avail) {
    // Pack tightly from the top; typography already as small as we go.
    var y = minY;
    final leftover = avail - labs.fold<double>(0, (s, l) => s + l.size.height);
    final g = labs.length > 1
        ? (leftover / (labs.length - 1)).clamp(0.0, _pieLabelGap)
        : 0.0;
    for (final l in labs) {
      l.y = y;
      y += l.size.height + g;
    }
    return;
  }

  labs.first.y = labs.first.preferredY;
  for (var i = 1; i < labs.length; i++) {
    final floor = labs[i - 1].y + labs[i - 1].size.height + _pieLabelGap;
    labs[i].y = math.max(labs[i].preferredY, floor);
  }
  final lastBottom = labs.last.y + labs.last.size.height;
  if (lastBottom > maxY) {
    labs.last.y = maxY - labs.last.size.height;
    for (var i = labs.length - 2; i >= 0; i--) {
      final ceil = labs[i + 1].y - labs[i].size.height - _pieLabelGap;
      labs[i].y = math.min(labs[i].y, ceil);
    }
  }
  if (labs.first.y < minY) {
    var y = minY;
    for (final l in labs) {
      l.y = y;
      y += l.size.height + _pieLabelGap;
    }
  }
}

PieLabelBox _toLabel(
  _PieItem it,
  Offset center,
  double radius,
  double colW,
  double width,
) {
  final inner = it.left
      ? center.dx - radius - _pieLeader - 4
      : center.dx + radius + _pieLeader + 4;
  final left = it.left
      ? (inner - it.size.width).clamp(_pieInset, width).toDouble()
      : inner;
  final right = it.left
      ? inner
      : (inner + it.size.width).clamp(0.0, width - _pieInset).toDouble();
  final rect = Rect.fromLTRB(
    it.left ? left : inner,
    it.y,
    it.left ? inner : right,
    it.y + it.size.height,
  ).intersect(Rect.fromLTWH(_pieInset, _pieInset, width - 2 * _pieInset, 1e6));
  // Re-clamp height into the canvas after the intersect on x.
  final y = rect.top;
  final box = Rect.fromLTWH(
    rect.left,
    y,
    math.max(rect.width, 1),
    it.size.height,
  );
  final elbow =
      center +
      Offset(math.cos(it.mid), math.sin(it.mid)) * (radius + _pieLeader);
  final anchor = Offset(it.left ? box.right : box.left, box.center.dy);
  return PieLabelBox(
    id: it.id,
    caption: it.caption,
    text: it.text,
    rect: box,
    left: it.left,
    rim: it.rim,
    elbow: Offset(elbow.dx, elbow.dy),
    anchor: anchor,
  );
}

Size _measure(String text, TextStyle style, double maxWidth) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: ui.TextDirection.ltr,
    maxLines: 3,
    ellipsis: '…',
  )..layout(minWidth: 0, maxWidth: math.max(8, maxWidth));
  // Slack so a later Text widget (possibly a different face) isn't clipped.
  return Size(tp.size.width + 6, tp.size.height + 1);
}

/// Hit-test a labelled pie: a label first, then a slice, else null.
String? hitTestPie(Offset local, PieChartLayout layout) {
  for (final lab in layout.labels) {
    if (lab.rect.inflate(4).contains(local)) return lab.id;
  }
  if (layout.total == 0 || layout.slices.isEmpty) return null;
  final v = local - layout.center;
  if (v.distance > layout.radius + 12 || v.distance < 2) return null;
  var theta = math.atan2(v.dy, v.dx) + math.pi / 2;
  while (theta < 0) {
    theta += 2 * math.pi;
  }
  var acc = 0.0;
  for (final b in layout.slices) {
    final share = b.centsOn(moneyOut: layout.moneyOut).abs();
    final sw = 2 * math.pi * share / layout.total;
    if (theta <= acc + sw) return b.id;
    acc += sw;
  }
  return layout.slices.last.id;
}

/// Vertical columns along a horizontal axis, names tilted below.
class ColumnBar {
  const ColumnBar({
    required this.id,
    required this.name,
    required this.caption,
    required this.valueText,
    required this.bar,
    required this.color,
    required this.hairline,
  });

  final String id;
  final String name;
  final String caption;
  final String valueText;
  final Rect bar;
  final Color color;
  final bool hairline;
}

class ColumnBarLayout {
  const ColumnBarLayout({
    required this.viewport,
    required this.contentWidth,
    required this.axisWidth,
    required this.plot,
    required this.labelBand,
    required this.maxValue,
    required this.ticks,
    required this.bars,
  });

  final Size viewport;
  final double contentWidth;
  final double axisWidth;
  final Rect plot;
  final double labelBand;
  final double maxValue;
  final List<({double value, String label, double y})> ticks;
  final List<ColumnBar> bars;
}

/// Lays out side-by-side columns for [slices]. [viewport] is the visible
/// size; [contentWidth] may be wider so the plot can scroll horizontally.
ColumnBarLayout layoutColumnBars({
  required Size viewport,
  required List<CategoryBucket> slices,
  required int total,
  required bool moneyOut,
  TextStyle? valueStyle,
  TextStyle? labelStyle,
  bool Function(Color color)? needsHairline,
}) {
  final vStyle =
      valueStyle ??
      const TextStyle(fontSize: 10, height: 1.1, color: AppTheme.text);
  final lStyle =
      labelStyle ??
      const TextStyle(fontSize: 10, height: 1.1, color: AppTheme.textMuted);
  final w = math.max(viewport.width, 1.0);
  final h = math.max(viewport.height, 1.0);

  var maxAbs = 0;
  for (final b in slices) {
    maxAbs = math.max(maxAbs, b.centsOn(moneyOut: moneyOut).abs());
  }
  final maxValue = _niceMax(maxAbs / 100.0);

  // Tilted-label band: height of the longest name at [barLabelAngle].
  var longest = 0.0;
  for (final b in slices) {
    longest = math.max(longest, _measure(b.name, lStyle, 200).width);
  }
  final labelH = _measure('Ag', lStyle, 200).height;
  var labelBand =
      longest * math.sin(barLabelAngle) +
      labelH * math.cos(barLabelAngle) +
      barLabelPad +
      4;

  final valueH = _measure('\$0', vStyle, 80).height;
  final axisWidth = _axisWidth(maxValue, vStyle);
  final plotTop = valueH + 4;
  const minPlot = 28.0;
  if (plotTop + minPlot + labelBand > h) {
    // Keep labels inside the chart so they never paint over the legend.
    labelBand = math.max(20.0, h - plotTop - minPlot);
  }
  final plotBottom = math.max(plotTop + minPlot, h - labelBand);
  final plotHeight = math.max(minPlot, plotBottom - plotTop);

  final n = math.max(slices.length, 1);
  // Advance between bar centres so tilted labels don't collide.
  final labelAdvance =
      longest * math.cos(barLabelAngle) + labelH * math.sin(barLabelAngle) + 8;
  final minSlot = math.max(minBarWidth + barGap, labelAdvance);
  final trailing = longest * math.cos(barLabelAngle) + 8;
  final minContent = n * minSlot + trailing;
  final plotW = math.max(w - axisWidth, minContent);
  final slot = (plotW - trailing) / n;

  final plot = Rect.fromLTWH(0, plotTop, plotW, plotHeight);

  final ticks = <({double value, String label, double y})>[];
  for (final t in [0.0, maxValue / 2, maxValue]) {
    final y = plotBottom - (maxValue == 0 ? 0 : plotHeight * (t / maxValue));
    ticks.add((value: t, label: _tickLabel(t), y: y));
  }

  final bars = <ColumnBar>[];
  for (var i = 0; i < slices.length; i++) {
    final b = slices[i];
    final share = b.centsOn(moneyOut: moneyOut).abs();
    final dollars = share / 100.0;
    final frac = maxValue == 0 ? 0.0 : dollars / maxValue;
    final cx = slot * (i + 0.5);
    final bw = math.min(minBarWidth + 8, slot - 6).clamp(8.0, slot - 4);
    final bh = plotHeight * frac.clamp(0.0, 1.0);
    final bar = Rect.fromCenter(
      center: Offset(cx, plotBottom - bh / 2),
      width: bw,
      height: math.max(bh, share == 0 ? 0 : 2),
    );
    final pct = categoryPercent(share, total);
    bars.add(
      ColumnBar(
        id: b.id,
        name: b.name,
        caption: pieLabelCaption(b.name, b.count, pct),
        valueText: formatMoneyAmount(dollars),
        bar: bar,
        color: b.color,
        hairline: needsHairline?.call(b.color) ?? false,
      ),
    );
  }

  return ColumnBarLayout(
    viewport: Size(w, h),
    contentWidth: plotW,
    axisWidth: axisWidth,
    plot: plot,
    labelBand: labelBand,
    maxValue: maxValue,
    ticks: ticks,
    bars: bars,
  );
}

double _niceMax(double v) {
  if (v <= 0) return 1;
  final exp = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
  final f = v / exp;
  final nice = f <= 1
      ? 1
      : f <= 2
      ? 2
      : f <= 5
      ? 5
      : 10;
  return nice * exp;
}

String _tickLabel(double dollars) => formatMoneyAmount(dollars);

double _axisWidth(double maxValue, TextStyle style) {
  final samples = [
    _tickLabel(0),
    _tickLabel(maxValue / 2),
    _tickLabel(maxValue),
  ];
  var w = 0.0;
  for (final s in samples) {
    w = math.max(w, _measure(s, style, 120).width);
  }
  return (w + 8).clamp(barAxisWidth, 72);
}

/// True when any pair of [rects] overlaps by more than [slop] pixels.
bool anyRectsOverlap(Iterable<Rect> rects, {double slop = 0.5}) {
  final list = rects.toList();
  for (var i = 0; i < list.length; i++) {
    for (var j = i + 1; j < list.length; j++) {
      final a = list[i].deflate(slop);
      final b = list[j].deflate(slop);
      if (a.overlaps(b)) return true;
    }
  }
  return false;
}

/// Tight world-bounds of a label rotated clockwise by [barLabelAngle]
/// around [origin] (top-left of the unrotated text).
Rect rotatedLabelBounds(Offset origin, Size size) {
  final c = math.cos(barLabelAngle);
  final s = math.sin(barLabelAngle);
  Offset map(Offset p) {
    final dx = p.dx - origin.dx;
    final dy = p.dy - origin.dy;
    return Offset(origin.dx + dx * c - dy * s, origin.dy + dx * s + dy * c);
  }

  final corners = [
    origin,
    origin + Offset(size.width, 0),
    origin + Offset(size.width, size.height),
    origin + Offset(0, size.height),
  ].map(map);
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final p in corners) {
    minX = math.min(minX, p.dx);
    minY = math.min(minY, p.dy);
    maxX = math.max(maxX, p.dx);
    maxY = math.max(maxY, p.dy);
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}
