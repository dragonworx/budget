import 'package:budget_formula/budget_formula.dart'
    show FieldSpec, parseLegacyInt;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../theme/app_theme.dart';
import 'formula/formula_field.dart';

/// Largest "every N" offered.
const int maxRecurrenceInterval = 99;

/// "day" / "days" etc. for [count].
String recurrenceUnitWord(RecurrenceUnit unit, int count) {
  final one = count == 1;
  return switch (unit) {
    RecurrenceUnit.days => one ? 'day' : 'days',
    RecurrenceUnit.weeks => one ? 'week' : 'weeks',
    RecurrenceUnit.months => one ? 'month' : 'months',
    RecurrenceUnit.years => one ? 'year' : 'years',
  };
}

/// Every [− N +] [unit ▾]: the recurrence spacing, shared by the event
/// editor and the Plan panels.
///
/// N (1–[maxRecurrenceInterval]) lives in [controller]: typed (digits, two
/// at most) or stepped with touch-sized (44px) − / + buttons. The unit reads
/// singular for 1. With [autoInterval] the field may be left blank: the
/// calculated value shows as an italic hint (✦) and the buttons step from
/// it; [onClear] then offers a clear button to go back to calculated.
///
/// With a [FormulaEditingController] and a [spec] N may be a formula: the
/// box widens (up to 180) and the − / + buttons are off while it is one.
class RecurrenceIntervalField extends StatelessWidget {
  const RecurrenceIntervalField({
    super.key,
    required this.controller,
    required this.unit,
    required this.onChanged,
    required this.onUnitChanged,
    this.keyPrefix = 'editor',
    this.caption,
    this.autoInterval,
    this.allowBlank = false,
    this.helperText,
    this.errorText,
    this.validator,
    this.onClear,
    this.highlight = false,
    this.spec,
    this.scope,
  });

  final TextEditingController controller;
  final RecurrenceUnit unit;
  final VoidCallback onChanged;
  final ValueChanged<RecurrenceUnit> onUnitChanged;

  /// Keys: `<prefix>-interval`, `-interval-minus`, `-interval-plus`,
  /// `-unit`, `-unit-<name>`, `-interval-clear`.
  final String keyPrefix;

  /// Optional small label above the row (e.g. "Frequency").
  final String? caption;

  /// The calculated N shown when the field is blank.
  final int? autoInterval;

  /// Whether a blank N is valid (calculated).
  final bool allowBlank;
  final String? helperText;
  final String? errorText;
  final FormFieldValidator<String>? validator;
  final VoidCallback? onClear;

  /// Draws attention (e.g. a value the solver needs).
  final bool highlight;

  /// The field's spec, for a [FormulaEditingController] (formulas).
  final FieldSpec? spec;
  final VariableScope? scope;

  FormulaEditingController? get _formulaController => spec == null
      ? null
      : switch (controller) {
          final FormulaEditingController c => c,
          _ => null,
        };

  bool get _formula => _formulaController?.showsFormula ?? false;

  int? get _typed =>
      _formulaController?.typedInt ?? parseLegacyInt(controller.text);

  /// The most a formula box may take (48..180): the row less "Every",
  /// − / +, the clear button and the unit dropdown's longest word.
  double _room(BuildContext context, double row, int n, bool blank) {
    final theme = Theme.of(context);
    double measure(String text, TextStyle? style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final w = painter.width;
      painter.dispose();
      return w;
    }

    final every = row >= 270
        ? measure('Every', theme.textTheme.bodyMedium) + 4
        : 0;
    var unitWord = 0.0;
    for (final u in RecurrenceUnit.values) {
      final w = measure(recurrenceUnitWord(u, n), theme.textTheme.titleMedium);
      if (w > unitWord) unitWord = w;
    }
    // Dropdown: 12 + 12 padding, 24 arrow; the 4 gap before it.
    final unit = unitWord + 48 + 4;
    final clear = onClear != null && !blank ? 44 : 0;
    return (row - every - 88 - unit - clear).clamp(48.0, 180.0);
  }

