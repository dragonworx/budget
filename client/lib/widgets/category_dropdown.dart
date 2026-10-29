import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../features/timeline/stack_lanes.dart' show colorFromHex;
import '../theme/app_theme.dart';

/// A row at the foot of a [CategoryDropdown]'s menu, after a divider
/// (e.g. "Manage categories…").
class CategoryDropdownAction {
  const CategoryDropdownAction({
    required this.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final Key key;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
}

/// The full-width category drop-down shared by the Events list filter and
/// the event editor: a field showing the chosen category's colour dot and
/// name, opening a menu (not a route, so the list can change under it
/// without a pop) as wide as the field, one row per category in name order
/// ([sortedCategories]), each with its dot, an ellipsised name and a check
/// on the chosen one.
///
/// Rows are at least 48px tall; the menu scrolls past 60% of the screen
/// height. Keyboard: Enter / Space open it, the chosen (else first) row
/// takes focus, arrows move, Enter picks, Esc closes the menu only (never
/// an enclosing editor or dialog).
class CategoryDropdown extends StatefulWidget {
  const CategoryDropdown({
    super.key,
    required this.categories,
    required this.selectedId,
    required this.onSelected,
    required this.triggerKey,
    required this.itemKeyPrefix,
    this.allLabel,
    this.labelText,
    this.errorText,
    this.errorKey,
    this.semanticsLabel = 'Category',
    this.enabled = true,
    this.dense = false,
    this.footer,
  });

  final List<Category> categories;

  /// The chosen category's id (null: [allLabel], or nothing chosen yet).
  final String? selectedId;

  /// A category, or null for the [allLabel] row.
  final ValueChanged<Category?> onSelected;

  /// On the field (tap target).
  final Key triggerKey;

  /// Menu rows are keyed `<prefix><id>` (`<prefix>all` for [allLabel]).
  final String itemKeyPrefix;

  /// When set, a first "all" row (a filter's default).
  final String? allLabel;

  /// The field's floating label (none when null).
  final String? labelText;
  final String? errorText;
  final Key? errorKey;
  final String semanticsLabel;

  /// False: read-only, shows the choice, opens no menu.
  final bool enabled;

  /// Compact field (filters) rather than a form field.
  final bool dense;

  /// After a divider at the bottom of the menu.
  final CategoryDropdownAction? footer;

  @override
  State<CategoryDropdown> createState() => _CategoryDropdownState();
}

/// The colour dot a category wears in pickers.
Widget categoryDot(Color? color, {double size = 10}) => Container(
  width: size,
  height: size,
  decoration: BoxDecoration(
    color: color ?? AppTheme.textFaint,
    shape: BoxShape.circle,
  ),
);

class _CategoryDropdownState extends State<CategoryDropdown> {
  final _menu = MenuController();
  final _focusItem = FocusNode(debugLabel: 'category dropdown row');
  bool _isOpen = false;

  /// Driven by the keyboard (opened with Enter / Space / ↓ or a key
  /// pressed since): only then does the focused row show its ring.
  bool _keyboardNav = false;

  static final _openKeys = {
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.arrowDown,
  };

  bool _onKey(KeyEvent e) {
    if (e is KeyDownEvent && _isOpen && !_keyboardNav && mounted) {
      setState(() => _keyboardNav = true);
    }
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _focusItem.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_menu.isOpen) return _menu.close();
    _keyboardNav = HardwareKeyboard.instance.logicalKeysPressed.any(
      _openKeys.contains,
    );
    _menu.open();
  }

  /// The chosen (else first) row takes focus on open, so arrows / Enter /
  /// Esc work at once; re-asserted for a few frames (the menu builds a
  /// frame late on web and the trigger's tap can take focus back).
  void _focusRow([int frame = 0]) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_menu.isOpen) return;
        if (_focusItem.context != null && !_menuHasFocus()) {
          _focusItem.requestFocus();
        }
        if (frame < 4) _focusRow(frame + 1);
      });

  bool _menuHasFocus() {
    final f = FocusManager.instance.primaryFocus;
    if (f == null || f == _focusItem) return f == _focusItem;
    return f.context?.findAncestorWidgetOfExactType<MenuItemButton>() != null;
  }

  ButtonStyle get _style =>
      MenuItemButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ).copyWith(
        side: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.focused) && _keyboardNav
              ? const BorderSide(color: AppTheme.accent, width: 2)
              : BorderSide.none,
        ),
        overlayColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.pressed)) {
            return AppTheme.text.withValues(alpha: 0.10);
          }
          if (s.contains(WidgetState.hovered)) {
            return AppTheme.text.withValues(alpha: 0.06);
          }
          if (s.contains(WidgetState.focused) && _keyboardNav) {
            return AppTheme.text.withValues(alpha: 0.08);
          }
          return Colors.transparent;
        }),
      );

  Widget _entry(Category? c, {TextStyle? style}) => Row(
    children: [
      if (c == null)
        const Icon(Icons.sell_outlined, size: 16, color: AppTheme.textMuted)
      else
        categoryDot(colorFromHex(c.color)),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          c?.name ?? widget.allLabel ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    ],
  );

  Category? get _selected {
    for (final c in widget.categories) {
      if (c.id == widget.selectedId) return c;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = sortedCategories(widget.categories);
    final selected = _selected;
    final rows = <Category?>[if (widget.allLabel != null) null, ...list];
    final focusAt = rows.contains(selected) ? rows.indexOf(selected) : 0;
    final footer = widget.footer;
    final textStyle = widget.dense ? null : theme.textTheme.bodyLarge;
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        return Focus(
          canRequestFocus: false,
          skipTraversal: true,
          // Esc with the menu open closes the menu only: the key stops here
          // instead of reaching an enclosing editor's shortcuts.
          onKeyEvent: (node, e) {
            if (e is KeyDownEvent &&
                e.logicalKey == LogicalKeyboardKey.escape &&
                _menu.isOpen) {
              _menu.close();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: MenuAnchor(
            controller: _menu,
            alignmentOffset: const Offset(0, 4),
            style: MenuStyle(
              minimumSize: WidgetStatePropertyAll(Size(width, 0)),
              maximumSize: WidgetStatePropertyAll(
                Size(width, MediaQuery.sizeOf(context).height * 0.6),
              ),
            ),
            onOpen: () {
              HardwareKeyboard.instance.addHandler(_onKey);
              setState(() => _isOpen = true);
              _focusRow();
            },
            onClose: () {
              HardwareKeyboard.instance.removeHandler(_onKey);
              if (mounted) setState(() => _isOpen = false);
            },
            menuChildren: [
              for (final (i, c) in rows.indexed)
                SizedBox(
                  width: width,
                  child: MenuItemButton(
                    key: ValueKey('${widget.itemKeyPrefix}${c?.id ?? 'all'}'),
                    focusNode: i == focusAt ? _focusItem : null,
                    style: _style,
                    onPressed: () => widget.onSelected(c),
                    trailingIcon: c?.id == selected?.id
                        ? const Icon(Icons.check_rounded, size: 18)
                        : null,
                    child: Semantics(
                      selected: c?.id == selected?.id,
                      child: _entry(c),
                    ),
                  ),
                ),
              if (footer != null) ...[
                const Divider(height: 9),
                SizedBox(
                  width: width,
                  child: MenuItemButton(
                    key: footer.key,
                    focusNode: rows.isEmpty ? _focusItem : null,
                    style: _style,
                    leadingIcon: Icon(footer.icon, size: 18),
                    onPressed: footer.onPressed,
                    child: Text(
                      footer.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ],
            builder: (context, controller, _) {
              final field = InputDecorator(
                isFocused: controller.isOpen,
                decoration: InputDecoration(
                  isDense: widget.dense,
                  enabled: widget.enabled,
                  labelText: widget.labelText,
                  contentPadding: widget.dense
                      ? const EdgeInsets.fromLTRB(12, 10, 8, 10)
                      : null,
                  suffixIcon: widget.enabled
                      ? const Icon(Icons.arrow_drop_down_rounded)
                      : null,
                  error: widget.errorText == null
                      ? null
                      : Text(
                          widget.errorText!,
                          key: widget.errorKey,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                ),
                child: ExcludeSemantics(
                  child: _entry(selected, style: textStyle),
                ),
              );
              return Semantics(
                button: widget.enabled,
                label: widget.semanticsLabel,
                value: selected?.name ?? widget.allLabel,
                child: InkWell(
                  key: widget.triggerKey,
                  borderRadius: BorderRadius.circular(12),
                  onTap: widget.enabled ? _toggle : null,
                  child: field,
                ),
              );
            },
          ),
        );
      },
    );
  }
}
