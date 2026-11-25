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
/// path (parent names regular, the leaf bold), opening a menu as wide as
/// the field. Folders in the menu wear a folder icon.
///
/// The menu is a tinted Favourites block (flat leaves, if any) then a
/// labelled Categories tree. Folders (categories with children) expand
/// and collapse inline — a tap anywhere on the folder row toggles them
/// and never selects. Only leaves can be picked or starred.
///
/// Rows are at least 48px tall; the menu scrolls past 60% of the screen
/// height. Keyboard: Enter / Space open it, the chosen (else first) leaf
/// takes focus, arrows move, Enter picks a leaf or toggles a folder, Esc
/// closes the menu only.
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
  /// `<prefix>expand-<id>` on a folder's chevron).
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

/// Leading slot shared by dots and folder icons so names stay aligned.
const double kCategoryLeadingSize = 18;

/// A stroked folder glyph, painted (not an icon-font [Icon]) so both the
/// open and closed states render on browsers that drop or fail to draw
/// Material folder codepoints even when they are in the release subset.
/// [open] adds a front lip; the chevron also shows state.
Widget categoryFolderIcon({
  required bool open,
  Color? color,
  double size = kCategoryLeadingSize,
  Key? key,
}) {
  return FolderGlyph(
    key: key,
    open: open,
    color: color ?? AppTheme.textMuted,
    size: size,
  );
}

/// Leading folder mark shared by the category picker and the manager.
class FolderGlyph extends StatelessWidget {
  const FolderGlyph({
    super.key,
    required this.open,
    required this.color,
    this.size = kCategoryLeadingSize,
  });

  final bool open;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _FolderGlyphPainter(open: open, color: color)),
    );
  }
}

class _FolderGlyphPainter extends CustomPainter {
  const _FolderGlyphPainter({required this.open, required this.color});

  final bool open;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    if (s <= 0) return;
    final stroke = (s * 0.1).clamp(1.2, 1.8);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    final pad = stroke * 0.65;
    final left = pad;
    final right = s - pad;
    final top = pad + s * 0.05;
    final bottom = s - pad;
    final tabH = s * 0.20;
    final tabW = s * 0.42;
    final r = s * 0.11;
    final rad = Radius.circular(r);

    final back = Path()
      ..moveTo(left, top + tabH)
      ..lineTo(left, top + r)
      ..arcToPoint(Offset(left + r, top), radius: rad)
      ..lineTo(left + tabW * 0.78, top)
      ..lineTo(left + tabW, top + tabH)
      ..lineTo(right - r, top + tabH)
      ..arcToPoint(Offset(right, top + tabH + r), radius: rad);

    if (!open) {
      back
        ..lineTo(right, bottom - r)
        ..arcToPoint(Offset(right - r, bottom), radius: rad)
        ..lineTo(left + r, bottom)
        ..arcToPoint(Offset(left, bottom - r), radius: rad)
        ..close();
      canvas.drawPath(back, paint);
      return;
    }

    // Rear pocket, then a front lip slightly dropped so "open" is obvious.
    final rearBottom = bottom - s * 0.18;
    back
      ..lineTo(right, rearBottom)
      ..lineTo(left, rearBottom)
      ..close();
    canvas.drawPath(back, paint);

    final flapTop = top + tabH + s * 0.16;
    final inset = s * 0.07;
    final flap = Path()
      ..moveTo(left, flapTop)
      ..lineTo(right, flapTop)
      ..lineTo(right - inset, bottom)
      ..lineTo(left + inset, bottom)
      ..close();
    canvas.drawPath(flap, paint);
  }

  @override
  bool shouldRepaint(covariant _FolderGlyphPainter old) =>
      old.open != open || old.color != color;
}

/// Same const-[Icon] split for the expand/collapse chevron.
Widget categoryExpandIcon({
  required bool open,
  Color? color,
  double? size,
  Key? key,
}) {
  Widget icon = open
      ? const Icon(Icons.expand_more_rounded)
      : const Icon(Icons.chevron_right_rounded);
  if (color != null || size != null) {
    icon = IconTheme(
      data: IconThemeData(color: color, size: size),
      child: icon,
    );
  }
  return key == null ? icon : KeyedSubtree(key: key, child: icon);
}

/// A single-line path: ancestor names in regular weight, the leaf in bold.
/// A top-level leaf is just bold. Ellipsizes as one run.
class CategoryPathLabel extends StatelessWidget {
  const CategoryPathLabel({
    super.key,
    required this.names,
    this.style,
    this.separator = ' › ',
  });

