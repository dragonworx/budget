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
                width: 40,
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
        child: Wrap(
          key: ValueKey('$keyPrefix-keys'),
          spacing: 4,
          runSpacing: 4,
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
                      width: 40,
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
