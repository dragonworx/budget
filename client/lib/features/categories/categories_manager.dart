import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/confirm_dialog.dart';
import '../events/editor_outcome.dart' show undoTipDuration;
import '../timeline/stack_lanes.dart';

/// Random generator for a new category's default colour (tests set it).
math.Random? categoryColorRandom;

/// A new category's default colour: a random palette colour none of
/// [existing] wears yet, or (all taken) a random one of the least used.
String pickCategoryColor(Iterable<Category> existing, [math.Random? random]) {
  final uses = List<int>.filled(laneColors.length, 0);
  for (final c in existing) {
    final col = colorFromHex(c.color);
    final i = col == null ? null : laneColorIndexOf(col);
    if (i != null) uses[i]++;
  }
  final least = uses.reduce(math.min);
  final pool = [
    for (var i = 0; i < uses.length; i++)
      if (uses[i] == least) i,
  ];
  final r = random ?? categoryColorRandom ?? math.Random();
  return colorToHex(laneColors[pool[r.nextInt(pool.length)]]);
}

/// [base] if no category of [existing] has that name, else "[base] 2",
/// "[base] 3", … (a plan's default name, free to save as is).
String freeCategoryName(String base, Iterable<Category> existing) {
  final taken = {for (final c in existing) c.name.toLowerCase()};
  final b = normalizeCategoryName(base);
  if (!taken.contains(b.toLowerCase())) return b;
  for (var i = 2; ; i++) {
    final n = '$b $i';
    if (!taken.contains(n.toLowerCase())) return n;
  }
}

/// Live number of events per category of [streamId] (from the loaded
/// events; the listed counts until they load).
Map<String, int> categoryEventCounts(WidgetRef ref, String streamId) {
  final events = ref.watch(eventsProvider(streamId)).valueOrNull;
  if (events == null) {
    return {
      for (final c
          in ref.watch(categoriesProvider(streamId)).valueOrNull ??
              const <Category>[])
        c.id: c.eventCount,
    };
  }
  final counts = <String, int>{};
  for (final e in events) {
    final id = e.categoryId;
    if (id != null) counts[id] = (counts[id] ?? 0) + 1;
  }
  return counts;
}

/// Opens the category manager of [streamId] (a dialog on every screen
/// size). Resolves to the id of the last category created in it, if any.
Future<String?> showCategoriesManager(
  BuildContext context, {
  required String streamId,
  required bool canEdit,
}) {
  final width = MediaQuery.sizeOf(context).width;
  return showDialog<String>(
    context: context,
    builder: (_) => Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: width < 600 ? 10 : 40,
        vertical: 24,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: CategoriesManager(streamId: streamId, canEdit: canEdit),
      ),
    ),
  );
}

/// The category manager: the stream's categories as wrapped pills, each
/// with a ⋮ menu (Edit, Delete, Delete N Events), and a last, dashed
/// "+ New category" pill that turns into a name field with a colour.
/// Viewers see the pills only.
class CategoriesManager extends ConsumerStatefulWidget {
  const CategoriesManager({
    super.key,
    required this.streamId,
    required this.canEdit,
  });

  final String streamId;
  final bool canEdit;

  @override
  ConsumerState<CategoriesManager> createState() => _CategoriesManagerState();
}

class _CategoriesManagerState extends ConsumerState<CategoriesManager> {
  bool _creating = false;
  bool _busy = false;
  final _newName = TextEditingController();
  final _newFocus = FocusNode(debugLabel: 'new category name');
  String _newColor = '#3D6FD8';
  String? _newError;
  String? _lastCreated;
  String? _error;

  /// The undo strip after "Delete N Events" (text, batch to undo).
  ({String text, String batchId})? _undo;
  Timer? _undoTimer;

  CategoriesNotifier get _notifier =>
      ref.read(categoriesProvider(widget.streamId).notifier);

  @override
  void dispose() {
    _newName.dispose();
    _newFocus.dispose();
    _undoTimer?.cancel();
    super.dispose();
  }

  void _startCreate(List<Category> list) {
    setState(() {
      _creating = true;
      _newName.clear();
      _newError = null;
      _newColor = pickCategoryColor(list);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _newFocus.requestFocus();
    });
  }