  /// Ancestor names followed by the leaf (a single name is a top-level leaf).
  final List<String> names;
  final TextStyle? style;
  final String separator;

  factory CategoryPathLabel.fromCategories({
    Key? key,
    required Iterable<Category> categories,
    required String id,
    TextStyle? style,
    String separator = ' › ',
  }) => CategoryPathLabel(
    key: key,
    names: [for (final c in categoryPath(categories, id)) c.name],
    style: style,
    separator: separator,
  );

  @override
  Widget build(BuildContext context) {
    if (names.isEmpty) return const SizedBox.shrink();
    final base = style ?? DefaultTextStyle.of(context).style;
    final leafStyle = base.copyWith(fontWeight: FontWeight.w700);
    if (names.length == 1) {
      return Text(
        names.single,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: leafStyle,
      );
    }
    final parentStyle = base.copyWith(fontWeight: FontWeight.w400);
    final parent = names.sublist(0, names.length - 1).join(separator);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: parent + separator, style: parentStyle),
          TextSpan(text: names.last, style: leafStyle),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
    );
  }
}

class _CategoryDropdownState extends State<CategoryDropdown> {
  final _menu = MenuController();
  final _focusItem = FocusNode(debugLabel: 'category dropdown row');
  bool _isOpen = false;

  /// Driven by the keyboard (opened with Enter / Space / ↓ or a key
  /// pressed since): only then does the focused row show its ring.
  bool _keyboardNav = false;

