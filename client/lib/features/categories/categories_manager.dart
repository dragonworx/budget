import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_client.dart';
import '../../data/category_tree.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/category_dropdown.dart';
import '../../widgets/confirm_dialog.dart';
import '../events/editor_outcome.dart' show undoTipDuration;
import '../timeline/stack_lanes.dart';
import '../../widgets/app_menu_anchor.dart';

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

/// Live number of events per category of [streamId]'s owner, across all
/// that owner's streams (the listed counts; the list refetches whenever
/// events change).
Map<String, int> categoryEventCounts(WidgetRef ref, String streamId) => {
  for (final c
      in ref.watch(categoriesProvider(streamId)).valueOrNull ??
          const <Category>[])
    c.id: c.eventCount,
};

/// Opens the category manager of [streamId]'s owner (a dialog on every
/// screen size). [canEdit]: may add categories (editors and the owner);
/// renaming, recolouring and deleting reach every stream of the owner, so
/// only the owner gets those. Resolves to the id of the last category
/// created in it, if any.
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
        horizontal: width < 600 ? 8 : 40,
        vertical: 24,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: CategoriesManager(streamId: streamId, canEdit: canEdit),
      ),
    ),
  );
}

/// The category manager: a table of the owner's categories (shared by all
/// their streams). Columns: colour (tap to change), name (tap to rename in
/// place), event count (all streams), and two icon buttons: delete the
/// events (keeping the category; undoable) and delete the category with
/// its events. A dashed "new category" row is pinned below the rows (only
/// the rows scroll). Viewers see the table read-only; editors may only add.
class CategoriesManager extends ConsumerStatefulWidget {
  const CategoriesManager({
    super.key,
    required this.streamId,
    required this.canEdit,
  });

  final String streamId;

  /// May add (editor or owner). Managing also needs ownership.
  final bool canEdit;

  @override
  ConsumerState<CategoriesManager> createState() => _CategoriesManagerState();
}

class _CategoriesManagerState extends ConsumerState<CategoriesManager> {
  bool _busy = false;
  final _newName = TextEditingController();
  final _newFocus = FocusNode(debugLabel: 'new category name');
  String? _newColor;
  String? _newError;
  String? _lastCreated;
  String? _error;

  /// Expanded parents in the tree (all start open).
  final Set<String> _expanded = {};
  bool _expandedReady = false;

  /// Parent for the dashed "new category" row (null = top-level).
  String? _newParentId;

  /// The row whose name is being edited in place.
  String? _editingId;
  final _editName = TextEditingController();
  late final _editFocus = FocusNode(debugLabel: 'category name')
    ..addListener(_editFocusChanged);
  String? _editError;

  /// The undo strip after "Delete N events" (text, batch to undo).
  ({String text, String batchId})? _undo;
  Timer? _undoTimer;

  CategoriesNotifier get _notifier =>
      ref.read(categoriesProvider(widget.streamId).notifier);

  /// One key per row (by category id).
  final Map<String, GlobalKey> _rowKeys = {};
  final _scroll = ScrollController();
  final _listAreaKey = GlobalKey();

  /// Immediate handle-drag (touch and mouse).
  String? _draggingId;
  Offset? _pointerPos;
  _DropCue? _dropCue;
  Timer? _autoScroll;
  OverlayEntry? _feedback;
  int? _dragPointer;

