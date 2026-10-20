import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/providers.dart';
import '../theme/app_theme.dart';

/// Reusable project > account picker: a dropdown anchored to the trigger.
///
/// Projects are listed at the top level, each opening a submenu of its
/// accounts (the current one checked). With a single project the accounts
/// are listed directly. On wide screens the submenus cascade to the side and
/// open on click or hover; on phones (< 600px) a tap expands the project's
/// accounts in place under its row (the current project starts expanded),
/// so nothing opens off a narrow screen or covers the other rows.
/// Arrow keys / Enter / Esc work as in any menu; an outside tap dismisses.
///
/// [builder] draws the trigger; call the `open` callback it receives.
class AccountPicker extends ConsumerStatefulWidget {
  const AccountPicker({
    super.key,
    required this.builder,
    required this.onSelected,
    this.excludeAccountId,
    this.currentAccountId,
    this.title = 'Choose an account',
    this.keyPrefix = 'picker',
  });

  final Widget Function(BuildContext context, VoidCallback open) builder;
  final ValueChanged<Account> onSelected;
  final String? excludeAccountId;
  final String? currentAccountId;

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

/// Below this width submenus open below their row instead of to the side.
const double _compactWidth = 600;

MenuStyle _menuStyle(BuildContext context, {AlignmentGeometry? alignment}) {
  final screen = MediaQuery.sizeOf(context);
  return MenuStyle(
    alignment: alignment,
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

  /// Phones: the project whose accounts are expanded in place.
  String? _expanded;

  /// Wide screens: each project submenu's first account (Right arrow
  /// moves focus there).
  final _submenuFirst = <String, FocusNode>{};
  FocusNode _submenuFirstFor(String projectId) => _submenuFirst.putIfAbsent(
    projectId,
    () => FocusNode(debugLabel: 'first account of $projectId'),
  );

  @override
  void dispose() {
    _firstItem.dispose();
    for (final n in _submenuFirst.values) {
      n.dispose();
    }
    super.dispose();
  }

  void _open() {
    if (_menu.isOpen) {
      _menu.close();
      return;
    }
    // Start with the current account's project expanded (phones).
    final current = widget.currentAccountId;
    _expanded = null;
    for (final (project, accounts)
        in ref.read(accountDirectoryProvider).value ??
            const <(Project, List<Account>)>[]) {
      if (accounts.any((a) => a.id == current)) _expanded = project.id;
    }
    setState(() {});
    _menu.open();
  }

  /// Keyboard users land on the first row (no highlight on touch).
  void _focusFirst() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && _menu.isOpen && _firstItem.context != null) {
      _firstItem.requestFocus();
    }
  });

  Widget _accountItem(Account a, {bool indent = false, FocusNode? focus}) =>
      MenuItemButton(
        key: ValueKey('${widget.keyPrefix}-account-${a.id}'),
        focusNode: focus,
        style: indent
            ? _itemStyle.copyWith(
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.only(left: 36, right: 12),
                ),
              )
            : _itemStyle,
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

  List<Widget> _accountItems(
    String projectId,
    List<Account> accounts, {
    bool header = true,
    bool indent = false,
    FocusNode? focusFirst,
  }) {
    final choices = _choices(accounts);
    return [
      if (header)
        PickerSectionHeader(
          'Accounts:',
          key: ValueKey('${widget.keyPrefix}-header-accounts-$projectId'),
        ),
      if (choices.isEmpty)
        MenuItemButton(
          style: indent
              ? _itemStyle.copyWith(
                  padding: const WidgetStatePropertyAll(
                    EdgeInsets.only(left: 36, right: 12),
                  ),
                )
              : _itemStyle,
          onPressed: null,
          child: const Text('No other accounts'),
        ),
      for (final (i, a) in choices.indexed)
        _accountItem(a, indent: indent, focus: i == 0 ? focusFirst : null),
    ];
  }

  /// Phones: a project row that expands its accounts in place, beneath it
  /// (a side-opening or overlapping submenu would cover the other rows on
  /// a narrow screen).
  List<Widget> _inlineProject(
    Project project,
    List<Account> accounts, {
    FocusNode? focus,
  }) {
    final open = _expanded == project.id;
    return [
      MenuItemButton(
        key: ValueKey('${widget.keyPrefix}-project-${project.id}'),
        focusNode: focus,
        style: _itemStyle,
        closeOnActivate: false,
        leadingIcon: Icon(
          project.shared ? Icons.folder_shared_outlined : Icons.folder_outlined,
          size: 18,
        ),
        trailingIcon: Icon(
          open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
          size: 18,
        ),
        onPressed: () => setState(() => _expanded = open ? null : project.id),
        child: _MenuLabel(project.name),
      ),
      if (open)
        ..._accountItems(project.id, accounts, header: false, indent: true),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final dir = ref.watch(accountDirectoryProvider);
    final p = widget.keyPrefix;
    final compact = MediaQuery.sizeOf(context).width < _compactWidth;
    final children = dir.when(
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
      data: (projects) => [
        // One project: no need for a level that holds nothing else.
        if (projects.length == 1)
          ..._accountItems(
            projects.single.$1.id,
            projects.single.$2,
            focusFirst: _firstItem,
          )
        else ...[
          PickerSectionHeader('Projects:', key: ValueKey('$p-header-projects')),
          for (final (i, (project, accounts)) in projects.indexed)
            if (compact)
              ..._inlineProject(
                project,
                accounts,
                focus: i == 0 ? _firstItem : null,
              )
            else
              _ProjectSubmenu(
                key: ValueKey('$p-submenu-${project.id}'),
                buttonKey: ValueKey('$p-project-${project.id}'),
                focusNode: i == 0 ? _firstItem : null,
                firstChildFocus: _submenuFirstFor(project.id),
                project: project,
                onOpening: _closeSiblings,
                menuChildren: _accountItems(
                  project.id,
                  accounts,
                  focusFirst: _submenuFirstFor(project.id),
                ),
              ),
        ],
      ],
    );
    return Semantics(
      label: widget.title,
      container: true,
      child: MenuAnchor(
        controller: _menu,
        style: _menuStyle(context),
        onOpen: _focusFirst,
        menuChildren: children,
        builder: (context, controller, _) => widget.builder(context, _open),
      ),
    );
  }

  /// Only one project's account list open at a time.
  final _submenus = <MenuController>{};
  void _closeSiblings(MenuController opening) {
    for (final c in _submenus) {
      if (c != opening && c.isOpen) c.close();
    }
    _submenus.add(opening);
  }

  List<Account> _choices(List<Account> accounts) =>
      accounts.where((a) => a.id != widget.excludeAccountId).toList();
}

