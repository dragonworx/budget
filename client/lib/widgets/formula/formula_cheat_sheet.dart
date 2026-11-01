// The "Formulas" help popover: one constant shared with the docs.
import 'package:flutter/material.dart';

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
    (r'$rent / 4', 'A quarter of your rent'),
    (r'($rent + 50) * 2', 'Rent plus 50, doubled'),
    (r'$salary * 12 / 52', 'Monthly salary as a weekly amount'),
    (r'-$fee', 'The fee, negated'),
  ],
  notes: [
    r'Type $ to pick a variable.',
    'Results are rounded to cents at the end.',
    'Not yet: % signs and functions like round().',
  ],
);

/// The `?` suffix button and its popover.
class FormulaHelpButton extends StatelessWidget {
  const FormulaHelpButton({
    super.key,
    this.onOpenChanged,
    this.buttonKey,
    this.onManage,
  });

  final ValueChanged<bool>? onOpenChanged;
  final Key? buttonKey;

  /// Owner (012): a "Manage variables…" link at the bottom.
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
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
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        iconSize: 18,
        icon: const Icon(Icons.help_outline),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}
