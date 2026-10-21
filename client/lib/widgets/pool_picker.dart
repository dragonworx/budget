import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../boot/page_stub.dart'
    if (dart.library.js_interop) '../boot/page_web.dart';
import '../data/models.dart';
import '../state/providers.dart';
import '../theme/app_theme.dart';
import 'pool_icon.dart';

/// Reusable pool picker: a dropdown anchored to the trigger, with a flat
/// list of my pools (the current one checked), then a "Shared with me"
/// section, then an optional New pool action. Pools
/// are top level, so there are no submenus.
///
/// Rows are at least 48px tall and the menu is kept on screen (320px+).
/// Arrow keys / Enter / Esc work as in any menu (the first row is focused
/// on open); an outside tap dismisses.
///
/// [builder] draws the trigger; call the `open` callback it receives.
class PoolPicker extends ConsumerStatefulWidget {
  const PoolPicker({
    super.key,
    required this.builder,
    required this.onSelected,
    this.excludePoolId,
    this.currentPoolId,
    this.editableOnly = false,
    this.onNewPool,
    this.title = 'Choose a pool',
    this.keyPrefix = 'picker',
  });

  final Widget Function(BuildContext context, VoidCallback open) builder;
  final ValueChanged<Pool> onSelected;
  final String? excludePoolId;
  final String? currentPoolId;

  /// Only pools I can edit (transfer destinations).
  final bool editableOnly;

  /// Action row at the bottom (omitted when null). The Pools home is
  /// reached from the timeline's back arrow, not from this menu.
  final VoidCallback? onNewPool;

  /// Accessible name of the menu.
  final String title;
  final String keyPrefix;

  @override
  ConsumerState<PoolPicker> createState() => _PoolPickerState();
}

/// Touch-friendly menu rows (at least 48px tall).
final ButtonStyle _itemStyle = MenuItemButton.styleFrom(
  minimumSize: const Size(0, 48),
  padding: const EdgeInsets.symmetric(horizontal: 12),
);

MenuStyle _menuStyle(BuildContext context) {
  final screen = MediaQuery.sizeOf(context);
  return MenuStyle(
    maximumSize: WidgetStatePropertyAll(
      Size(
        (screen.width - 16).clamp(160.0, 340.0).toDouble(),
        (screen.height * 0.7).clamp(160.0, 560.0).toDouble(),
      ),
    ),
  );
}

class _PoolPickerState extends ConsumerState<PoolPicker> {
  final _menu = MenuController();
  final _firstItem = FocusNode(debugLabel: 'pool picker first item');
  bool _isOpen = false;

  /// The menu is being driven by the keyboard (opened with Enter / Space /
  /// ↓, or a key pressed since): only then does the focused row show its
  /// ring. Opened by touch or mouse, the first row still takes focus (so
  /// arrows / Esc work at once) but shows no outline.
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

  ButtonStyle get _style => _itemStyle.copyWith(
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

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _firstItem.dispose();
    super.dispose();
  }

  void _open() {
    if (_menu.isOpen) {
      _menu.close();
      return;
    }
    _keyboardNav = HardwareKeyboard.instance.logicalKeysPressed.any(
      _openKeys.contains,
    );
    _menu.open();
  }