/// Wide screens: a project row whose accounts open in a submenu to its
/// side (flipped left by the menu layout if there's no room). Unlike
/// [SubmenuButton], a
/// tap/click on a row that is already open keeps it open (no toggle), so a
/// mouse user's click after hovering never collapses the list, and a touch
/// tap always opens it. Right arrow / Enter / Space open it from the
/// keyboard.
class _ProjectSubmenu extends StatefulWidget {
  const _ProjectSubmenu({
    super.key,
    required this.buttonKey,
    required this.project,
    required this.menuChildren,
    required this.onOpening,
    required this.firstChildFocus,
    this.focusNode,
  });

  final Key buttonKey;
  final Project project;
  final List<Widget> menuChildren;
  final ValueChanged<MenuController> onOpening;
  final FocusNode? focusNode;
  final FocusNode firstChildFocus;

  @override
  State<_ProjectSubmenu> createState() => _ProjectSubmenuState();
}

class _ProjectSubmenuState extends State<_ProjectSubmenu> {
  final _controller = MenuController();

  void _open() {
    widget.onOpening(_controller);
    if (!_controller.isOpen) _controller.open();
  }

  /// Keyboard: open and move focus to the first account.
  void _openAndEnter() {
    _open();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.firstChildFocus.context != null) {
        widget.firstChildFocus.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: _controller,
      style: _menuStyle(context, alignment: AlignmentDirectional.topEnd),
      alignmentOffset: const Offset(0, -8),
      menuChildren: widget.menuChildren,
      builder: (context, controller, _) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowRight): _openAndEnter,
        },
        child: MenuItemButton(
          key: widget.buttonKey,
          focusNode: widget.focusNode,
          style: _itemStyle,
          closeOnActivate: false,
          leadingIcon: Icon(
            widget.project.shared
                ? Icons.folder_shared_outlined
                : Icons.folder_outlined,
            size: 18,
          ),
          trailingIcon: const Icon(Icons.chevron_right_rounded, size: 18),
          onHover: (hovering) {
            if (hovering) _open();
          },
          onPressed: _open,
          child: _MenuLabel(widget.project.name),
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