  void _set(int n) {
    controller.text = '${n.clamp(1, maxRecurrenceInterval)}';
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final typed = _typed;
    final n = typed ?? autoInterval ?? 1;
    final blank = controller.text.trim().isEmpty;
    final p = keyPrefix;
    Widget step(IconData icon, String tip, VoidCallback? onPressed, String k) =>
        IconButton(
          key: ValueKey('$p-interval-$k'),
          tooltip: _formula ? formulaStepperTip : tip,
          onPressed: onPressed,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          padding: EdgeInsets.zero,
          icon: Icon(icon, size: 20),
        );
    final border = highlight
        ? OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: scheme.tertiary, width: 1.5),
          )
        : null;
    final row = LayoutBuilder(
      builder: (context, box) => Row(
        children: [
          if (box.maxWidth >= 270) ...[
            Text('Every', style: theme.textTheme.bodyMedium),
            const SizedBox(width: 4),
          ],
          step(
            Icons.remove_rounded,
            'Fewer',
            _formula || n <= 1 ? null : () => _set(n - 1),
            'minus',
          ),
          if (_formulaController case final c?)
            FormulaField(
              key: ValueKey('$p-interval'),
              spec: spec!,
              scope: scope ?? VariableScope.empty,
              controller: c,
              textAlign: TextAlign.center,
              legacyKeyboardType: TextInputType.number,
              legacyFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(2),
              ],
              dense: true,
              allowEmpty: allowBlank,
              // Plain N: no field errors (the screen's errorText shows
              // them, as today); a formula's own errors show.
              plainErrors: false,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              hintText: autoInterval == null ? null : '$autoInterval',
              hintStyle: TextStyle(
                color: scheme.primary,
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w700,
              ),
              enabledBorder: border,
              previewInTooltip: true,
              // The unit dropdown keeps its place (and its longest word).
              growWidth: (48, _room(context, box.maxWidth, n, blank)),
              onChanged: (_) => onChanged(),
            )
          else
            SizedBox(
              width: 48,
              child: TextFormField(
                key: ValueKey('$p-interval'),
                controller: controller,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(2),
                ],
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  hintText: autoInterval == null ? null : '$autoInterval',
                  hintStyle: TextStyle(
                    color: scheme.primary,
                    fontStyle: FontStyle.italic,
                    fontWeight: FontWeight.w700,
                  ),
                  enabledBorder: border,
                ),
                onChanged: (_) => onChanged(),
                validator:
                    validator ??
                    (value) {
                      final raw = (value ?? '').trim();
                      if (raw.isEmpty && allowBlank) return null;
                      final v = parseLegacyInt(raw);
                      return v == null || v < 1 || v > maxRecurrenceInterval
                          ? '1–$maxRecurrenceInterval'
                          : null;
                    },
              ),
            ),
          step(
            Icons.add_rounded,
            'More',
            _formula || n >= maxRecurrenceInterval ? null : () => _set(n + 1),
            'plus',
          ),
          const SizedBox(width: 4),
          Expanded(
            // Re-keyed by unit so a unit set from outside shows.
            child: KeyedSubtree(
              key: ValueKey('$p-unit-is-${unit.name}'),
              child: DropdownButtonFormField<RecurrenceUnit>(
                key: ValueKey('$p-unit'),
                initialValue: unit,
                isExpanded: true,
                decoration: InputDecoration(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  enabledBorder: border,
                ),
                dropdownColor: AppTheme.overlay,
                items: [
                  for (final u in RecurrenceUnit.values)
                    DropdownMenuItem(
                      value: u,
                      child: Text(
                        recurrenceUnitWord(u, n),
                        key: ValueKey('$p-unit-${u.name}'),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (u) {
                  if (u != null && u != unit) onUnitChanged(u);
                },
              ),
            ),
          ),
          if (onClear != null && !blank)
            IconButton(
              key: ValueKey('$p-interval-clear'),
              tooltip: 'Clear (calculate it)',
              onPressed: onClear,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
        ],
      ),
    );
    final note = errorText ?? helperText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (caption != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              caption!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: highlight ? scheme.tertiary : AppTheme.textMuted,
              ),
            ),
          ),
        row,
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 4),
            child: Text(
              note,
              style: theme.textTheme.bodySmall?.copyWith(
                color: errorText != null ? scheme.error : AppTheme.textMuted,
              ),
            ),
          ),
      ],
    );
  }
}
