// The operator row under a focused formula field on touch devices: Flutter
// web can't add keys to the iOS keyboard, so they sit inline.
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// (label, inserted text).
const formulaKeys = [
  (r'$', r'$'),
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
                        Icons.data_object,
                        size: 18,
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
class _KeysLayout extends StatelessWidget {
  const _KeysLayout({super.key, required this.children});
  final List<Widget> children;

  static const _gap = 4.0;
  static const _min = 40.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final n = children.length;
      final fits = c.maxWidth >= n * _min + (n - 1) * _gap;
      if (fits) {
        // Up to 56 px a key, then left-aligned (wide screens, tablets).
        final w = ((c.maxWidth - (n - 1) * _gap) / n).clamp(_min, 56.0);
        return Row(
          children: [
            for (var i = 0; i < n; i++) ...[
              if (i > 0) const SizedBox(width: _gap),
              SizedBox(width: w, child: children[i]),
            ],
          ],
        );
      }
      return Wrap(
        spacing: _gap,
        runSpacing: _gap,
        children: [for (final k in children) SizedBox(width: _min, child: k)],
      );
    },
  );
}

const _spoken = {
  r'$': 'Dollar sign, variable',
  '(': 'Open bracket',
  ')': 'Close bracket',
  '+': 'Plus',
  '-': 'Minus',
  '*': 'Times',
  '/': 'Divided by',
  '.': 'Point',
};
