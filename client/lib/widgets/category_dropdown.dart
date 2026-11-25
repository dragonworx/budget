import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/category_tree.dart';
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
/// name (with a path when it has a parent), opening a menu as wide as the
/// field.
///
/// The menu is Favourites (flat, if any) then a separator then top-level
/// categories. A parent drills into a submenu of its children; the parent
/// itself stays selectable. On touch the submenu is a pushed page with a
/// back row.
///
/// Rows are at least 48px tall; the menu scrolls past 60% of the screen
/// height. Keyboard: Enter / Space open it, the chosen (else first) row
/// takes focus, arrows move, Enter picks, Esc closes the menu only (or
/// goes back one drill-in page).
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
    this.favoriteIds = const [],
    this.onToggleFavorite,
    this.hideHiddenBranches = false,
  });

  final List<Category> categories;

  /// The chosen category's id (null: [allLabel], or nothing chosen yet).
  final String? selectedId;

  /// A category, or null for the [allLabel] row.
  final ValueChanged<Category?> onSelected;

  /// On the field (tap target).
  final Key triggerKey;

  /// Menu rows are keyed `<prefix><id>` (`<prefix>all` for [allLabel],
  /// `<prefix>drill-<id>` to open a parent's children, `<prefix>back`).
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

  /// Category ids this user has favourited, in their order.
  final List<String> favoriteIds;

  /// When set, each row shows a star that calls this (does not close the
  /// menu).
  final ValueChanged<Category>? onToggleFavorite;

  /// When true, hidden categories and the children of a hidden parent are
  /// left out (transaction picker). The events-list filter keeps them.
  final bool hideHiddenBranches;

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

  /// Non-null: the submenu of this parent's children is showing.
  String? _drillId;

  /// Kept across a favourite-toggle rebuild that may close the menu.
  String? _restoreDrillId;

  /// True while the user still wants the menu open (a parent rebuild
  /// after starring otherwise closes MenuAnchor).
  bool _holdMenu = false;

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
    if (_menu.isOpen) {
      _holdMenu = false;
      return _menu.close();
    }
    _keyboardNav = HardwareKeyboard.instance.logicalKeysPressed.any(
      _openKeys.contains,
    );
    _restoreDrillId = null;
    _drillId = null;
    _holdMenu = true;
    _menu.open();
  }

  void _reopenIfHeld({int frames = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_holdMenu) return;
      if (!_menu.isOpen) _menu.open();
      final keep = _restoreDrillId;
      if (keep != null && _drillId != keep) {
        setState(() => _drillId = keep);
      }
      if (frames < 20) _reopenIfHeld(frames: frames + 1);
    });
  }

  @override
  void didUpdateWidget(CategoryDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_holdMenu) _reopenIfHeld();
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

  List<Category> get _pool {
    final all = widget.categories;
    return widget.hideHiddenBranches ? visibleForPicker(all) : [...all];
  }

  Category? get _selected {
    for (final c in widget.categories) {
      if (c.id == widget.selectedId) return c;
    }
    return null;
  }

  List<Category> get _favorites {
    final byId = {for (final c in _pool) c.id: c};
    return [
      for (final id in widget.favoriteIds)
        if (byId[id] != null) byId[id]!,
    ];
  }

  void _pick(Category? c) {
    _holdMenu = false;
    _restoreDrillId = null;
    _drillId = null;
    _menu.close();
    widget.onSelected(c);
  }

  void _drill(String? id) {
    setState(() => _drillId = id);
    _focusRow();
  }

  Widget _entry(Category? c, {TextStyle? style, bool showPath = false}) => Row(
    children: [
      if (c == null)
        const Icon(Icons.sell_outlined, size: 16, color: AppTheme.textMuted)
      else
        categoryDot(colorFromHex(c.color)),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          c == null
              ? (widget.allLabel ?? '')
              : (showPath
                    ? categoryPathLabel(widget.categories, c.id)
                    : c.name),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    ],
  );

  void _toggleFavorite(Category c) {
    _holdMenu = true;
    _restoreDrillId = _drillId;
    widget.onToggleFavorite!(c);
    _reopenIfHeld();
  }

  Widget _star(Category c) {
    final on = widget.favoriteIds.contains(c.id);
    return IconButton(
      key: ValueKey('${widget.itemKeyPrefix}star-${c.id}'),
      tooltip: on ? 'Remove from favourites' : 'Add to favourites',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      iconSize: 18,
      onPressed: widget.onToggleFavorite == null
          ? null
          : () => _toggleFavorite(c),
      icon: Icon(
        on ? Icons.star_rounded : Icons.star_border_rounded,
        color: on ? AppTheme.accent : AppTheme.textMuted,
      ),
    );
  }

  Widget _row(
    Category? c, {
    required double width,
    required bool selected,
    bool focus = false,
    bool showPath = false,
    List<Category> children = const [],
  }) {
    final actions = <Widget>[
      if (c != null && widget.onToggleFavorite != null) _star(c),
      if (c != null && children.isNotEmpty)
        IconButton(
          key: ValueKey('${widget.itemKeyPrefix}drill-${c.id}'),
          tooltip: 'Show ${c.name} categories',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 36, height: 36),
          iconSize: 20,
          onPressed: () => _drill(c.id),
          icon: const Icon(Icons.chevron_right_rounded),
        ),
    ];
    // Star / chevron sit beside the MenuItemButton, not in trailingIcon:
    // on Flutter web a trailing IconButton's taps are eaten by the parent
    // item and would select (and close) instead of starring or drilling.
    return SizedBox(
      key: ValueKey('${widget.itemKeyPrefix}${c?.id ?? 'all'}'),
      width: width,
      child: Row(
        children: [
          Expanded(
            child: MenuItemButton(
              focusNode: focus ? _focusItem : null,
              style: _style,
              onPressed: () => _pick(c),
              trailingIcon: selected
                  ? const Icon(Icons.check_rounded, size: 18)
                  : null,
              child: Semantics(
                selected: selected,
                child: _entry(c, showPath: showPath),
              ),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }

  List<Widget> _menuChildren(double width) {
    final pool = _pool;
    final selected = _selected;
    final footer = widget.footer;
    final widgets = <Widget>[];
    var focusAssigned = false;
    void addRow(
      Category? c, {
      bool showPath = false,
      List<Category> children = const [],
    }) {
      final sel = c?.id == selected?.id || (c == null && selected == null);
      widgets.add(
        _row(
          c,
          width: width,
          selected: sel,
          focus: !focusAssigned && (sel || widgets.isEmpty),
          showPath: showPath,
          children: children,
        ),
      );
      if (sel || widgets.length == 1) focusAssigned = true;
    }

    final drill = _drillId == null ? null : categoryById(pool, _drillId);
    if (drill != null) {
      widgets.add(
        SizedBox(
          width: width,
          child: MenuItemButton(
            key: ValueKey('${widget.itemKeyPrefix}back'),
            focusNode: _focusItem,
            style: _style,
            leadingIcon: const Icon(Icons.arrow_back_rounded, size: 18),
            onPressed: () => _drill(null),
            child: const Text('Back'),
          ),
        ),
      );
      focusAssigned = true;
      // The parent itself is still selectable on this page.
      addRow(drill, children: const []);
      for (final ch in childCategories(pool, drill.id)) {
        addRow(ch);
      }
    } else {
      if (widget.allLabel != null) addRow(null);
      final favs = _favorites;
      if (favs.isNotEmpty) {
        widgets.add(
          Padding(
            key: ValueKey('${widget.itemKeyPrefix}favorites-header'),
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 4),
            child: Text(
              'Favourites',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: AppTheme.textMuted,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
        );
        for (final c in favs) {
          addRow(c, showPath: c.parentId != null);
        }
        widgets.add(const Divider(height: 9));
      }
      for (final c in rootCategories(pool)) {
        addRow(c, children: childCategories(pool, c.id));
      }
    }
    if (footer != null) {
      widgets.add(const Divider(height: 9));
      widgets.add(
        SizedBox(
          width: width,
          child: MenuItemButton(
            key: footer.key,
            focusNode: widgets.isEmpty ? _focusItem : null,
            style: _style,
            leadingIcon: Icon(footer.icon, size: 18),
            onPressed: () {
              _holdMenu = false;
              footer.onPressed();
            },
            child: Text(
              footer.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = _selected;
    final textStyle = widget.dense ? null : theme.textTheme.bodyLarge;
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        return Focus(
          canRequestFocus: false,
          skipTraversal: true,
          // Esc with the menu open closes the submenu first, then the menu
          // only: the key stops here instead of reaching an enclosing
          // editor's shortcuts.
          onKeyEvent: (node, e) {
            if (e is KeyDownEvent &&
                e.logicalKey == LogicalKeyboardKey.escape &&
                _menu.isOpen) {
              if (_drillId != null) {
                _drill(null);
              } else {
                _holdMenu = false;
                _menu.close();
              }
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
              setState(() {
                _isOpen = true;
                _drillId = _restoreDrillId;
                _restoreDrillId = null;
              });
              _focusRow();
            },
            onClose: () {
              HardwareKeyboard.instance.removeHandler(_onKey);
              if (mounted && !_holdMenu) {
                setState(() {
                  _isOpen = false;
                  _drillId = null;
                });
              }
            },
            menuChildren: _menuChildren(width),
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
                  child: _entry(selected, style: textStyle, showPath: true),
                ),
              );
              return Semantics(
                button: widget.enabled,
                label: widget.semanticsLabel,
                value: selected == null
                    ? widget.allLabel
                    : categoryPathLabel(widget.categories, selected.id),
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
