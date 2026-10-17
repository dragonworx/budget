import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/providers.dart';
import '../theme/app_theme.dart';

/// Reusable project > account picker.
///
/// Wide screens: a cascading menu (projects, each opening a submenu of its
/// accounts). Phones (< 600px): a bottom sheet that drills down from the
/// project list to that project's accounts, since side-opening submenus
/// don't fit a portrait screen.
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
  final String title;
  final String keyPrefix;

  @override
  ConsumerState<AccountPicker> createState() => _AccountPickerState();
}

class _AccountPickerState extends ConsumerState<AccountPicker> {
  final _menu = MenuController();

  void _open() {
    final compact = MediaQuery.sizeOf(context).width < 600;
    if (compact) {
      _openSheet();
    } else {
      _menu.isOpen ? _menu.close() : _menu.open();
    }
  }

  Future<void> _openSheet() async {
    final picked = await showModalBottomSheet<Account>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _DrillDownSheet(
        title: widget.title,
        excludeAccountId: widget.excludeAccountId,
        currentAccountId: widget.currentAccountId,
        keyPrefix: widget.keyPrefix,
      ),
    );
    if (picked != null) widget.onSelected(picked);
  }

  @override
  Widget build(BuildContext context) {
    final dir = ref.watch(accountDirectoryProvider);
    final p = widget.keyPrefix;
    final children = dir.when(
      skipLoadingOnReload: true,
      loading: () => const <Widget>[
        MenuItemButton(onPressed: null, child: Text('Loading…')),
      ],
      error: (e, _) => const <Widget>[
        MenuItemButton(onPressed: null, child: Text('Could not load accounts')),
      ],
      data: (projects) => [
        PickerSectionHeader('Projects:', key: ValueKey('$p-header-projects')),
        for (final (project, accounts) in projects)
          _ProjectSubmenu(
            key: ValueKey('$p-submenu-${project.id}'),
            buttonKey: ValueKey('$p-project-${project.id}'),
            project: project,
            onOpening: _closeSiblings,
            menuChildren: [
              PickerSectionHeader(
                'Accounts:',
                key: ValueKey('$p-header-accounts-${project.id}'),
              ),
              if (_choices(accounts).isEmpty)
                const MenuItemButton(
                  onPressed: null,
                  child: Text('No other accounts'),
                ),
              for (final a in _choices(accounts))
                MenuItemButton(
                  key: ValueKey('$p-account-${a.id}'),
                  leadingIcon: Icon(
                    a.id == widget.currentAccountId
                        ? Icons.check_rounded
                        : Icons.account_balance_wallet_outlined,
                    size: 18,
                  ),
                  onPressed: () => widget.onSelected(a),
                  child: Text(a.name),
                ),
            ],
          ),
      ],
    );
    return MenuAnchor(
      controller: _menu,
      menuChildren: children,
      builder: (context, controller, _) => widget.builder(context, _open),
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

class _DrillDownSheet extends ConsumerStatefulWidget {
  const _DrillDownSheet({
    required this.title,
    required this.keyPrefix,
    this.excludeAccountId,
    this.currentAccountId,
  });

  final String title;
  final String keyPrefix;
  final String? excludeAccountId;
  final String? currentAccountId;

  @override
  ConsumerState<_DrillDownSheet> createState() => _DrillDownSheetState();
}

class _DrillDownSheetState extends ConsumerState<_DrillDownSheet> {
  Project? _project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dir = ref.watch(accountDirectoryProvider);
    final p = widget.keyPrefix;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 16, 8),
              child: Row(
                children: [
                  if (_project != null)
                    IconButton(
                      key: ValueKey('$p-sheet-back'),
                      tooltip: 'Projects',
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: () => setState(() => _project = null),
                    )
                  else
                    const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _project?.name ?? widget.title,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: dir.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Could not load accounts'),
                ),
                data: (projects) {
                  final project = _project;
                  if (project == null) {
                    return ListView(
                      shrinkWrap: true,
                      children: [
                        PickerSectionHeader(
                          'Projects:',
                          key: ValueKey('$p-header-projects'),
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                        ),
                        for (final (pr, accounts) in projects)
                          ListTile(
                            key: ValueKey('$p-project-${pr.id}'),
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(pr.name),
                            subtitle: Text(
                              '${accounts.length} account${accounts.length == 1 ? '' : 's'}',
                            ),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => setState(() => _project = pr),
                          ),
                      ],
                    );
                  }
                  final accounts = [
                    for (final (pr, list) in projects)
                      if (pr.id == project.id)
                        for (final a in list)
                          if (a.id != widget.excludeAccountId) a,
                  ];
                  final header = PickerSectionHeader(
                    'Accounts:',
                    key: ValueKey('$p-header-accounts-${project.id}'),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  );
                  if (accounts.isEmpty) {
                    return ListView(
                      shrinkWrap: true,
                      children: [
                        header,
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('No other accounts in this project'),
                        ),
                      ],
                    );
                  }
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      header,
                      for (final a in accounts)
                        ListTile(
                          key: ValueKey('$p-account-${a.id}'),
                          leading: Icon(
                            a.id == widget.currentAccountId
                                ? Icons.check_rounded
                                : Icons.account_balance_wallet_outlined,
                            color: a.id == widget.currentAccountId
                                ? AppTheme.accent
                                : null,
                          ),
                          title: Text(a.name),
                          subtitle: Text(a.currency),
                          onTap: () => Navigator.of(context).pop(a),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A project row whose accounts open to its side. Unlike [SubmenuButton],
/// clicking a row that hover already opened keeps it open (no toggle), so a
/// mouse user's click never collapses the list they are reaching for.
class _ProjectSubmenu extends StatefulWidget {
  const _ProjectSubmenu({
    super.key,
    required this.buttonKey,
    required this.project,
    required this.menuChildren,
    required this.onOpening,
  });

  final Key buttonKey;
  final Project project;
  final List<Widget> menuChildren;
  final ValueChanged<MenuController> onOpening;

  @override
  State<_ProjectSubmenu> createState() => _ProjectSubmenuState();
}

class _ProjectSubmenuState extends State<_ProjectSubmenu> {
  final _controller = MenuController();

  void _open() {
    widget.onOpening(_controller);
    if (!_controller.isOpen) _controller.open();
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: _controller,
      style: const MenuStyle(alignment: AlignmentDirectional.topEnd),
      alignmentOffset: const Offset(0, -8),
      menuChildren: widget.menuChildren,
      builder: (context, controller, _) => MenuItemButton(
        key: widget.buttonKey,
        closeOnActivate: false,
        leadingIcon: const Icon(Icons.folder_outlined, size: 18),
        trailingIcon: const Icon(Icons.chevron_right_rounded, size: 18),
        onHover: (hovering) {
          if (hovering) _open();
        },
        onPressed: _open,
        child: Text(widget.project.name),
      ),
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