  /// The first row takes focus on open, so arrows / Enter / Esc work at
  /// once. Re-asserted for a few frames: the
  /// menu builds a frame late on web and the trigger's tap can take focus
  /// back.
  void _focusFirst([int frame = 0]) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_menu.isOpen) return;
        if (_firstItem.context != null && !_menuHasFocus()) {
          _firstItem.requestFocus();
        }
        if (frame < 4) _focusFirst(frame + 1);
      });

  /// Focus is already on a row of this menu (don't steal it back).
  bool _menuHasFocus() {
    final f = FocusManager.instance.primaryFocus;
    if (f == null || f == _firstItem) return f == _firstItem;
    return f.context?.findAncestorWidgetOfExactType<MenuItemButton>() != null;
  }

  Widget _poolItem(Pool a, {FocusNode? focus}) => MenuItemButton(
    key: ValueKey('${widget.keyPrefix}-pool-${a.id}'),
    focusNode: focus,
    style: _style,
    leadingIcon: a.id == widget.currentPoolId
        ? const Icon(Icons.check_rounded, size: 18, color: AppTheme.accent)
        : const PoolIcon(key: ValueKey('pool-icon'), size: 18),
    onPressed: () => widget.onSelected(a),
    trailingIcon: sharedIndicator(a),
    child: _MenuLabel(a.name),
  );

  Widget _action(
    String key,
    IconData icon,
    String label,
    VoidCallback f, {
    FocusNode? focus,
  }) => MenuItemButton(
    key: ValueKey('${widget.keyPrefix}-$key'),
    focusNode: focus,
    style: _style,
    leadingIcon: Icon(icon, size: 18),
    onPressed: f,
    child: _MenuLabel(label),
  );

  List<Widget> _items(List<Pool> all) {
    final p = widget.keyPrefix;
    final choices = [
      for (final a in all)
        if (a.id != widget.excludePoolId &&
            (!widget.editableOnly || a.role.canEdit))
          a,
    ];
    final mine = [
      for (final a in choices)
        if (!a.shared) a,
    ];
    final shared = [
      for (final a in choices)
        if (a.shared) a,
    ];
    var focused = false;
    FocusNode? first() {
      if (focused) return null;
      focused = true;
      return _firstItem;
    }

    final hasActions = widget.onNewPool != null;
    return [
      if (choices.isEmpty)
        MenuItemButton(
          key: ValueKey('$p-none'),
          style: _style,
          onPressed: null,
          child: Text(
            all.isEmpty
                ? 'No pools yet'
                : widget.editableOnly
                ? 'No other pools you can edit'
                : 'No other pools',
          ),
        ),
      if (mine.isNotEmpty) ...[
        PickerSectionHeader('My pools', key: ValueKey('$p-header-mine')),
        for (final a in mine) _poolItem(a, focus: first()),
      ],
      if (shared.isNotEmpty) ...[
        PickerSectionHeader(
          'Shared with me',
          key: ValueKey('$p-header-shared'),
        ),
        for (final a in shared) _poolItem(a, focus: first()),
      ],
      if (hasActions) const Divider(height: 9),
      if (widget.onNewPool != null)
        // MenuItemButton runs onPressed a frame later (after the menu
        // closes), outside the tap: prime the keyboard on the release so
        // the New pool dialog's Name field raises it on phones.
        Listener(
          behavior: HitTestBehavior.translucent,
          onPointerUp: (_) => primeSoftKeyboard(),
          child: _action(
            'new-pool',
            Icons.add_rounded,
            'New pool',
            widget.onNewPool!,
            focus: first(),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final pools = ref.watch(poolsProvider);
    final children = pools.when(
      skipLoadingOnReload: true,
      loading: () => <Widget>[
        MenuItemButton(
          style: _style,
          onPressed: null,
          child: const Text('Loading…'),
        ),
      ],
      error: (e, _) => <Widget>[
        MenuItemButton(
          style: _style,
          onPressed: null,
          child: const Text('Could not load pools'),
        ),
      ],
      data: _items,
    );
    return Semantics(
      label: widget.title,
      container: true,
      child: MenuAnchor(
        controller: _menu,
        style: _menuStyle(context),
        onOpen: () {
          HardwareKeyboard.instance.addHandler(_onKey);
          setState(() => _isOpen = true);
          _focusFirst();
        },
        onClose: () {
          HardwareKeyboard.instance.removeHandler(_onKey);
          if (mounted) setState(() => _isOpen = false);
        },
        menuChildren: children,
        // The trigger's tooltip would sit on top of the open menu.
        builder: (context, controller, _) => TooltipVisibility(
          visible: !_isOpen,
          child: widget.builder(context, _open),
        ),
      ),
    );
  }
}

/// A menu row's text: one line, ellipsised so the menu fits the screen
/// (room is left for the row's icons and the menu's margins).
class _MenuLabel extends StatelessWidget {
  const _MenuLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: (width - 140).clamp(80.0, 240.0).toDouble(),
      ),
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

/// Small muted, non-interactive label heading a picker level. Excluded from
/// focus traversal so keyboard navigation skips straight to the items.
class PickerSectionHeader extends StatelessWidget {
  const PickerSectionHeader(
    this.label, {
    super.key,
    this.padding = const EdgeInsets.fromLTRB(12, 8, 12, 4),
  });

  final String label;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExcludeFocus(
      child: Semantics(
        header: true,
        child: Padding(
          padding: padding,
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// People icon for pools shared with me (not owned), with my role.
Widget? sharedIndicator(Pool a) {
  if (a.role.isOwner) return null;
  return Tooltip(
    message: 'Shared with you · ${a.role.label.toLowerCase()}',
    child: Icon(
      Icons.people_alt_outlined,
      key: ValueKey('shared-indicator-${a.id}'),
      size: 16,
      color: AppTheme.textFaint,
    ),
  );
}
