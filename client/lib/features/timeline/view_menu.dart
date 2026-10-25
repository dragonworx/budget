import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import 'combined.dart';

/// The timeline's View (eye) menu: on phones Go to today / seed, and
/// "Combine with" (other streams as checkboxes; the
/// menu stays open so several can be ticked).
///
/// Keyboard: Enter / Space / ↓ on the trigger opens it with the first row
/// focused (ringed); arrows move, Enter / Space toggle, Esc closes. Opened
/// by touch or mouse the first row still takes focus but shows no ring.
class ViewMenu extends StatefulWidget {
  const ViewMenu({
    super.key,
    required this.compact,
    required this.streams,
    required this.combined,
    required this.onToday,
    required this.onSeed,
    required this.onGoToDate,
    required this.onToggleStream,
    required this.builder,
  });

  final bool compact;
  final List<CombinedStream> streams;
  final Set<String> combined;
  final VoidCallback onToday;
  final VoidCallback onSeed;

  /// "Go to date…": a date picker, then that day from the left edge.
  final VoidCallback onGoToDate;
  final ValueChanged<String> onToggleStream;

  /// The trigger; call `open` to toggle the menu.
  final Widget Function(BuildContext context, VoidCallback open) builder;

  @override
  State<ViewMenu> createState() => _ViewMenuState();
}

class _ViewMenuState extends State<ViewMenu> {
  final _menu = MenuController();
  final _first = FocusNode(debugLabel: 'view menu first item');
  bool _isOpen = false;
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
    _first.dispose();
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

  /// First row takes focus (re-asserted a few frames: on web the menu
  /// builds late and the trigger's tap can take focus back).
  void _focusFirst([
    int frame = 0,
  ]) => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted || !_menu.isOpen) return;
    final f = FocusManager.instance.primaryFocus;
    final inMenu =
        f == _first ||
        f?.context?.findAncestorWidgetOfExactType<MenuItemButton>() != null ||
        f?.context?.findAncestorWidgetOfExactType<CheckboxMenuButton>() != null;
    if (_first.context != null && !inMenu) _first.requestFocus();
    if (frame < 4) _focusFirst(frame + 1);
  });

  ButtonStyle get _style =>
      MenuItemButton.styleFrom(
        minimumSize: const Size(0, 44),
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

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.labelSmall;
    final screen = MediaQuery.sizeOf(context);
    final children = <Widget>[
      if (widget.compact) ...[
        MenuItemButton(
          key: const ValueKey('view-today'),
          focusNode: _first,
          style: _style,
          leadingIcon: const Icon(Icons.today_rounded, size: 18),
          onPressed: widget.onToday,
          child: const Text('Go to today'),
        ),
        MenuItemButton(
          key: const ValueKey('view-seed'),
          style: _style,
          leadingIcon: const Icon(
            Icons.flag_rounded,
            size: 18,
            color: AppTheme.violet,
          ),
          onPressed: widget.onSeed,
          child: const Text('Go to seed date'),
        ),
      ],
      MenuItemButton(
        key: const ValueKey('view-go-to-date'),
        focusNode: widget.compact ? null : _first,
        style: _style,
        leadingIcon: const Icon(Icons.event_rounded, size: 18),
        onPressed: widget.onGoToDate,
        child: const Text('Go to date…'),
      ),
      const Divider(height: 8),
      Padding(
        key: const ValueKey('combine-heading'),
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
        child: Text(
          'COMBINE WITH (SUM OF BALANCES)',
          style: small?.copyWith(
            letterSpacing: 1,
            fontWeight: FontWeight.w700,
            color: AppTheme.textFaint,
          ),
        ),
      ),
      if (widget.streams.isEmpty)
        MenuItemButton(
          style: _style,
          onPressed: null,
          child: const Text('No other streams'),
        ),
      // Keys on a wrapper: CheckboxMenuButton hands its key to its inner
      // MenuItemButton too.
      for (final p in widget.streams)
        KeyedSubtree(
          key: ValueKey('combine-${p.id}'),
          child: CheckboxMenuButton(
            style: _style,
            closeOnActivate: false,
            value: widget.combined.contains(p.id),
            onChanged: (_) => widget.onToggleStream(p.id),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: p.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: (screen.width - 150).clamp(80.0, 220.0),
                  ),
                  child: Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!p.canEdit) ...[
                  const SizedBox(width: 8),
                  Text(
                    'view only',
                    style: small?.copyWith(color: AppTheme.textFaint),
                  ),
                ],
              ],
            ),
          ),
        ),
    ];
    return MenuAnchor(
      controller: _menu,
      style: MenuStyle(
        maximumSize: WidgetStatePropertyAll(
          Size(
            (screen.width - 16).clamp(160.0, 360.0).toDouble(),
            (screen.height * 0.7).clamp(160.0, 560.0).toDouble(),
          ),
        ),
      ),
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
      builder: (context, controller, _) => TooltipVisibility(
        visible: !_isOpen,
        child: widget.builder(context, _open),
      ),
    );
  }
}
