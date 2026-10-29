import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
/// its events. The last row is a dashed "new category" row. Viewers see
/// the table read-only; editors may only add.
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

  List<Category> get _list =>
      ref.read(categoriesProvider(widget.streamId)).valueOrNull ??
      const <Category>[];

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
    _newName.dispose();
    _newFocus.dispose();
    _editName.dispose();
    _editFocus.dispose();
    _undoTimer?.cancel();
    super.dispose();
  }

  // ---- in-place rename ----

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
      if (mounted) setState(() => _editingId = null);
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

  Future<void> _create() async {
    if (_busy) return;
    final problem = categoryNameProblem(_newName.text, _list);
    if (problem != null) {
      setState(() => _newError = problem);
      _newFocus.requestFocus();
      return;
    }
    setState(() => _busy = true);
    try {
      final c = await _notifier.create(
        normalizeCategoryName(_newName.text),
        color: _newColor ?? pickCategoryColor(_list),
      );
      if (!mounted) return;
      setState(() {
        _lastCreated = c.id;
        _newName.clear();
        _newError = null;
        _newColor = null; // a fresh random one for the next
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

  // ---- layout ----

  double get _button => _touch ? 40 : 36;
  static const double _countWidth = 52;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final async = ref.watch(categoriesProvider(widget.streamId));
    final counts = categoryEventCounts(ref, widget.streamId);
    final list = async.valueOrNull ?? const <Category>[];
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
                  ? 'Shared by all your streams: counts and deletes cover '
                        'every stream. Tap a name to rename it, a dot to '
                        'recolour.'
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
                padding: const EdgeInsets.only(right: 6, bottom: 4),
                child: Column(
                  key: const ValueKey('categories-table'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _headerRow(muted, manage),
                    const Divider(height: 1),
                    for (final c in list) ...[
                      _row(c, counts[c.id] ?? 0, manage),
                      const Divider(height: 1),
                    ],
                    if (widget.canEdit) ...[
                      const SizedBox(height: 10),
                      _newRow(),
                    ],
                  ],
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

  Widget _headerRow(TextStyle? style, bool manage) {
    final s = style?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.5);
    return Padding(
      key: const ValueKey('categories-header'),
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(width: _button + 4),
          Expanded(child: Text('NAME', style: s)),
          Tooltip(
            message: 'Events in all streams',
            child: SizedBox(
              width: _countWidth,
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('EVENTS', style: s, maxLines: 1),
                ),
              ),
            ),
          ),
          if (manage) SizedBox(width: _button * 2 + 6),
        ],
      ),
    );
  }

  Widget _row(Category c, int n, bool manage) {
    final theme = Theme.of(context);
    final color = colorFromHex(c.color) ?? laneColor(0);
    final editing = manage && _editingId == c.id;
    final b = _button;
    final Widget swatch = manage
        ? _ColorDotMenu(
            key: ValueKey('category-color-${c.id}'),
            color: c.color,
            size: b,
            onPicked: (v) {
              if (v != c.color) _run(() => _notifier.edit(c.id, color: v));
            },
          )
        : SizedBox(
            width: b,
            height: b,
            child: Center(
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
          );
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
            onTap: manage && !_busy ? () => _startEdit(c) : null,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: b),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        c.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
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
    return Semantics(
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
              swatch,
              const SizedBox(width: 4),
              Expanded(child: name),
              SizedBox(
                width: _countWidth,
                height: b,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '$n',
                    semanticsLabel: '${_events(n)} in all streams',
                    key: ValueKey('category-count-${c.id}'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textMuted,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              if (manage) ...[
                const SizedBox(width: 6),
                _action(
                  key: ValueKey('category-delete-events-${c.id}'),
                  tooltip: n == 0
                      ? 'No events to delete'
                      : 'Delete ${_events(n)} in all streams (keep category)',
                  icon: Icons.playlist_remove_rounded,
                  onPressed: _busy || n == 0 ? null : () => _deleteEvents(c, n),
                ),
                _action(
                  key: ValueKey('category-delete-${c.id}'),
                  tooltip: n == 0
                      ? 'Delete category'
                      : 'Delete category and its ${_events(n)}',
                  icon: Icons.delete_outline_rounded,
                  danger: true,
                  onPressed: _busy ? null : () => _delete(c, n),
                ),
              ],
            ],
          ),
        ),
      ),
    );
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
                    decoration: const InputDecoration(
                      hintText: 'New category name',
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
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tightFor(width: size, height: size),
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