  /// Folder ids that are expanded in the inline tree.
  final Set<String> _expanded = {};

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
    _expandSelectedPath();
    _holdMenu = true;
    _menu.open();
  }

  void _expandSelectedPath() {
    final sel = widget.selectedId;
    if (sel == null) return;
    for (final step in categoryPath(widget.categories, sel)) {
      if (step.id != sel) _expanded.add(step.id);
    }
  }

  void _reopenIfHeld({int frames = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_holdMenu) return;
      if (!_menu.isOpen) _menu.open();
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
        if (byId[id] != null && isCategoryLeaf(_pool, byId[id]!)) byId[id]!,
    ];
  }

  void _pick(Category? c) {
    if (c != null && !isCategoryLeaf(_pool, c)) {
      _toggleExpand(c.id);
      return;
    }
    _holdMenu = false;
    _menu.close();
    widget.onSelected(c);
  }

  void _toggleExpand(String id) {
    _holdMenu = true;
    setState(() {
      if (!_expanded.add(id)) _expanded.remove(id);
    });
    _reopenIfHeld();
    _focusRow();
  }

  Widget _leading(Category? c, {required bool isFolder, required bool open}) {
    Widget child;
    if (c == null) {
      child = const Icon(
        Icons.sell_outlined,
        size: 18,
        color: AppTheme.textMuted,
      );
    } else if (isFolder) {
      child = categoryFolderIcon(
        open: open,
        key: ValueKey('${widget.itemKeyPrefix}folder-${c.id}'),
        color: colorFromHex(c.color) ?? AppTheme.textMuted,
      );
    } else {
      child = Center(child: categoryDot(colorFromHex(c.color)));
    }
    return SizedBox(
      width: kCategoryLeadingSize,
      height: kCategoryLeadingSize,
      child: child,
    );
  }

  Widget _entry(Category? c, {TextStyle? style, bool showPath = false}) {
    final isFolder = c != null && categoryHasChildren(_pool, c.id);
    final open = c != null && _expanded.contains(c.id);
    final Widget label;
    if (c == null) {
      label = Text(
        widget.allLabel ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: style,
      );
    } else if (showPath) {
      label = CategoryPathLabel.fromCategories(
        categories: widget.categories,
        id: c.id,
        style: style,
      );
    } else if (isFolder) {
      label = Text(
        c.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: style,
      );
    } else {
      label = CategoryPathLabel(names: [c.name], style: style);
    }
    return Row(
      children: [
        _leading(c, isFolder: isFolder, open: open),
        const SizedBox(width: 10),
        Expanded(child: label),
      ],
    );
  }

  void _toggleFavorite(Category c) {
    if (!isCategoryLeaf(_pool, c)) return;
    _holdMenu = true;
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

  Widget _sectionLabel(String text, {Key? key}) => Padding(
    key: key,
    padding: const EdgeInsets.fromLTRB(16, 10, 12, 6),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: AppTheme.textMuted,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.8,
      ),
    ),
  );

  Widget _row(
    Category? c, {
    required double width,
    required bool selected,
    bool focus = false,
    bool showPath = false,
    int depth = 0,
  }) {
    final pool = _pool;
    final isFolder = c != null && categoryHasChildren(pool, c.id);
    final open = c != null && _expanded.contains(c.id);
    final star = c != null && !isFolder && widget.onToggleFavorite != null;
    Widget? trailing;
    if (isFolder) {
      trailing = categoryExpandIcon(
        open: open,
        key: ValueKey('${widget.itemKeyPrefix}expand-${c.id}'),
        color: AppTheme.textMuted,
        size: 22,
      );
    } else if (selected) {
      trailing = const Icon(Icons.check_rounded, size: 18);
    }
    return SizedBox(
      key: ValueKey('${widget.itemKeyPrefix}${c?.id ?? 'all'}'),
      width: width,
      child: Row(
        children: [
          Expanded(
            child: MenuItemButton(
              focusNode: focus ? _focusItem : null,
              style: _style,
              closeOnActivate: !isFolder,
              onPressed: () {
                if (isFolder) {
                  _toggleExpand(c.id);
                } else {
                  _pick(c);
                }
              },
              trailingIcon: trailing,
              child: Padding(
                padding: EdgeInsets.only(left: 16.0 * depth),
                child: Semantics(
                  selected: selected,
                  button: true,
                  label: c == null
                      ? widget.allLabel
                      : (isFolder
                            ? (open ? 'Collapse ${c.name}' : 'Expand ${c.name}')
                            : c.name),
                  child: _entry(c, showPath: showPath),
                ),
              ),
            ),
          ),
          if (star) _star(c),
        ],
      ),
    );
  }

  void _addTree(
    List<Widget> widgets,
    Category c, {
    required double width,
    required Category? selected,
    required void Function(Category? c, {bool showPath, int depth}) addRow,
    int depth = 0,
  }) {
    addRow(c, showPath: false, depth: depth);
    if (!_expanded.contains(c.id)) return;
    for (final ch in childCategories(_pool, c.id)) {
      _addTree(
        widgets,
        ch,
        width: width,
        selected: selected,
        addRow: addRow,
        depth: depth + 1,
      );
    }
  }

  List<Widget> _menuChildren(double width) {
    final pool = _pool;
    final selected = _selected;
    final footer = widget.footer;
    final widgets = <Widget>[];
    var focusAssigned = false;
    void addRow(Category? c, {bool showPath = false, int depth = 0}) {
      final sel =
          (c != null && isCategoryLeaf(pool, c) && c.id == selected?.id) ||
          (c == null && selected == null);
      final focus = !focusAssigned && (sel || selected == null);
      widgets.add(
        _row(
          c,
          width: width,
          selected: sel,
          focus: focus,
          showPath: showPath,
          depth: depth,
        ),
      );
      if (focus) focusAssigned = true;
    }

    if (widget.allLabel != null) addRow(null);
    final favs = _favorites;
    if (favs.isNotEmpty) {
      widgets.add(
        ColoredBox(
          key: ValueKey('${widget.itemKeyPrefix}favorites-block'),
          color: AppTheme.accentSoft,
          child: _sectionLabel(
            'FAVOURITES',
            key: ValueKey('${widget.itemKeyPrefix}favorites-header'),
          ),
        ),
      );
      for (final c in favs) {
        final sel = c.id == selected?.id;
        widgets.add(
          ColoredBox(
            color: AppTheme.accentSoft,
            child: _row(
              c,
              width: width,
              selected: sel,
              focus: !focusAssigned && sel,
              showPath: c.parentId != null,
            ),
          ),
        );
        if (sel) focusAssigned = true;
      }
      widgets.add(
        const ColoredBox(
          color: AppTheme.borderStrong,
          child: SizedBox(height: 2, width: double.infinity),
        ),
      );
    }
    widgets.add(
      _sectionLabel(
        'CATEGORIES',
        key: ValueKey('${widget.itemKeyPrefix}categories-header'),
      ),
    );
    for (final c in rootCategories(pool)) {
      _addTree(widgets, c, width: width, selected: selected, addRow: addRow);
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
          // Esc with the menu open closes the menu only: the key stops
          // here instead of reaching an enclosing editor's shortcuts.
          onKeyEvent: (node, e) {
            if (e is KeyDownEvent &&
                e.logicalKey == LogicalKeyboardKey.escape &&
                _menu.isOpen) {
              _holdMenu = false;
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
              setState(() {
                _isOpen = true;
                _expandSelectedPath();
              });
              _focusRow();
            },
            onClose: () {
              HardwareKeyboard.instance.removeHandler(_onKey);
              if (mounted && !_holdMenu) {
                setState(() => _isOpen = false);
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
