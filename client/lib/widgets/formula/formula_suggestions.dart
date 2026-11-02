// The `$` autocomplete list (and the touch picker dialog) for FormulaField.
import 'package:budget_formula/budget_formula.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'formula_style.dart';
import 'variable_scope.dart';

const double suggestionRowDesktop = 40;
const double suggestionRowTouch = 48;
const int suggestionMaxRows = 6;

/// The list itself: rows of `$name`, description, value and unit badge.
class FormulaSuggestionList extends StatelessWidget {
  const FormulaSuggestionList({
    super.key,
    required this.items,
    required this.prefix,
    required this.highlighted,
    required this.scope,
    required this.rowHeight,
    required this.maxHeight,
    required this.onPick,
    required this.onHover,
    this.scrollController,
    this.onManage,
    this.onCreate,
  });

  final List<VariableValue> items;
  final String prefix;
  final int highlighted;
  final VariableScope scope;
  final double rowHeight;
  final double maxHeight;
  final ValueChanged<VariableValue> onPick;
  final ValueChanged<int> onHover;
  final ScrollController? scrollController;

  /// Owner (012): "Manage variables…" under "No variables yet".
  final VoidCallback? onManage;

  /// Owner (012): 'Create "\$x"…' under 'No variable named "\$x"'.
  final ValueChanged<String>? onCreate;

  /// The empty state's action row, if any (label, key, run).
  (String, String, IconData, VoidCallback)? get emptyAction =>
      emptyActionFor(scope, prefix, onManage: onManage, onCreate: onCreate);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = items.length;
    return Semantics(
      container: true,
      label: 'Variable suggestions, $n ${n == 1 ? 'result' : 'results'}',
      explicitChildNodes: true,
      child: Material(
        key: const ValueKey('formula-suggestions'),
        color: AppTheme.overlay,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: AppTheme.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: n == 0
              ? _empty(theme)
              : ListView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  shrinkWrap: true,
                  itemExtent: rowHeight,
                  itemCount: n,
                  itemBuilder: (context, i) => _row(theme, i),
                ),
        ),
      ),
    );
  }

  Widget _empty(ThemeData theme) {
    final none = scope.variables.isEmpty;
    final text = none ? 'No variables yet' : 'No variable named "\$$prefix"';
    final action = emptyAction;
    final line = _emptyLine(theme, text);
    if (action == null) return line;
    final (label, key, icon, run) = action;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        line,
        const Divider(height: 1),
        SizedBox(
          height: rowHeight,
          child: InkWell(
            key: ValueKey(key),
            onTap: run,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: AppTheme.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppTheme.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _emptyLine(ThemeData theme, String text) {
    return SizedBox(
      height: rowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            key: const ValueKey('formula-suggestions-empty'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppTheme.textMuted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(ThemeData theme, int i) {
    final v = items[i];
    final lower = v.name.toLowerCase();
    final selected = i == highlighted;
    final body = theme.textTheme.bodyMedium;
    final desc = scope.descriptions[lower];
    final value = formatVariableValue(
      v,
      decimals: scope.displayDecimals[lower],
    );
    final unitName = v.unit.name;
    return Semantics(
      button: true,
      selected: selected,
      label: '\$${v.name}, ${spokenVariableValue(v)}, $unitName',
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: (_) => onHover(i),
        child: InkWell(
          key: ValueKey('formula-suggestion-${v.name}'),
          canRequestFocus: false,
          onTap: () => onPick(v),
          child: Container(
            color: selected ? AppTheme.accentSoft : null,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Flexible(
                  child: Text.rich(
                    _name(v.name, body),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    desc ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppTheme.textFaint,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  value,
                  maxLines: 1,
                  style: body?.copyWith(color: AppTheme.textMuted),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 20,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppTheme.raised,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Text(
                    unitBadge(v.unit),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppTheme.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// `$name` with the typed part in bold.
  TextSpan _name(String name, TextStyle? base) {
    final style = base?.copyWith(color: AppTheme.accent);
    final bold =
        style?.copyWith(fontWeight: FontWeight.w700) ??
        const TextStyle(fontWeight: FontWeight.w700);
    final p = prefix.toLowerCase();
    final at = p.isEmpty ? -1 : name.toLowerCase().indexOf(p);
    if (at < 0) return TextSpan(text: '\$$name', style: style);
    return TextSpan(
      style: style,
      children: [
        TextSpan(text: '\$${name.substring(0, at)}'),
        TextSpan(text: name.substring(at, at + p.length), style: bold),
        TextSpan(text: name.substring(at + p.length)),
      ],
    );
  }
}

/// Touch: the picker as a dialog with a search box. Returns the choice.
/// [onManage] (owner, 012): after the dialog closes, open the manager
/// (with a name to create, or null).
/// [live] keeps the list current while the dialog is open (variables
/// that finish loading or are created meanwhile show up at once).
Future<VariableValue?> showVariablePicker(
  BuildContext context, {
  required VariableScope scope,
  ValueListenable<VariableScope>? live,
  ValueChanged<String?>? onManage,
}) => showDialog<VariableValue>(
  context: context,
  builder: (context) => live == null
      ? _PickerDialog(scope: scope, onManage: onManage)
      : ValueListenableBuilder<VariableScope>(
          valueListenable: live,
          builder: (context, s, _) =>
              _PickerDialog(scope: s, onManage: onManage),
        ),
);

class _PickerDialog extends StatefulWidget {
  const _PickerDialog({required this.scope, this.onManage});
  final VariableScope scope;
  final ValueChanged<String?>? onManage;

  @override
  State<_PickerDialog> createState() => _PickerDialogState();
}

class _PickerDialogState extends State<_PickerDialog> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _manage(String? name) {
    Navigator.of(context).pop();
    widget.onManage!(name);
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().replaceFirst(r'$', '');
    final items = rankCompletions(q, widget.scope.variables);
    final h = MediaQuery.sizeOf(context).height;
    return AlertDialog(
      key: const ValueKey('formula-picker-dialog'),
      title: const Text('Insert a variable'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('formula-picker-search'),
              controller: _search,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              decoration: const InputDecoration(
                hintText: 'Search variables',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (items.isNotEmpty) Navigator.of(context).pop(items.first);
              },
            ),
            const SizedBox(height: 8),
            FormulaSuggestionList(
              items: items,
              prefix: q,
              highlighted: -1,
              scope: widget.scope,
              rowHeight: suggestionRowTouch,
              maxHeight: (h * 0.4).clamp(suggestionRowTouch, 6 * 48.0),
              onPick: (v) => Navigator.of(context).pop(v),
              onManage: widget.onManage == null ? null : () => _manage(null),
              onCreate: widget.onManage == null ? null : _manage,
              onHover: (_) {},
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// The empty list's action (owner, 012): "Manage variables…" when there
/// are none at all, else 'Create "\$[prefix]"…' for a valid new name.
(String, String, IconData, VoidCallback)? emptyActionFor(
  VariableScope scope,
  String prefix, {
  VoidCallback? onManage,
  ValueChanged<String>? onCreate,
}) {
  if (scope.variables.isEmpty) {
    if (onManage == null) return null;
    return (
      'Manage variables…',
      'formula-manage-variables',
      Icons.tune_rounded,
      onManage,
    );
  }
  if (onCreate == null ||
      prefix.isEmpty ||
      variableNameProblem(prefix, const []) != null) {
    return null;
  }
  return (
    'Create "\$$prefix"…',
    'formula-create-variable',
    Icons.add_rounded,
    () => onCreate(prefix),
  );
}
