// The operator row under a focused formula field on touch devices: Flutter
// web can't add keys to the iOS keyboard, so they sit inline.
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'variable_icon.dart';

/// (label, inserted text).
const formulaKeys = [
  ('(', '('),
  (')', ')'),
  ('+', '+'),
  ('−', '-'),
  ('×', '*'),
  ('÷', '/'),
  ('.', '.'),
];

class FormulaKeysRow extends StatelessWidget {
  const FormulaKeysRow({
    super.key,
    required this.onKey,
    this.onPicker,
    this.keyPrefix = 'formula',
  });

  final ValueChanged<String> onKey;
  final VoidCallback? onPicker;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget key(String label, String semantics, VoidCallback onTap, Key k) =>
        Semantics(
          button: true,
          label: semantics,
          excludeSemantics: true,
          child: Material(
            color: AppTheme.overlay,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              key: k,
              canRequestFocus: false,
              borderRadius: BorderRadius.circular(8),
              onTap: onTap,
              child: SizedBox(
                height: 40,
                child: Center(
                  child: Text(
                    label,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: AppTheme.text,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
    return TextFieldTapRegion(
      child: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: _KeysLayout(
          key: ValueKey('$keyPrefix-keys'),
          children: [
            for (final (label, insert) in formulaKeys)
              key(
                label,
                _spoken[insert] ?? label,
                () => onKey(insert),
                ValueKey('$keyPrefix-key-$insert'),
              ),
            if (onPicker != null)
              Semantics(
                button: true,
                label: 'Insert a variable',
                excludeSemantics: true,
                child: Material(
                  color: AppTheme.accentSoft,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    key: ValueKey('$keyPrefix-key-picker'),
                    canRequestFocus: false,
                    borderRadius: BorderRadius.circular(8),
                    onTap: onPicker,
                    child: const SizedBox(
                      height: 40,
                      child: Icon(
                        variableIcon,
                        size: 20,
                        color: AppTheme.accent,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One line of equal keys (at least 40 px each) when they fit, else a wrap
/// of 40 px keys (320 px phones).
///
/// A render box rather than a LayoutBuilder so it can report intrinsic
/// sizes: the field sits in AlertDialogs (stream dialog, loan setup), which
/// measure their content with IntrinsicWidth (spec 013).
class _KeysLayout extends MultiChildRenderObjectWidget {
  const _KeysLayout({super.key, required super.children});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderKeys();
}

class _KeysParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderKeys extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _KeysParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _KeysParentData> {
  static const _gap = 4.0;
  static const _min = 40.0;
  static const _max = 56.0;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _KeysParentData) {
      child.parentData = _KeysParentData();
    }
  }

  List<RenderBox> get _kids {
    final out = <RenderBox>[];
    var c = firstChild;
    while (c != null) {
      out.add(c);
      c = childAfter(c);
    }
    return out;
  }

  bool _fits(double width, int n) => width >= n * _min + (n - 1) * _gap;

  double _keyWidth(double width, int n) =>
      ((width - (n - 1) * _gap) / n).clamp(_min, _max);

  /// Keys per wrapped line at [width] (at least one).
  int _perLine(double width) {
    final k = ((width + _gap) / (_min + _gap)).floor();
    return k < 1 ? 1 : k;
  }

  @override
  double computeMinIntrinsicWidth(double height) => childCount == 0 ? 0 : _min;

  @override
  double computeMaxIntrinsicWidth(double height) {
    final n = childCount;
    return n == 0 ? 0 : n * _max + (n - 1) * _gap;
  }

  double _height(double width) {
    final kids = _kids;
    final n = kids.length;
    if (n == 0) return 0;
    if (width.isInfinite || _fits(width, n)) {
      final w = width.isInfinite ? _max : _keyWidth(width, n);
      var h = 0.0;
      for (final k in kids) {
        final kh = k.getMaxIntrinsicHeight(w);
        if (kh > h) h = kh;
      }
      return h;
    }
    final per = _perLine(width);
    var total = 0.0;
    for (var i = 0; i < n; i += per) {
      var h = 0.0;
      for (var j = i; j < n && j < i + per; j++) {
        final kh = kids[j].getMaxIntrinsicHeight(_min);
        if (kh > h) h = kh;
      }
      total += (i > 0 ? _gap : 0) + h;
    }
    return total;
  }

  @override
  double computeMinIntrinsicHeight(double width) => _height(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _height(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  void performLayout() => size = _layout(constraints, dry: false);

  Size _layout(BoxConstraints c, {required bool dry}) {
    final kids = _kids;
    final n = kids.length;
    if (n == 0) return c.smallest;
    Size lay(RenderBox k, double w) {
      final kc = BoxConstraints(
        minWidth: w,
        maxWidth: w,
        maxHeight: c.maxHeight,
      );
      if (dry) return k.getDryLayout(kc);
      k.layout(kc, parentUsesSize: true);
      return k.size;
    }

    if (_fits(c.maxWidth, n)) {
      // As a Row of fixed-width keys: full width, keys left-aligned and
      // centred vertically.
      final w = _keyWidth(c.maxWidth, n);
      final sizes = [for (final k in kids) lay(k, w)];
      var h = 0.0;
      for (final s in sizes) {
        if (s.height > h) h = s.height;
      }
      final size = c.constrain(Size(c.maxWidth, h));
      if (!dry) {
        var x = 0.0;
        for (var i = 0; i < n; i++) {
          (kids[i].parentData! as _KeysParentData).offset = Offset(
            x,
            (size.height - sizes[i].height) / 2,
          );
          x += w + _gap;
        }
      }
      return size;
    }
    // As a Wrap of 40 px keys: lines top-aligned, as wide as the widest.
    final per = _perLine(c.maxWidth);
    var y = 0.0, widest = 0.0;
    for (var i = 0; i < n; i += per) {
      final line = kids.sublist(i, i + per > n ? n : i + per);
      final sizes = [for (final k in line) lay(k, _min)];
      var h = 0.0;
      for (final s in sizes) {
        if (s.height > h) h = s.height;
      }
      if (i > 0) y += _gap;
      final lw = line.length * _min + (line.length - 1) * _gap;
      if (lw > widest) widest = lw;
      if (!dry) {
        var x = 0.0;
        for (final k in line) {
          (k.parentData! as _KeysParentData).offset = Offset(x, y);
          x += _min + _gap;
        }
      }
      y += h;
    }
    return c.constrain(Size(widest, y));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
}

const _spoken = {
  '(': 'Open bracket',
  ')': 'Close bracket',
  '+': 'Plus',
  '-': 'Minus',
  '*': 'Times',
  '/': 'Divided by',
  '.': 'Point',
};