  /// After a rename re-sorts the table: brings [id]'s row into view.
  void _revealRow(String id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _rowKeys[id]?.currentContext;
      if (!mounted || ctx == null) return;
      // Below the view: to its bottom edge; above: to its top edge.
      for (final policy in const [
        ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      ]) {
        Scrollable.ensureVisible(ctx, alignmentPolicy: policy);
      }
    });
  }

  List<Category> get _list =>
      ref.read(categoriesProvider(widget.streamId)).valueOrNull ??
      const <Category>[];

  /// Expanded-aware flatten, same order as the table.
  List<Category> get _visible {
    final raw = _list;
    return [
      for (final c in flattenedTree(raw))
        if (c.parentId == null || _expanded.contains(c.parentId)) c,
    ];
  }

  /// Rename, recolour, delete: the owner only (they reach every stream).
  bool get _canManage {
    if (!widget.canEdit) return false;
    final role = ref.watch(streamProvider(widget.streamId)).valueOrNull?.role;
    return role?.isOwner ?? true;
  }

  bool get _touch {
    final p = Theme.of(context).platform;
    return p == TargetPlatform.android || p == TargetPlatform.iOS;
  }

  @override
  void dispose() {
    _clearDrag(notify: false);
    _newName.dispose();
    _newFocus.dispose();
    _editName.dispose();
    _editFocus.dispose();
    _undoTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  // ---- in-place rename ----

  void _toggleExpanded(Category c) {
    setState(() {
      if (!_expanded.add(c.id)) _expanded.remove(c.id);
    });
  }

  void _startEdit(Category c) {
    if (_busy) return;
    setState(() {
      _editingId = c.id;
      _editName.text = c.name;
      _editName.selection = TextSelection(
        baseOffset: 0,
        extentOffset: c.name.length,
      );
      _editError = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editFocus.requestFocus();
    });
  }

  /// When the last in-place edit was cancelled (an Escape that the web
  /// engine also reports as a dismiss must not close the dialog too).
  DateTime? _cancelledAt;

  void _cancelEdit() {
    _cancelledAt = DateTime.now();
    setState(() {
      _editingId = null;
      _editError = null;
    });
  }

  /// Escape: cancels an in-place edit, else closes (with the last created
  /// category).
  void _dismiss() {
    if (_editingId != null) return _cancelEdit();
    final t = _cancelledAt;
    if (t != null &&
        DateTime.now().difference(t) < const Duration(milliseconds: 400)) {
      return;
    }
    Navigator.of(context).pop(_lastCreated);
  }

  /// Blur commits (when valid; an invalid name stays open with its error).
  void _editFocusChanged() {
    if (!_editFocus.hasFocus && _editingId != null) _commitEdit();
  }

  Future<void> _commitEdit() async {
    final id = _editingId;
    if (id == null || _busy) return;
    final c = _list.where((x) => x.id == id).firstOrNull;
    if (c == null) return _cancelEdit();
    final name = normalizeCategoryName(_editName.text);
    if (name == c.name) return _cancelEdit();
    final problem = categoryNameProblem(name, _list, except: id);
    if (problem != null) {
      setState(() => _editError = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _notifier.edit(id, name: name);
      if (mounted) {
        setState(() => _editingId = null);
        _revealRow(id);
      }
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _editError = e is ApiException && e.statusCode == 409
            ? 'That name is taken'
            : friendlyError(e),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- the new row ----

  String? _newProblem(String v) =>
      v.trim().isEmpty ? null : categoryNameProblem(v, _list);

  bool get _newValid =>
      _newName.text.trim().isNotEmpty && _newProblem(_newName.text) == null;

  Future<void> _explain(String title, String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _create() async {
    if (_busy) return;
    final name = normalizeCategoryName(_newName.text);
    final problem = categoryNameProblem(_newName.text, _list);
    if (problem != null) {
      setState(() => _newError = problem);
      _newFocus.requestFocus();
      return;
    }
    var moveParentEvents = false;
    if (_newParentId != null) {
      final parent = _list.cast<Category?>().firstWhere(
        (c) => c!.id == _newParentId,
        orElse: () => null,
      );
      final n = parent?.eventCount ?? 0;
      if (parent != null && n > 0) {
        final ok = await showConfirmDialog(
          context,
          title: 'Move ${parent.name}\'s transactions?',
          message:
              '${parent.name} has ${n == 1 ? '1 transaction' : '$n transactions'}. '
              'Adding a subcategory turns it into a folder, which can\'t hold '
              'transactions. Those will move into "$name".',
          confirmLabel: 'Move and add',
          cancelLabel: 'Cancel',
          isDestructive: false,
        );
        if (!ok || !mounted) return;
        moveParentEvents = true;
      }
    }
    setState(() => _busy = true);
    try {
      final c = await _notifier.create(
        name,
        color: _newColor ?? pickCategoryColor(_list),
        parentId: _newParentId,
        moveParentEvents: moveParentEvents,
      );
      if (!mounted) return;
      setState(() {
        _lastCreated = c.id;
        _newName.clear();
        _newError = null;
        _newColor = null; // a fresh random one for the next
      });
      // The new row is pinned, so bring the created one into view.
      _revealRow(c.id);
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

  // ---- deletes ----

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

  static String _others(int others) => others > 0
      ? ', plus ${others == 1 ? 'the other side of 1 transfer' : 'the other sides of $others transfers'}'
      : '';

  Future<void> _delete(Category c, int n) async {
    int children = 0;
    try {
      final p = await ref
          .read(categoryRepositoryProvider)
          .deletePreview(widget.streamId, c.id);
      children = p.children;
    } catch (_) {}
    if (!mounted) return;
    if (children > 0) {
      final label = children == 1 ? '1 subcategory' : '$children subcategories';
      await showConfirmDialog(
        context,
        title: 'Move or delete subcategories first',
        message:
            '"${c.name}" has $label. Move them to another category or '
            'the top level, or delete them, before deleting this one.',
        confirmLabel: 'OK',
      );
      return;
    }
    final others = n == 0 ? 0 : await _counterparts(c);
    if (!mounted) return;
    final ok = await showConfirmDialog(
      context,
      title: 'Delete category "${c.name}"?',
      message: n == 0
          ? 'No stream has events in it. Only the category is deleted.'
          : 'This deletes "${c.name}" and '
                '${n == 1 ? 'its 1 event' : 'all $n of its events'} across '
                'all your streams${_others(others)}. This can\'t be undone.',
      confirmLabel: n == 0 ? 'Delete category' : 'Delete category and events',
    );
    if (!ok || !mounted) return;
    await _run(() async {
      await _notifier.delete(c.id);
      final last = lastCategoryProvider(widget.streamId);
      if (ref.read(last) == c.id) {
        rememberLastCategory(ref, widget.streamId, null);
      }
    });
  }

  Future<void> _deleteEvents(Category c, int n) async {
    final others = await _counterparts(c);
    if (!mounted) return;
    final ok = await showConfirmDialog(
      context,
      title: 'Delete ${_events(n)}?',
      message:
          '${n == 1 ? 'The 1 event' : 'All $n events'} in "${c.name}" '
          '${n == 1 ? 'is' : 'are'} deleted across all your streams'
          '${_others(others)}. The category stays.',
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

  Future<void> _toggleFavorite(Category c) async {
    if (!isCategoryLeaf(_list, c) &&
        !(ref.read(categoryFavoritesProvider(widget.streamId)).valueOrNull ??
                const <String>[])
            .contains(c.id)) {
      return;
    }
    await _run(
      () => ref
          .read(categoryFavoritesProvider(widget.streamId).notifier)
          .toggle(c.id),
    );
  }

  Future<void> _move(Category c, String? parentId) async {
    if (parentId != null) {
      final parent = _list.cast<Category?>().firstWhere(
        (x) => x!.id == parentId,
        orElse: () => null,
      );
      final n = parent?.eventCount ?? 0;
      if (parent != null && n > 0) {
        await _explain(
          "Can't nest under ${parent.name}",
          '${parent.name} has ${n == 1 ? '1 transaction' : '$n transactions'}. '
              "Folders can't hold transactions. Add a subcategory first — you'll "
              'be asked to move those transactions into it.',
        );
        return;
      }
    }
    await _run(
      () => _notifier.edit(
        c.id,
        parentId: parentId,
        clearParent: parentId == null,
      ),
    );
  }

  Future<void> _shiftSibling(Category c, int delta) async {
    final sibs = c.parentId == null
        ? rootCategories(_list)
        : childCategories(_list, c.parentId!);
    final i = sibs.indexWhere((x) => x.id == c.id);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= sibs.length) return;
    final ids = [for (final x in sibs) x.id];
    ids.removeAt(i);
    ids.insert(j, c.id);
    await _run(() => _notifier.reorder(parentId: c.parentId, ids: ids));
  }

  Future<void> _moveToSheet(Category c) async {
    final targets = [
      for (final r in rootCategories(_list))
        if (canMoveToParent(_list, c, r)) r,
    ];
    final choice = await showModalBottomSheet<String?>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            key: ValueKey('category-move-sheet-${c.id}'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(
                  'Move "${c.name}" to…',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (c.parentId != null)
                ListTile(
                  key: ValueKey('category-move-top-${c.id}'),
                  leading: const Icon(Icons.vertical_align_top_rounded),
                  title: const Text('Top level'),
                  onTap: () => Navigator.pop(context, ''),
                ),
              for (final t in targets)
                ListTile(
                  key: ValueKey('category-move-to-${t.id}'),
                  leading: categoryDot(colorFromHex(t.color)),
                  title: Text(t.name),
                  onTap: () => Navigator.pop(context, t.id),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    await _move(c, choice.isEmpty ? null : choice);
  }

  void _startSubcategory(Category parent) {
    setState(() {
      _newParentId = parent.id;
      _expanded.add(parent.id);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _newFocus.requestFocus();
    });
  }

  // ---- layout ----

  double get _button => _touch ? 40 : 36;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final async = ref.watch(categoriesProvider(widget.streamId));
    final counts = categoryEventCounts(ref, widget.streamId);
    final raw = async.valueOrNull ?? const <Category>[];
    if (!_expandedReady && raw.isNotEmpty) {
      _expanded.addAll(rootCategories(raw).map((c) => c.id));
      _expandedReady = true;
    }
    final list = [
      for (final c in flattenedTree(raw))
        if (c.parentId == null || _expanded.contains(c.parentId)) c,
    ];
    final manage = _canManage;
    final narrow = MediaQuery.sizeOf(context).width < 420;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: AppTheme.textMuted,
    );
    return Actions(
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            _dismiss();
            return null;
          },
        ),
      },
      // Its own scope: a blurred field leaves focus here (below these
      // actions), so Escape still cancels an open edit first.
      child: FocusScope(
        child: _body(theme, async, counts, list, manage, narrow, muted),
      ),
    );
  }

  Widget _body(
    ThemeData theme,
    AsyncValue<List<Category>> async,
    Map<String, int> counts,
    List<Category> list,
    bool manage,
    bool narrow,
    TextStyle? muted,
  ) {
    return Padding(
      key: const ValueKey('categories-manager'),
      padding: EdgeInsets.fromLTRB(narrow ? 12 : 20, 14, narrow ? 4 : 10, 18),
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
            padding: const EdgeInsets.only(right: 8, bottom: 10),
            child: Text(
              key: const ValueKey('categories-description'),
              !widget.canEdit
                  ? 'View only: you have viewer access. Categories are shared '
                        'by all the owner\'s streams.'
                  : manage
                  ? 'Shared by all your streams. Tap a name to rename a '
                        'category, or a folder to expand it. Recolour a leaf '
                        'with its dot. Drag the handle to reorder. More has '
                        'Move, Delete, and Delete events.'
                  : 'Shared by all the owner\'s streams. You can add '
                        'categories; only the owner renames or deletes them.',
              style: muted,
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
                key: _listAreaKey,
                controller: _scroll,
                physics: _draggingId != null
                    ? const NeverScrollableScrollPhysics()
                    : null,
                padding: const EdgeInsets.only(right: 6, bottom: 4),
                child: Column(
                  key: const ValueKey('categories-table'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _headerRow(muted, manage),
                    const Divider(height: 1),
                    for (final c in list) ...[
                      _wrapDropCue(c, _row(c, manage, counts)),
                      const Divider(height: 1),
                    ],
                  ],
                ),
              ),
            ),
          // The dashed new-category row is pinned below the table: only the
          // rows above it scroll, so Add is always in reach.
          if (widget.canEdit && async.valueOrNull != null)
            Padding(
              key: const ValueKey('category-new-footer'),
              padding: const EdgeInsets.only(top: 10, right: 6),
              child: _newRow(),
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

  Widget _headerRow(TextStyle? style, bool manage) {
    final s = style?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.5);
    return Padding(
      key: const ValueKey('categories-header'),
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          if (manage) SizedBox(width: _button + 4),
          SizedBox(width: _button + 4),
          Expanded(child: Text('NAME', style: s)),
          if (manage) SizedBox(width: _button),
        ],
      ),
    );
  }

  // ---- handle drag (immediate, touch and mouse) ----

  void _onHandleDown(Category c, PointerDownEvent e) {
    if (_busy || _draggingId != null) return;
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryMouseButton) {
      return;
    }
    _dragPointer = e.pointer;
    GestureBinding.instance.pointerRouter.addRoute(e.pointer, _onDragPointer);
    setState(() {
      _draggingId = c.id;
      _pointerPos = e.position;
      _dropCue = _cueAt(e.position);
    });
    _insertFeedback(c);
    _autoScroll?.cancel();
    _autoScroll = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _autoScrollTick(),
    );
  }

  void _onDragPointer(PointerEvent e) {
    if (e.pointer != _dragPointer) return;
    if (e is PointerMoveEvent) {
      _pointerPos = e.position;
      final cue = _cueAt(e.position);
      if (mounted) setState(() => _dropCue = cue);
      _feedback?.markNeedsBuild();
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      _finishDrag(drop: e is PointerUpEvent);
    }
  }

  void _finishDrag({required bool drop}) {
    final id = _draggingId;
    final cue = _dropCue;
    _clearDrag(notify: true);
    if (!drop || id == null || cue == null) return;
    final c = categoryById(_list, id);
    if (c == null) return;
    _applyDrop(c, cue);
  }

  void _clearDrag({bool notify = true}) {
    if (_dragPointer != null) {
      GestureBinding.instance.pointerRouter.removeRoute(
        _dragPointer!,
        _onDragPointer,
      );
    }
    _autoScroll?.cancel();
    _autoScroll = null;
    _feedback?.remove();
    _feedback = null;
    _dragPointer = null;
    _draggingId = null;
    _pointerPos = null;
    _dropCue = null;
    if (notify && mounted) setState(() {});
  }

  void _insertFeedback(Category c) {
    _feedback?.remove();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _feedback = OverlayEntry(
      builder: (context) {
        final p = _pointerPos ?? Offset.zero;
        final allowed = _dropCue?.allowed ?? false;
        final theme = Theme.of(context);
        return Positioned(
          left: p.dx + 12,
          top: p.dy + 8,
          child: IgnorePointer(
            child: Material(
              key: const ValueKey('category-drag-feedback'),
              elevation: 6,
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      allowed ? Icons.drag_indicator_rounded : Icons.block,
                      size: 16,
                      color: allowed
                          ? AppTheme.textMuted
                          : theme.colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    Text(c.name),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(_feedback!);
  }

  void _autoScrollTick() {
    if (_draggingId == null || _pointerPos == null || !_scroll.hasClients) {
      return;
    }
    final ctx = _listAreaKey.currentContext;
    final box = ctx?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    final y = _pointerPos!.dy;
    const edge = 48.0;
    var delta = 0.0;
    if (y < top + edge) {
      delta = -((top + edge) - y).clamp(4.0, 18.0);
    } else if (y > bottom - edge) {
      delta = (y - (bottom - edge)).clamp(4.0, 18.0);
    }
    if (delta == 0) return;
    final next = (_scroll.offset + delta).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    if (next == _scroll.offset) return;
    _scroll.jumpTo(next);
    if (mounted) setState(() => _dropCue = _cueAt(_pointerPos!));
    _feedback?.markNeedsBuild();
  }

  bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  int _destIndex(String? parentId, {Category? before, Category? after}) {
    final ids = [
      for (final s
          in parentId == null
              ? rootCategories(_list)
              : childCategories(_list, parentId))
        if (s.id != _draggingId) s.id,
    ];
    if (before != null) {
      final i = ids.indexOf(before.id);
      return i < 0 ? 0 : i;
    }
    if (after != null) {
      final i = ids.indexOf(after.id);
      return i < 0 ? ids.length : i + 1;
    }
    return ids.length;
  }

  bool _canNest(Category dragged, Category parent) =>
      canMoveToParent(_list, dragged, parent) && parent.eventCount == 0;

  _DropCue _insertCue({
    required Category dragged,
    required String? parentId,
    required int index,
    String? lineAboveId,
    String? lineBelowId,
    String? highlightFolderId,
  }) {
    var allowed = true;
    if (parentId != dragged.parentId) {
      final parent = parentId == null ? null : categoryById(_list, parentId);
      allowed =
          canMoveToParent(_list, dragged, parent) &&
          (parent == null || parent.eventCount == 0);
    }
    return _DropCue(
      parentId: parentId,
      index: index,
      lineAboveId: allowed ? lineAboveId : null,
      lineBelowId: allowed ? lineBelowId : null,
      highlightFolderId: allowed ? highlightFolderId : null,
      allowed: allowed,
    );
  }

  _DropCue? _cueAt(Offset global) {
    final dragged = categoryById(_list, _draggingId);
    if (dragged == null) return null;
    final boxes = <({Category c, Rect r})>[];
    for (final c in _visible) {
      final ctx = _rowKeys[c.id]?.currentContext;
      final box = ctx?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize || !box.attached) continue;
      boxes.add((c: c, r: box.localToGlobal(Offset.zero) & box.size));
    }
    if (boxes.isEmpty) return null;
    final y = global.dy;

    _DropCue before(Category c) => _insertCue(
      dragged: dragged,
      parentId: c.parentId,
      index: _destIndex(c.parentId, before: c),
      lineAboveId: c.id,
    );
    _DropCue after(Category c) => _insertCue(
      dragged: dragged,
      parentId: c.parentId,
      index: _destIndex(c.parentId, after: c),
      lineBelowId: c.id,
    );

    for (var i = 0; i < boxes.length; i++) {
      final b = boxes[i];
      if (y < b.r.top) {
        return i == 0 ? before(b.c) : after(boxes[i - 1].c);
      }
      if (y <= b.r.bottom) {
        if (b.c.id == dragged.id) {
          return _DropCue(
            parentId: dragged.parentId,
            index: _destIndex(dragged.parentId, before: b.c),
            allowed: true,
          );
        }
        final isFolder = childCategories(_list, b.c.id).isNotEmpty;
        final t = b.r.height == 0 ? 0.5 : (y - b.r.top) / b.r.height;
        if (isFolder && t >= 0.28 && t <= 0.72 && _canNest(dragged, b.c)) {
          return _DropCue(
            parentId: b.c.id,
            index: 0,
            highlightFolderId: b.c.id,
            allowed: true,
          );
        }
        return t < 0.5 ? before(b.c) : after(b.c);
      }
    }

    // Gaps already handled by the top < next.top branch. After the last:
    final last = boxes.last.c;
    if (last.id == dragged.id) {
      return _DropCue(
        parentId: dragged.parentId,
        index: _destIndex(dragged.parentId, after: last),
        allowed: true,
      );
    }
    return after(last);
  }

  Future<void> _applyDrop(Category c, _DropCue cue) async {
    if (!cue.allowed) return;
    final destParent = cue.parentId;
    final sibs = destParent == null
        ? rootCategories(_list)
        : childCategories(_list, destParent);
    final ids = [
      for (final s in sibs)
        if (s.id != c.id) s.id,
    ];
    final index = cue.index.clamp(0, ids.length);
    ids.insert(index, c.id);
    final current = [for (final s in sibs) s.id];
    if (c.parentId == destParent && _sameIds(current, ids)) return;
    if (c.parentId != destParent) {
      if (destParent != null) {
        final parent = categoryById(_list, destParent);
        final n = parent?.eventCount ?? 0;
        if (parent != null && n > 0) {
          await _explain(
            "Can't nest under ${parent.name}",
            '${parent.name} has ${n == 1 ? '1 transaction' : '$n transactions'}. '
                "Folders can't hold transactions. Add a subcategory first — you'll "
                'be asked to move those transactions into it.',
          );
          return;
        }
      }
      await _run(() async {
        await _notifier.edit(
          c.id,
          parentId: destParent,
          clearParent: destParent == null,
        );
        await _notifier.reorder(parentId: destParent, ids: ids);
      });
    } else {
      await _run(() => _notifier.reorder(parentId: c.parentId, ids: ids));
    }
  }

  Widget _dropLine() => Container(
    key: const ValueKey('category-drop-line'),
    height: 3,
    margin: const EdgeInsets.symmetric(horizontal: 8),
    decoration: BoxDecoration(
      color: AppTheme.accent,
      borderRadius: BorderRadius.circular(2),
    ),
  );

  Widget _wrapDropCue(Category c, Widget body) {
    final cue = _dropCue;
    final above = cue != null && cue.lineAboveId == c.id;
    final below = cue != null && cue.lineBelowId == c.id;
    final hl = cue != null && cue.highlightFolderId == c.id;
    final dragging = _draggingId == c.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (above) _dropLine(),
        DecoratedBox(
          decoration: hl
              ? BoxDecoration(
                  color: AppTheme.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.accent, width: 2),
                )
              : const BoxDecoration(),
          child: Opacity(opacity: dragging ? 0.35 : 1, child: body),
        ),
        if (below) _dropLine(),
      ],
    );
  }

  Widget _row(Category c, bool manage, Map<String, int> counts) {
    final theme = Theme.of(context);
    final editing = manage && _editingId == c.id;
    final b = _button;
    final kids = childCategories(_list, c.id);
    final direct = counts[c.id] ?? c.eventCount;
    final favs =
        ref.watch(categoryFavoritesProvider(widget.streamId)).valueOrNull ??
        const <String>[];
    final isFav = favs.contains(c.id);
    final sibs = c.parentId == null
        ? rootCategories(_list)
        : childCategories(_list, c.parentId!);
    final sibIndex = sibs.indexWhere((x) => x.id == c.id);
    final Widget name = editing
        ? CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _dismiss,
            },
            child: TextField(
              key: ValueKey('category-name-field-${c.id}'),
              controller: _editName,
              focusNode: _editFocus,
              maxLength: maxCategoryNameLength,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                isDense: true,
                counterText: '',
                errorText: _editError,
                errorMaxLines: 3,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 10,
                ),
                suffixIconConstraints: BoxConstraints.tightFor(
                  width: b,
                  height: b,
                ),
                suffixIcon: IconButton(
                  key: ValueKey('category-name-save-${c.id}'),
                  tooltip: 'Save name',
                  padding: EdgeInsets.zero,
                  iconSize: 20,
                  onPressed: _busy ? null : _commitEdit,
                  icon: const Icon(Icons.check_rounded, color: AppTheme.accent),
                ),
              ),
              onChanged: (v) {
                if (_editError != null) {
                  setState(
                    () => _editError = categoryNameProblem(
                      v,
                      _list,
                      except: c.id,
                    ),
                  );
                }
              },
              onSubmitted: (_) => _commitEdit(),
              // Enter keeps the focus (an invalid name stays editable).
              onEditingComplete: () {},
              // A tap anywhere else blurs, which commits (all platforms).
              onTapOutside: (_) => _editFocus.unfocus(),
            ),
          )
        : InkWell(
            key: ValueKey('category-name-${c.id}'),
            borderRadius: BorderRadius.circular(6),
            onTap: kids.isNotEmpty
                ? () => _toggleExpanded(c)
                : (manage && !_busy ? () => _startEdit(c) : null),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: b),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (c.hidden) ...[
                      const SizedBox(width: 4),
                      const Tooltip(
                        message: 'Hidden on the timeline',
                        child: Icon(
                          Icons.visibility_off_outlined,
                          size: 14,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
    final body = Semantics(
      // Global: the row keeps its state as it moves to its sorted place,
      // and a renamed row can be scrolled back into view.
      key: _rowKeys.putIfAbsent(c.id, GlobalKey.new),
      container: true,
      explicitChildNodes: true,
      child: Opacity(
        key: ValueKey('category-row-${c.id}'),
        opacity: c.hidden && !editing ? 0.6 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: editing
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              if (manage)
                Listener(
                  onPointerDown: _busy ? null : (e) => _onHandleDown(c, e),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: Tooltip(
                      message: 'Drag to reorder',
                      child: SizedBox(
                        width: b,
                        height: b,
                        child: Icon(
                          Icons.drag_indicator_rounded,
                          key: ValueKey('category-drag-${c.id}'),
                          size: 20,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              SizedBox(width: 16.0 * (c.parentId == null ? 0 : 1)),
              // Leaf: tappable colour dot (static for viewers).
              // Folder: folder icon; tapping the row (or chevron) toggles it.
              SizedBox(
                width: b,
                height: b,
                child: kids.isEmpty
                    ? (manage
                          ? _ColorDotMenu(
                              key: ValueKey('category-color-${c.id}'),
                              color: c.color,
                              size: b,
                              onPicked: (v) {
                                if (v != c.color) {
                                  _run(() => _notifier.edit(c.id, color: v));
                                }
                              },
                            )
                          : Center(
                              child: categoryDot(
                                colorFromHex(c.color),
                                size: 14,
                              ),
                            ))
                    : InkWell(
                        onTap: () => _toggleExpanded(c),
                        borderRadius: BorderRadius.circular(6),
                        child: categoryFolderIcon(
                          open: _expanded.contains(c.id),
                          key: ValueKey('category-folder-${c.id}'),
                          color: colorFromHex(c.color) ?? AppTheme.textMuted,
                          size: kCategoryManagerFolderSize,
                        ),
                      ),
              ),
              const SizedBox(width: 4),
              Expanded(child: name),
              if (kids.isNotEmpty)
                IconButton(
                  key: ValueKey('category-expand-${c.id}'),
                  tooltip: _expanded.contains(c.id) ? 'Collapse' : 'Expand',
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints.tightFor(width: b, height: b),
                  onPressed: () => _toggleExpanded(c),
                  icon: categoryExpandIcon(open: _expanded.contains(c.id)),
                ),
              if (manage) ...[
                AppMenuAnchor(
                  key: ValueKey('category-menu-${c.id}'),
                  menuChildren: [
                    if (manage)
                      MenuItemButton(
                        key: ValueKey('category-rename-${c.id}'),
                        leadingIcon: const Icon(
                          Icons.drive_file_rename_outline,
                        ),
                        onPressed: _busy ? null : () => _startEdit(c),
                        child: const Text('Rename'),
                      ),
                    if (kids.isEmpty || isFav)
                      MenuItemButton(
                        key: ValueKey('category-star-${c.id}'),
                        leadingIcon: Icon(
                          isFav
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                        ),
                        onPressed: _busy ? null : () => _toggleFavorite(c),
                        child: Text(
                          isFav
                              ? 'Remove from favourites'
                              : 'Add to favourites',
                        ),
                      ),
                    if (widget.canEdit && c.parentId == null)
                      MenuItemButton(
                        key: ValueKey('category-add-child-${c.id}'),
                        leadingIcon: const Icon(
                          Icons.subdirectory_arrow_right_rounded,
                        ),
                        onPressed: _busy ? null : () => _startSubcategory(c),
                        child: const Text('New subcategory'),
                      ),
                    if (manage)
                      MenuItemButton(
                        key: ValueKey('category-move-${c.id}'),
                        leadingIcon: const Icon(Icons.drive_file_move_outline),
                        onPressed: _busy ? null : () => _moveToSheet(c),
                        child: const Text('Move to…'),
                      ),
                    if (manage) ...[
                      MenuItemButton(
                        key: ValueKey('category-up-${c.id}'),
                        leadingIcon: const Icon(
                          Icons.keyboard_arrow_up_rounded,
                        ),
                        onPressed: _busy || sibIndex <= 0
                            ? null
                            : () => _shiftSibling(c, -1),
                        child: const Text('Move up'),
                      ),
                      MenuItemButton(
                        key: ValueKey('category-down-${c.id}'),
                        leadingIcon: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                        ),
                        onPressed:
                            _busy || sibIndex < 0 || sibIndex >= sibs.length - 1
                            ? null
                            : () => _shiftSibling(c, 1),
                        child: const Text('Move down'),
                      ),
                    ],
                    if (direct > 0)
                      MenuItemButton(
                        key: ValueKey('category-delete-events-${c.id}'),
                        leadingIcon: const Icon(Icons.playlist_remove_rounded),
                        onPressed: _busy
                            ? null
                            : () => _deleteEvents(c, direct),
                        child: Text('Delete ${_events(direct)}'),
                      ),
                    MenuItemButton(
                      key: ValueKey('category-delete-${c.id}'),
                      leadingIcon: Icon(
                        Icons.delete_outline_rounded,
                        color: theme.colorScheme.error,
                      ),
                      onPressed: _busy ? null : () => _delete(c, direct),
                      child: const Text('Delete category'),
                    ),
                  ],
                  builder: (context, controller, _) => _action(
                    key: ValueKey('category-more-${c.id}'),
                    tooltip: 'More',
                    icon: Icons.more_vert_rounded,
                    onPressed: () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return body;
  }

  Widget _action({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool danger = false,
  }) => IconButton(
    key: key,
    tooltip: tooltip,
    padding: EdgeInsets.zero,
    constraints: BoxConstraints.tightFor(width: _button, height: _button),
    iconSize: 20,
    color: danger ? Theme.of(context).colorScheme.error : null,
    onPressed: onPressed,
    icon: Icon(icon),
  );

  Widget _newRow() {
    final theme = Theme.of(context);
    final color = _newColor ??= pickCategoryColor(_list);
    final b = _button;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CustomPaint(
          key: const ValueKey('category-new-row'),
          painter: _DashedPillPainter(color: AppTheme.textFaint, radius: 10),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 3, 2, 3),
            child: Row(
              children: [
                _ColorDotMenu(
                  key: const ValueKey('category-new-color'),
                  color: color,
                  size: b,
                  onPicked: (c) => setState(() => _newColor = c),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: TextField(
                    key: const ValueKey('category-new-name'),
                    controller: _newName,
                    focusNode: _newFocus,
                    maxLength: maxCategoryNameLength,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      hintText: _newParentId == null
                          ? 'New category name'
                          : 'New subcategory of ${categoryById(_list, _newParentId)?.name ?? ''}',
                      isDense: true,
                      counterText: '',
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 10,
                      ),
                    ),
                    // Checked as you type: a taken name shows before Add.
                    onChanged: (v) =>
                        setState(() => _newError = _newProblem(v)),
                    onSubmitted: (_) {
                      if (_newValid) _create();
                    },
                  ),
                ),
                IconButton(
                  key: const ValueKey('category-new-save'),
                  tooltip: 'Add category',
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints.tightFor(width: b, height: b),
                  onPressed: _busy || !_newValid ? null : _create,
                  icon: const Icon(Icons.add_rounded),
                  color: AppTheme.accent,
                ),
              ],
            ),
          ),
        ),
        if (_newParentId != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: TextButton(
              key: const ValueKey('category-new-parent-clear'),
              onPressed: () => setState(() => _newParentId = null),
              child: Text(
                'Top level instead of ${categoryById(_list, _newParentId)?.name ?? 'parent'}',
              ),
            ),
          ),
        if (_newError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              _newError!,
              key: const ValueKey('category-new-error'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}

/// A colour dot that opens the palette.
class _ColorDotMenu extends StatelessWidget {
  const _ColorDotMenu({
    super.key,
    required this.color,
    required this.onPicked,
    this.size = 40,
  });

  final String color;
  final ValueChanged<String> onPicked;

  /// The tap target's side.
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = colorFromHex(color) ?? laneColor(0);
    final i = laneColorIndexOf(c);
    return AppMenuAnchor(
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
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tightFor(width: size, height: size),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: categoryDot(c, size: 22),
      ),
    );
  }
}

/// The 12 palette colours as tappable swatches. A check mark marks
/// the [selected] swatch; the dots themselves are a plain fill.
class PaletteSwatches extends StatelessWidget {
  const PaletteSwatches({
    super.key,
    required this.selected,
    required this.onPicked,
    this.swatchKeyPrefix = 'category-swatch',
  });

  final String selected;
  final ValueChanged<String> onPicked;

  /// ValueKey prefix for each swatch (category-swatch-N by default).
  final String swatchKeyPrefix;

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
                key: ValueKey('$swatchKeyPrefix-$i'),
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

/// A dashed rounded outline ([radius]; null: a stadium), e.g. the "new
/// category" row's.
class _DashedPillPainter extends CustomPainter {
  _DashedPillPainter({required this.color, this.radius});

  final Color color;
  final double? radius;

  @override
  void paint(Canvas canvas, Size size) {
    final r = radius ?? size.height / 2;
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
  bool shouldRepaint(_DashedPillPainter old) =>
      old.color != color || old.radius != radius;
}

/// The editor's category picker: one full-width [CategoryDropdown] (pick
/// one; categories are made and changed in the manager, reached from the
/// menu's last row, "Manage categories…"). With none yet, the field is a
/// "Create a category" prompt that opens the manager. Read-only
/// ([enabled] false): the chosen category, no menu.
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
    final Widget field;
    if (list.isEmpty) {
      // Loading, or none yet: a prompt field (opens the manager to create
      // one), plain text for viewers.
      final loading = async.isLoading && async.valueOrNull == null;
      final create = enabled && !loading;
      field = Semantics(
        button: create,
        label: 'Category',
        child: InkWell(
          key: ValueKey(
            create ? 'editor-create-category' : 'editor-category-empty',
          ),
          borderRadius: BorderRadius.circular(12),
          onTap: create ? onManage : null,
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: 'Category',
              enabled: create,
              suffixIcon: loading
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : create
                  ? const Icon(Icons.add_rounded)
                  : null,
              error: _error(theme),
            ),
            child: Text(
              loading
                  ? 'Loading…'
                  : create
                  ? 'Create a category'
                  : 'No categories yet',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: create ? AppTheme.accent : AppTheme.textFaint,
              ),
            ),
          ),
        ),
      );
    } else {
      final favIds =
          ref.watch(categoryFavoritesProvider(streamId)).valueOrNull ??
          const <String>[];
      field = CategoryDropdown(
        categories: list,
        selectedId: selectedId,
        onSelected: (c) {
          if (c != null) onSelected(c);
        },
        triggerKey: const ValueKey('editor-category-field'),
        itemKeyPrefix: 'editor-category-',
        labelText: 'Category',
        errorText: errorText,
        errorKey: const ValueKey('editor-category-error'),
        enabled: enabled,
        hideHiddenBranches: true,
        favoriteIds: favIds,
        onToggleFavorite: enabled
            ? (c) => ref
                  .read(categoryFavoritesProvider(streamId).notifier)
                  .toggle(c.id)
            : null,
        footer: CategoryDropdownAction(
          key: const ValueKey('editor-manage-categories'),
          icon: Icons.tune_rounded,
          label: 'Manage categories…',
          onPressed: onManage,
        ),
      );
    }
    return KeyedSubtree(key: const ValueKey('editor-category'), child: field);
  }

  Widget? _error(ThemeData theme) => errorText == null
      ? null
      : Text(
          errorText!,
          key: const ValueKey('editor-category-error'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        );
}

class _DropCue {
  const _DropCue({
    required this.parentId,
    required this.index,
    this.lineAboveId,
    this.lineBelowId,
    this.highlightFolderId,
    required this.allowed,
  });

  final String? parentId;
  final int index;
  final String? lineAboveId;
  final String? lineBelowId;
  final String? highlightFolderId;
  final bool allowed;
}
