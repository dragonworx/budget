// The "Formulas" help popover: one constant shared with the docs.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../theme/app_theme.dart';

class FormulaHelp {
  const FormulaHelp({
    required this.title,
    required this.intro,
    required this.examples,
    required this.notes,
  });
  final String title;
  final String intro;

  /// (formula, meaning).
  final List<(String, String)> examples;
  final List<String> notes;
}

/// The syntax help, in one place (docs quote it from here).
const formulaHelp = FormulaHelp(
  title: 'Formulas',
  intro: 'Use numbers, variables and + − × ÷ ( ).',
  examples: [
    ('rent / 4', 'A quarter of your rent'),
    ('(rent + 50) * 2', 'Rent plus 50, doubled'),
    ('salary * 12 / 52', 'Monthly salary as a weekly amount'),
    ('-fee', 'The fee, negated'),
  ],
  notes: [
    'Type a variable\'s name to pick it from the list.',
    'Results are rounded to cents at the end.',
    'Not yet: % signs and functions like round().',
  ],
);

/// The `?` suffix button and its popover.
/// Sort-key group for a formula field and its help button (see
/// FormulaField's build).
const formulaSortName = 'formula-field';

class FormulaHelpButton extends StatelessWidget {
  const FormulaHelpButton({
    super.key,
    this.onOpenChanged,
    this.buttonKey,
    this.onManage,
    this.compact = false,
  });

  /// A smaller button for dense boxes (rate rows, side-by-side terms).
  final bool compact;

  final ValueChanged<bool>? onOpenChanged;
  final Key? buttonKey;

  /// Owner (012): a "Manage variables…" link at the bottom.
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    return Semantics(
      container: true,
      sortKey: const OrdinalSortKey(1, name: formulaSortName),
      child: _anchor(context, theme, small),
    );
  }

  Widget _anchor(BuildContext context, ThemeData theme, TextStyle? small) {
    return MenuAnchor(
      onOpen: () => onOpenChanged?.call(true),
      onClose: () => onOpenChanged?.call(false),
      alignmentOffset: const Offset(-280, 0),
      menuChildren: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              key: const ValueKey('formula-help'),
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(formulaHelp.title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                Text(formulaHelp.intro, style: small),
                const SizedBox(height: 8),
                for (final (f, meaning) in formulaHelp.examples)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 128,
                          child: Text(
                            f,
                            style: small?.copyWith(
                              color: AppTheme.accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            meaning,
                            style: small?.copyWith(color: AppTheme.textMuted),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                for (final n in formulaHelp.notes)
                  Text(n, style: small?.copyWith(color: AppTheme.textMuted)),
                if (onManage != null) ...[
                  const SizedBox(height: 6),
                  Builder(
                    builder: (menuContext) => TextButton.icon(
                      key: const ValueKey('formula-help-manage'),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () {
                        MenuController.maybeOf(menuContext)?.close();
                        onManage!();
                      },
                      icon: const Icon(Icons.tune_rounded, size: 16),
                      label: const Text('Manage variables…'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        key: buttonKey,
        tooltip: 'Formula help',
        constraints: BoxConstraints(minWidth: compact ? 32 : 40, minHeight: 40),
        padding: compact ? EdgeInsets.zero : null,
        iconSize: compact ? 16 : 18,
        icon: const Icon(Icons.help_outline),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}
