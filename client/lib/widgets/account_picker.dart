import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/providers.dart';
import '../theme/app_theme.dart';

/// Reusable account picker: a dropdown anchored to the trigger, with a flat
/// list of my accounts (the current one checked), then a "Shared with me"
/// section, then optional actions (New account, Manage accounts). Accounts
/// are top level, so there are no submenus.
///
/// Rows are at least 48px tall and the menu is kept on screen (320px+).
/// Arrow keys / Enter / Esc work as in any menu (the first row is focused
/// on open); an outside tap dismisses.
///
/// [builder] draws the trigger; call the `open` callback it receives.
class AccountPicker extends ConsumerStatefulWidget {
  const AccountPicker({
    super.key,
    required this.builder,
    required this.onSelected,
    this.excludeAccountId,
    this.currentAccountId,
    this.editableOnly = false,
    this.onNewAccount,
    this.onManageAccounts,
    this.title = 'Choose an account',
    this.keyPrefix = 'picker',
  });

  final Widget Function(BuildContext context, VoidCallback open) builder;
  final ValueChanged<Account> onSelected;
  final String? excludeAccountId;
  final String? currentAccountId;

  /// Only accounts I can edit (transfer destinations).
  final bool editableOnly;

  /// Action rows at the bottom (omitted when null).
  final VoidCallback? onNewAccount;
  final VoidCallback? onManageAccounts;

  /// Accessible name of the menu.
  final String title;
  final String keyPrefix;

  @override
  ConsumerState<AccountPicker> createState() => _AccountPickerState();
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

class _AccountPickerState extends ConsumerState<AccountPicker> {
  final _menu = MenuController();
  final _firstItem = FocusNode(debugLabel: 'account picker first item');
  bool _isOpen = false;

  @override
  void dispose() {
    _firstItem.dispose();
    super.dispose();
  }

  void _open() {
    if (_menu.isOpen) {
      _menu.close();
      return;
    }
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

  Widget _accountItem(Account a, {FocusNode? focus}) => MenuItemButton(
    key: ValueKey('${widget.keyPrefix}-account-${a.id}'),
    focusNode: focus,
    style: _itemStyle,
    leadingIcon: Icon(
      a.id == widget.currentAccountId
          ? Icons.check_rounded
          : Icons.account_balance_wallet_outlined,
      size: 18,
      color: a.id == widget.currentAccountId ? AppTheme.accent : null,
    ),
    onPressed: () => widget.onSelected(a),
    trailingIcon: sharedIndicator(a),
    child: _MenuLabel(a.name),
  );

  Widget _action(String key, IconData icon, String label, VoidCallback f,
          {FocusNode? focus}) =>
      MenuItemButton(
        key: ValueKey('${widget.keyPrefix}-$key'),
        focusNode: focus,
        style: _itemStyle,
        leadingIcon: Icon(icon, size: 18),
        onPressed: f,
        child: _MenuLabel(label),
      );

  List<Widget> _items(List<Account> all) {
    final p = widget.keyPrefix;
    final choices = [
      for (final a in all)
        if (a.id != widget.excludeAccountId &&
            (!widget.editableOnly || a.role.canEdit))
          a,
    ];
    final mine = [for (final a in choices) if (!a.shared) a];
    final shared = [for (final a in choices) if (a.shared) a];
    var focused = false;
    FocusNode? first() {
      if (focused) return null;
      focused = true;
      return _firstItem;
    }

    final hasActions =
        widget.onNewAccount != null || widget.onManageAccounts != null;
    return [
      if (choices.isEmpty)
        MenuItemButton(
          key: ValueKey('$p-none'),
          style: _itemStyle,
          onPressed: null,
          child: Text(
            all.isEmpty
                ? 'No accounts yet'
                : widget.editableOnly
                ? 'No other accounts you can edit'
                : 'No other accounts',
          ),
        ),
      if (mine.isNotEmpty) ...[
        PickerSectionHeader('My accounts', key: ValueKey('$p-header-mine')),
        for (final a in mine) _accountItem(a, focus: first()),
      ],
      if (shared.isNotEmpty) ...[
        PickerSectionHeader(
          'Shared with me',
          key: ValueKey('$p-header-shared'),
        ),
        for (final a in shared) _accountItem(a, focus: first()),
      ],
      if (hasActions) const Divider(height: 9),
      if (widget.onNewAccount != null)
        _action(
          'new-account',
          Icons.add_rounded,
          'New account',
          widget.onNewAccount!,
          focus: first(),
        ),
      if (widget.onManageAccounts != null)
        _action(
          'manage-accounts',
          Icons.view_list_rounded,
          'Manage accounts',
          widget.onManageAccounts!,
          focus: first(),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(accountsProvider);
    final children = accounts.when(
      skipLoadingOnReload: true,
      loading: () => <Widget>[
        MenuItemButton(
          style: _itemStyle,
          onPressed: null,
          child: const Text('Loading…'),
        ),
      ],
      error: (e, _) => <Widget>[
        MenuItemButton(
          style: _itemStyle,
          onPressed: null,
          child: const Text('Could not load accounts'),
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
          setState(() => _isOpen = true);
          _focusFirst();
        },
        onClose: () {
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

/// People icon for accounts shared with me (not owned), with my role.
Widget? sharedIndicator(Account a) {
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