  Future<void> _create(List<Category> list) async {
    if (_busy) return;
    final problem = categoryNameProblem(_newName.text, list);
    if (problem != null) {
      setState(() => _newError = problem);
      _newFocus.requestFocus();
      return;
    }
    setState(() => _busy = true);
    try {
      final c = await _notifier.create(
        normalizeCategoryName(_newName.text),
        color: _newColor,
      );
      if (!mounted) return;
      setState(() {
        _lastCreated = c.id;
        _creating = false;
        _newError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _newError = e is ApiException && e.statusCode == 409
            ? 'That name is taken'
            : friendlyError(e),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(Category c, List<Category> list) async {
    final r = await showDialog<({String name, String color})>(
      context: context,
      builder: (_) => _EditCategoryDialog(category: c, all: list),
    );
    if (r == null || !mounted) return;
    await _run(
      () => _notifier.edit(
        c.id,
        name: r.name == c.name ? null : r.name,
        color: r.color == c.color ? null : r.color,
      ),
    );
  }

  Future<int> _counterparts(Category c) async {
    try {
      final p = await ref
          .read(categoryRepositoryProvider)
          .deletePreview(widget.streamId, c.id);
      return p.counterparts;
    } catch (_) {
      return 0;
    }
  }

  static String _events(int n) => n == 1 ? '1 event' : '$n events';

  Future<void> _delete(Category c, int n) async {
    final others = n == 0 ? 0 : await _counterparts(c);
    if (!mounted) return;
    final ok = await showConfirmDialog(
      context,
      title: 'Delete category "${c.name}"?',
      message: n == 0
          ? 'It has no events. Only the category is deleted.'
          : 'This deletes "${c.name}" and all ${_events(n)} in it'
                '${others > 0 ? ', plus ${others == 1 ? 'the transfer\'s other side' : '$others transfer counterparts'} in other streams' : ''}. '
                'This can\'t be undone.',
      confirmLabel: n == 0 ? 'Delete category' : 'Delete category and events',
    );
    if (!ok || !mounted) return;
    await _run(() async {
      await _notifier.delete(c.id);
      final last = lastCategoryProvider(widget.streamId);
      if (ref.read(last) == c.id) ref.read(last.notifier).state = null;
    });
  }

  Future<void> _deleteEvents(Category c, int n) async {
    final others = await _counterparts(c);
    if (!mounted) return;
    final ok = await showConfirmDialog(
      context,
      title: 'Delete ${_events(n)}?',
      message:
          'All ${_events(n)} in "${c.name}" are deleted'
          '${others > 0 ? ', plus ${others == 1 ? 'the transfer\'s other side' : '$others transfer counterparts'} in other streams' : ''}. '
          'The category stays.',
      confirmLabel: 'Delete ${_events(n)}',
    );
    if (!ok || !mounted) return;
    await _run(() async {
      final batch = await _notifier.deleteEvents(c.id);
      if (batch == null || !mounted) return;
      _undoTimer?.cancel();
      setState(
        () => _undo = (
          text: 'Deleted ${_events(n)} of "${c.name}"',
          batchId: batch,
        ),
      );
      _undoTimer = Timer(undoTipDuration * 2, () {
        if (mounted) setState(() => _undo = null);
      });
    });
  }

  Future<void> _runUndo() async {
    final u = _undo;
    if (u == null) return;
    _undoTimer?.cancel();
    setState(() => _undo = null);
    await _run(() => _notifier.undoDeleteEvents(u.batchId));
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final async = ref.watch(categoriesProvider(widget.streamId));
    final counts = categoryEventCounts(ref, widget.streamId);
    final list = async.valueOrNull ?? const <Category>[];
    return Padding(
      key: const ValueKey('categories-manager'),
      padding: const EdgeInsets.fromLTRB(20, 14, 10, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.sell_outlined, size: 20, color: AppTheme.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Categories', style: theme.textTheme.titleLarge),
              ),
              IconButton(
                key: const ValueKey('categories-close'),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(_lastCreated),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10, bottom: 14),
            child: Text(
              widget.canEdit
                  ? 'Every event has one category: its name and colour show '
                        'on the timeline and in the list. Use ⋮ to edit or '
                        'delete one.'
                  : 'View only: you have viewer access to this stream.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppTheme.textMuted,
              ),
            ),
          ),
          if (async.isLoading && async.valueOrNull == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (async.hasError && async.valueOrNull == null)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Couldn\'t load categories: ${friendlyError(async.error!)}',
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        ref.invalidate(categoriesProvider(widget.streamId)),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          else
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(right: 10, bottom: 4),
                child: Wrap(
                  key: const ValueKey('category-pills'),
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final c in list)
                      CategoryPill(
                        key: ValueKey('category-pill-${c.id}'),
                        category: c,
                        count: counts[c.id] ?? 0,
                        menu: widget.canEdit
                            ? _menu(c, counts[c.id] ?? 0, list)
                            : null,
                      ),
                    if (widget.canEdit) _newPill(list),
                  ],
                ),
              ),
            ),
          if (_newError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 10),
              child: Text(
                _newError!,
                key: const ValueKey('category-new-error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 10),
              child: Text(
                _error!,
                key: const ValueKey('categories-error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (_undo != null)
            Padding(
              padding: const EdgeInsets.only(top: 12, right: 10),
              child: Container(
                key: const ValueKey('category-undo'),
                padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
                decoration: BoxDecoration(
                  color: AppTheme.overlay,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.borderStrong),
                ),
                child: Row(
                  children: [
                    Expanded(child: Text(_undo!.text)),
                    TextButton(
                      key: const ValueKey('category-undo-button'),
                      onPressed: _busy ? null : _runUndo,
                      child: const Text('Undo'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _menu(Category c, int n, List<Category> list) {
    final touch =
        Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          key: ValueKey('category-edit-${c.id}'),
          leadingIcon: const Icon(Icons.edit_outlined, size: 18),
          onPressed: _busy ? null : () => _edit(c, list),
          child: const Text('Edit'),
        ),
        MenuItemButton(
          key: ValueKey('category-delete-${c.id}'),
          leadingIcon: const Icon(Icons.delete_outline_rounded, size: 18),
          onPressed: _busy ? null : () => _delete(c, n),
          child: const Text('Delete'),
        ),
        MenuItemButton(
          key: ValueKey('category-delete-events-${c.id}'),
          leadingIcon: const Icon(Icons.layers_clear_outlined, size: 18),
          // Nothing to delete: shown, disabled.
          onPressed: _busy || n == 0 ? null : () => _deleteEvents(c, n),
          child: Text('Delete $n ${n == 1 ? 'Event' : 'Events'}'),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        key: ValueKey('category-menu-${c.id}'),
        tooltip: 'Options for ${c.name}',
        visualDensity: VisualDensity.compact,
        constraints: BoxConstraints.tightFor(
          width: touch ? 40 : 32,
          height: touch ? 40 : 32,
        ),
        padding: EdgeInsets.zero,
        iconSize: 18,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.more_vert_rounded),
      ),
    );
  }

  Widget _newPill(List<Category> list) {
    if (!_creating) {
      return CustomPaint(
        key: const ValueKey('category-new'),
        painter: _DashedPillPainter(color: AppTheme.textFaint),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: _busy ? null : () => _startCreate(list),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 18, color: AppTheme.textMuted),
                  SizedBox(width: 6),
                  Text(
                    'New category',
                    style: TextStyle(
                      color: AppTheme.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final color = colorFromHex(_newColor) ?? laneColor(0);
    return CustomPaint(
      key: const ValueKey('category-new-editing'),
      painter: _DashedPillPainter(color: color),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 2, 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ColorDotMenu(
              key: const ValueKey('category-new-color'),
              color: _newColor,
              onPicked: (c) => setState(() => _newColor = c),
            ),
            SizedBox(
              width: 170,
              child: TextField(
                key: const ValueKey('category-new-name'),
                controller: _newName,
                focusNode: _newFocus,
                maxLength: maxCategoryNameLength,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  hintText: 'Category name',
                  isDense: true,
                  counterText: '',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: EdgeInsets.symmetric(vertical: 10),
                ),
                // Checked as you type: a taken name shows before Create.
                onChanged: (v) => setState(
                  () => _newError = v.trim().isEmpty
                      ? null
                      : categoryNameProblem(v, list),
                ),
                onSubmitted: (_) => _create(list),
              ),
            ),
            IconButton(
              key: const ValueKey('category-new-save'),
              tooltip: 'Create',
              visualDensity: VisualDensity.compact,
              onPressed: _busy || _newError != null
                  ? null
                  : () => _create(list),
              icon: const Icon(Icons.check_rounded, color: AppTheme.accent),
            ),
            IconButton(
              key: const ValueKey('category-new-cancel'),
              tooltip: 'Cancel',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() {
                _creating = false;
                _newError = null;
              }),
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

/// One category as a pill: colour dot, name, event count, and [menu] (the
/// ⋮ button) when editable. Hidden categories are dimmed with an eye-off.
class CategoryPill extends StatelessWidget {
  const CategoryPill({
    super.key,
    required this.category,
    required this.count,
    this.menu,
  });

  final Category category;
  final int count;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final color = colorFromHex(category.color) ?? laneColor(0);
    final hidden = category.hidden;
    return Semantics(
      container: true,
      label:
          '${category.name}, ${count == 1 ? '1 event' : '$count events'}'
          '${hidden ? ', hidden' : ''}',
      child: Opacity(
        opacity: hidden ? 0.6 : 1,
        child: Container(
          padding: EdgeInsets.fromLTRB(12, 0, menu == null ? 12 : 2, 0),
          constraints: const BoxConstraints(minHeight: 40),
          decoration: ShapeDecoration(
            color: color.withValues(alpha: 0.16),
            shape: StadiumBorder(
              side: BorderSide(color: color.withValues(alpha: 0.7)),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: ExcludeSemantics(
                  child: Text(
                    category.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              ExcludeSemantics(
                child: Text(
                  '$count',
                  key: ValueKey('category-count-${category.id}'),
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 12,
                  ),
                ),
              ),
              if (hidden) ...[
                const SizedBox(width: 4),
                const Icon(
                  Icons.visibility_off_outlined,
                  size: 14,
                  color: AppTheme.textMuted,
                ),
              ],
              if (menu != null) menu! else const SizedBox(width: 2),
            ],
          ),
        ),
      ),
    );
  }
}

/// A colour dot that opens the palette.
class _ColorDotMenu extends StatelessWidget {
  const _ColorDotMenu({super.key, required this.color, required this.onPicked});

  final String color;
  final ValueChanged<String> onPicked;

  @override
  Widget build(BuildContext context) {
    final c = colorFromHex(color) ?? laneColor(0);
    final i = laneColorIndexOf(c);
    return MenuAnchor(
      style: const MenuStyle(
        padding: WidgetStatePropertyAll(EdgeInsets.all(8)),
      ),
      menuChildren: [
        SizedBox(
          width: 6 * 44,
          child: Builder(
            builder: (menuContext) => PaletteSwatches(
              selected: color,
              onPicked: (v) {
                onPicked(v);
                MenuController.maybeOf(menuContext)?.close();
              },
            ),
          ),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: 'Colour: ${i == null ? 'Custom' : laneColorNames[i]} (change)',
        visualDensity: VisualDensity.compact,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            border: Border.all(color: laneTextColor, width: 2),
          ),
        ),
      ),
    );
  }
}

/// The 12 palette colours as tappable swatches ([selected] ticked).
class PaletteSwatches extends StatelessWidget {
  const PaletteSwatches({
    super.key,
    required this.selected,
    required this.onPicked,
  });

  final String selected;
  final ValueChanged<String> onPicked;

  @override
  Widget build(BuildContext context) {
    final sel = colorFromHex(selected);
    final si = sel == null ? null : laneColorIndexOf(sel);
    return Wrap(
      children: [
        for (var i = 0; i < laneColors.length; i++)
          Semantics(
            selected: si == i,
            button: true,
            label: '${laneColorNames[i]}${si == i ? ', selected' : ''}',
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: InkResponse(
                key: ValueKey('category-swatch-$i'),
                radius: 22,
                onTap: () => onPicked(colorToHex(laneColors[i])),
                child: Tooltip(
                  message: laneColorNames[i],
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: laneColors[i],
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: si == i ? laneTextColor : Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                    child: si == i
                        ? const Icon(
                            Icons.check_rounded,
                            size: 20,
                            color: laneTextColor,
                          )
                        : null,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Edit: rename (unique) and recolour.
class _EditCategoryDialog extends StatefulWidget {
  const _EditCategoryDialog({required this.category, required this.all});

  final Category category;
  final List<Category> all;

  @override
  State<_EditCategoryDialog> createState() => _EditCategoryDialogState();
}

class _EditCategoryDialogState extends State<_EditCategoryDialog> {
  late final _name = TextEditingController(text: widget.category.name);
  late String _color = widget.category.color;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final problem = categoryNameProblem(
      _name.text,
      widget.all,
      except: widget.category.id,
    );
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context)
        .pop((name: normalizeCategoryName(_name.text), color: _color));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('category-edit-dialog'),
      title: const Text('Edit category'),
      content: SizedBox(
        width: 6 * 44,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('category-edit-name'),
              controller: _name,
              autofocus: true,
              maxLength: maxCategoryNameLength,
              decoration: InputDecoration(
                labelText: 'Name',
                errorText: _error,
                counterText: '',
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 16),
            const Text(
              'Colour',
              style: TextStyle(
                color: AppTheme.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            PaletteSwatches(
              selected: _color,
              onPicked: (c) => setState(() => _color = c),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('category-edit-save'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// The dashed stadium outline of the "+ New category" pill.
class _DashedPillPainter extends CustomPainter {
  _DashedPillPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.height / 2;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.75),
          Radius.circular(r),
        ),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, math.min(d + 6, m.length)), paint);
        d += 10;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedPillPainter old) => old.color != color;
}

/// The editor's category picker: read-only pills (pick one; categories
/// are made and changed in the manager), and a link to the manager.
class CategoryPicker extends ConsumerWidget {
  const CategoryPicker({
    super.key,
    required this.streamId,
    required this.selectedId,
    required this.onSelected,
    required this.onManage,
    this.enabled = true,
    this.errorText,
  });

  final String streamId;
  final String? selectedId;
  final ValueChanged<Category> onSelected;
  final VoidCallback onManage;
  final bool enabled;
  final String? errorText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(categoriesProvider(streamId));
    final list = async.valueOrNull ?? const <Category>[];
    final label = theme.textTheme.labelMedium?.copyWith(
      color: AppTheme.textMuted,
    );
    return Column(
      key: const ValueKey('editor-category'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('Category', style: label)),
            if (enabled && list.isNotEmpty)
              TextButton.icon(
                key: const ValueKey('editor-manage-categories'),
                onPressed: onManage,
                icon: const Icon(Icons.tune_rounded, size: 16),
                label: const Text('Manage'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        if (async.isLoading && async.valueOrNull == null)
          const Padding(
            padding: EdgeInsets.all(8),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (list.isEmpty)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'No categories yet.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textMuted,
                ),
              ),
              if (enabled)
                TextButton(
                  key: const ValueKey('editor-create-category'),
                  onPressed: onManage,
                  child: const Text('Create a category'),
                ),
            ],
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 168),
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final c in list) _pickPill(c, c.id == selectedId),
                ],
              ),
            ),
          ),
        if (errorText != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              errorText!,
              key: const ValueKey('editor-category-error'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }

  Widget _pickPill(Category c, bool selected) {
    final color = colorFromHex(c.color) ?? laneColor(0);
    return Semantics(
      key: ValueKey('editor-category-${c.id}'),
      container: true,
      button: true,
      selected: selected,
      label: c.name,
      excludeSemantics: true,
      child: Material(
        color: selected ? color : color.withValues(alpha: 0.12),
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? laneTextColor : color.withValues(alpha: 0.6),
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: enabled ? () => onSelected(c) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected)
                  const Icon(
                    Icons.check_rounded,
                    size: 16,
                    color: laneTextColor,
                  )
                else
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: selected ? laneTextColor : AppTheme.text,
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
}
