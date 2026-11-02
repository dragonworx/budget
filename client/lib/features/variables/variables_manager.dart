// The central variables manager (spec 012): the owner's variables in a
// table shaped like the categories manager (same dialog, paddings, header,
// table rules, dashed add row and undo strip).
import 'dart:async';
import 'dart:convert';

import 'package:budget_formula/budget_formula.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/repositories.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/formula/formula_field.dart';
import '../../widgets/formula/formula_style.dart';
import '../events/editor_outcome.dart' show undoTipDuration;
import 'variable_impact.dart';
import 'variable_usages_dialog.dart';

/// Opens the variables manager: [streamId] null = my own variables, else
/// that stream's owner's (read-only unless I own it). [createName]
/// prefills the add row (and focuses its value); [focusVariableId]
/// scrolls to that row. Resolves to the name of the last variable created.
Future<String?> showVariablesManager(
  BuildContext context, {
  String? streamId,
  String? createName,
  String? focusVariableId,
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
        child: VariablesManager(
          streamId: streamId,
          createName: createName,
          focusVariableId: focusVariableId,
        ),
      ),
    ),
  );
}

/// Display precision when none is set: 2 for money; null (as written,
/// like the formula suggestions list) for percent and number.
int? defaultVariableDecimals(String unit) => unit == 'money' ? 2 : null;

const _units = ['money', 'percent', 'number'];
const _unitNames = {'money': 'Money', 'percent': 'Percent', 'number': 'Number'};

VariableUnit _unitOf(String u) => switch (u) {
  'money' => VariableUnit.money,
  'percent' => VariableUnit.percent,
  _ => VariableUnit.number,
};

/// The owner's variables by name (natural, case-insensitive).
List<Variable> sortedVariables(Iterable<Variable> list) =>
    [...list]..sort((a, b) => compareNames(a.name, b.name));

/// The `{code}` in an API error's details (or body), if any.
String? apiErrorCode(Object e) {
  if (e is! ApiException || e.body == null) return null;
  try {
    final j = jsonDecode(e.body!);
    if (j is! Map) return null;
    final d = j['details'];
    if (d is Map && d['code'] != null) return '${d['code']}';
    return j['code'] as String?;
  } catch (_) {
    return null;
  }
}

String? _apiDetail(Object e, String key) {
  if (e is! ApiException || e.body == null) return null;
  try {
    final j = jsonDecode(e.body!);
    final d = j is Map ? j['details'] : null;
    return d is Map && d[key] != null ? '${d[key]}' : null;
  } catch (_) {
    return null;
  }
}

/// A write's error for the user: a taken name, a cycle, else the server's.
String variableWriteError(Object e) {
  final code = apiErrorCode(e);
  if (code == 'variable_name_taken' ||
      (e is ApiException && e.statusCode == 409 && code == null)) {
    return 'That name is taken';
  }
  if (code == 'cycle') {
    final path = _apiDetail(e, 'path');
    if (path != null) return 'These variables depend on each other: $path';
  }
  return friendlyError(e);
}

class VariablesManager extends ConsumerStatefulWidget {
  const VariablesManager({
    super.key,
    this.streamId,
    this.createName,
    this.focusVariableId,
  });

  final String? streamId;
  final String? createName;
  final String? focusVariableId;

  @override
  ConsumerState<VariablesManager> createState() => _VariablesManagerState();
}

enum _Edit { name, value }

class _VariablesManagerState extends ConsumerState<VariablesManager> {
  bool _busy = false;
  String? _error;
  String? _lastCreated;

  // The add row.
  final _newName = TextEditingController();
  final _newNameFocus = FocusNode(debugLabel: 'new variable name');
  final _newValue = FormulaEditingController();
  final _newValueFocus = FocusNode(debugLabel: 'new variable value');
  String _newUnit = 'money';
  String? _newError;

  // The in-place edit (one row, one cell).
  String? _editingId;
  _Edit? _editing;
  final _editName = TextEditingController();
  late final _editNameFocus = FocusNode(debugLabel: 'variable name')
    ..addListener(_editFocusChanged);
  final _editValue = FormulaEditingController();
  late final _editValueFocus = FocusNode(debugLabel: 'variable value')
    ..addListener(_editFocusChanged);
  final _editValueKey = GlobalKey();
  String? _editError;

  /// The undo strip: one at a time, dismissed by the next action.
  ({String text, Future<void> Function() run})? _undo;
  Timer? _undoTimer;

  /// A row briefly highlighted after "jump to" from the usages list.
  String? _flashId;
  Timer? _flashTimer;

  final Map<String, GlobalKey> _rowKeys = {};

  /// Holds focus when an edit closes, so Escape still reaches the dialog.
  final _scope = FocusScopeNode(debugLabel: 'variables manager');

  VariableRepository get _repo => ref.read(variableRepositoryProvider);

  AsyncValue<List<Variable>> _watchList() => widget.streamId == null
      ? ref.watch(myVariablesProvider)
      : ref.watch(variablesProvider(widget.streamId!));

  List<Variable> get _list =>
      (widget.streamId == null
              ? ref.read(myVariablesProvider)
              : ref.read(variablesProvider(widget.streamId!)))
          .valueOrNull ??
      const <Variable>[];

  Variable? _find(String id) => _list.where((v) => v.id == id).firstOrNull;

  /// My own set, or the stream's role (D3: only the owner changes them).
  Role? get _role => widget.streamId == null
      ? Role.owner
      : ref.watch(streamProvider(widget.streamId!)).valueOrNull?.role;

  bool get _owner => _role?.isOwner ?? false;

  bool get _touch {
    final p = Theme.of(context).platform;
    return p == TargetPlatform.android || p == TargetPlatform.iOS;
  }

  double get _button => _touch ? 40 : 36;

  @override
  void initState() {
    super.initState();
    final create = widget.createName;
    if (create != null && create.isNotEmpty) {
      _newName.text = create;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _newValueFocus.requestFocus();
      });
    }
    final focus = widget.focusVariableId;
    if (focus != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpTo(focus));
    }
  }

  @override
  void dispose() {
    _newName.dispose();
    _newNameFocus.dispose();
    _newValue.dispose();
    _newValueFocus.dispose();
    _editName.dispose();
    _editNameFocus.dispose();
    _editValue.dispose();
    _editValueFocus.dispose();
    _undoTimer?.cancel();
    _flashTimer?.cancel();
    _scope.dispose();
    super.dispose();
  }

  void _revealRow(String id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _rowKeys[id]?.currentContext;
      if (!mounted || ctx == null) return;
      for (final policy in const [
        ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      ]) {
        Scrollable.ensureVisible(ctx, alignmentPolicy: policy);
      }
    });
  }

  void _jumpTo(String id) {
    if (!mounted) return;
    _flashTimer?.cancel();
    setState(() => _flashId = id);
    _flashTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _flashId = null);
    });
    _revealRow(id);
  }

  /// After my own write: this list now, the other views when they next
  /// look (values may have moved in events, balances and other streams).
  Future<void> _refresh({bool values = false}) async {
    // Every stream of mine lists the same set (not just this one).
    invalidateVariables(ref.invalidate);
    if (widget.streamId == null) {
      await ref.read(myVariablesProvider.future);
    } else {
      await ref.read(variablesProvider(widget.streamId!).future);
    }
    if (values) {
      ref.invalidate(eventsProvider);
      ref.invalidate(balanceProvider);
      ref.invalidate(streamProvider);
    }
  }

  /// [action] with buttons disabled; errors go to the error line.
  Future<bool> _run(
    Future<void> Function() action, {
    bool keepUndo = false,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
      if (!keepUndo) _clearUndo();
    });
    try {
      await action();
      return true;
    } catch (e) {
      if (mounted) setState(() => _error = variableWriteError(e));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _clearUndo() {
    _undoTimer?.cancel();
    _undo = null;
  }

  void _offerUndo(String text, Future<void> Function() run) {
    if (!mounted) return;
    _undoTimer?.cancel();
    setState(() => _undo = (text: text, run: run));
    _undoTimer = Timer(undoTipDuration * 2, () {
      if (mounted) setState(() => _undo = null);
    });
  }

  Future<void> _runUndo() async {
    final u = _undo;
    if (u == null) return;
    setState(_clearUndo);
    await _run(u.run, keepUndo: true);
  }

  // ---- in-place edits ----

  void _startEdit(Variable v, _Edit what) {
    if (_busy || !_owner) return;
    setState(() {
      _clearUndo();
      _editingId = v.id;
      _editing = what;
      _editError = null;
      if (what == _Edit.name) {
        _editName.text = v.name;
        _editName.selection = TextSelection(
          baseOffset: 0,
          extentOffset: v.name.length,
        );
      } else {
        _editValue.text = v.expr;
        _editValue.selection = TextSelection.collapsed(offset: v.expr.length);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (what == _Edit.name ? _editNameFocus : _editValueFocus).requestFocus();
    });
  }

  /// Set for the rest of the frame an edit was cancelled in, so the same
  /// Escape doesn't also close the dialog.
  bool _justCancelled = false;

  void _cancelEdit({String? because}) {
    _justCancelled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _justCancelled = false);
    WidgetsBinding.instance.scheduleFrame();
    _closeEdit();
    if (because != null) setState(() => _error = because);
  }

  /// Ends the in-place edit; focus stays in the manager (not lost with
  /// the field) unless it already moved elsewhere in it.
  void _closeEdit() {
    final hadFocus = _editNameFocus.hasFocus || _editValueFocus.hasFocus;
    setState(() {
      _editingId = null;
      _editing = null;
      _editError = null;
    });
    if (hadFocus) _scope.requestFocus();
  }

  void _dismiss() {
    if (_editingId != null) return _cancelEdit();
    if (_justCancelled) return;
    Navigator.of(context).pop(_lastCreated);
  }

  /// Blur commits, unless focus only moved into the field's own popups
  /// (help, picker dialog) or a dialog opened on top.
  void _editFocusChanged() {
    if (_editingId == null) return;
    final node = _editing == _Edit.name ? _editNameFocus : _editValueFocus;
    if (node.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _editingId == null || node.hasFocus) return;
      if (ModalRoute.of(context)?.isCurrent == false) return;
      if (_editing == _Edit.value && _focusInsideValueField()) return;
      _commitEdit();
    });
  }

  bool _focusInsideValueField() {
    final field = _editValueKey.currentContext;
    final focus = FocusManager.instance.primaryFocus?.context;
    if (field == null || focus == null) return false;
    var inside = false;
    focus.visitAncestorElements((e) {
      if (e == field) inside = true;
      return !inside;
    });
    return inside;
  }

  Future<void> _commitEdit() =>
      _editing == _Edit.name ? _commitName() : _commitValue();

  Future<void> _commitName() async {
    final id = _editingId;
    if (id == null || _busy) return;
    final v = _find(id);
    if (v == null) return _cancelEdit(because: 'This variable was deleted');
    final name = _editName.text.trim();
    if (name == v.name) return _cancelEdit();
    final problem = variableNameProblem(name, [
      for (final o in _list) o.name,
    ], self: v.name);
    if (problem != null) {
      setState(() => _editError = problem);
      return;
    }
    final old = v.name;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _repo.update(
        id,
        streamId: widget.streamId,
        name: name,
        version: v.version,
      );
      await _refresh(values: v.usageCount > 0);
      if (!mounted) return;
      _closeEdit();
      _revealRow(id);
      _offerUndo('Renamed $old to $name', () async {
        await _repo.update(
          id,
          streamId: widget.streamId,
          name: old,
          version: _find(id)?.version,
        );
        await _refresh(values: true);
      });
    } catch (e) {
      if (mounted) setState(() => _editError = variableWriteError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The text to store for a value field: the canonical formula, or the
  /// plain number.
  static String? _exprOf(FormulaValue f) {
    if (f.isEmpty) return null;
    if (f.isFormula) return f.expr ?? f.text.trim();
    return f.value?.toString() ?? f.text.trim();
  }

  static bool _sameExpr(String a, String b) {
    final x = Decimal.tryParse(a.trim()), y = Decimal.tryParse(b.trim());
    if (x != null && y != null) return x == y;
    return a.replaceAll(' ', '') == b.replaceAll(' ', '');
  }

  Map<String, String> get _unitsByName => {
    for (final v in _list) v.name.toLowerCase(): v.unit,
  };

  Future<void> _commitValue() async {
    final id = _editingId;
    if (id == null || _busy) return;
    final v = _find(id);
    if (v == null) return _cancelEdit(because: 'This variable was deleted');
    final f = _editValue.formula;
    final expr = _exprOf(f);
    if (expr == null) {
      setState(() => _editError = 'Enter a value');
      return;
    }
    if (f.message != null) {
      // The field already shows its own message under itself: once only.
      setState(() => _editError = null);
      _editValueFocus.requestFocus();
      return;
    }
    if (_sameExpr(expr, v.expr)) return _cancelEdit();
    final old = v.expr;
    setState(() {
      _busy = true;
      _error = null;
      _editError = null;
    });
    try {
      if (v.usageCount > 0) {
        final results = await Future.wait([
          _repo.preview(id, expr, streamId: widget.streamId),
          _repo
              .usages(id, streamId: widget.streamId)
              .catchError((Object _) => <String, dynamic>{}),
        ]);
        if (!mounted) return;
        final ok = await confirmVariableImpact(
          context,
          variable: v,
          preview: results[0],
          usages: usagesFromJson(results[1]['usages']),
          variableUnits: _unitsByName,
        );
        if (!mounted) return;
        if (!ok) {
          setState(() => _busy = false);
          return _cancelEdit();
        }
      }
      await _repo.update(
        id,
        streamId: widget.streamId,
        expr: expr,
        version: v.version,
      );
      await _refresh(values: v.usageCount > 0);
      if (!mounted) return;
      _closeEdit();
      _offerUndo('Updated ${v.name}', () async {
        await _repo.update(
          id,
          streamId: widget.streamId,
          expr: old,
          version: _find(id)?.version,
        );
        await _refresh(values: true);
      });
    } catch (e) {
      if (mounted) setState(() => _editError = variableWriteError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- the add row ----

  List<String> get _names => [for (final v in _list) v.name];

  String? _newNameProblem(String n) =>
      n.trim().isEmpty ? null : variableNameProblem(n, _names);

  Future<void> _create() async {
    if (_busy) return;
    final name = _newName.text.trim();
    final problem = variableNameProblem(name, _names);
    if (problem != null) {
      setState(() => _newError = problem);
      _newNameFocus.requestFocus();
      return;
    }
    final f = _newValue.formula;
    final expr = _exprOf(f);
    if (expr == null || f.message != null) {
      setState(() => _newError = f.message ?? 'Enter a value');
      _newValueFocus.requestFocus();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _newError = null;
      _clearUndo();
    });
    try {
      final v = await _repo.create(
        streamId: widget.streamId,
        name: name,
        expr: expr,
        unit: _newUnit,
      );
      await _refresh();
      if (!mounted) return;
      setState(() {
        _lastCreated = v.name;
        _newName.clear();
        _newValue.clear();
        _newError = null;
      });
      _newNameFocus.requestFocus();
      _revealRow(v.id);
    } catch (e) {
      if (mounted) setState(() => _newError = variableWriteError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- the ⋮ menu ----

  Future<void> _patch(
    Variable v, {
    String? unit,
    String? description,
    int? displayDecimals,
  }) => _run(() async {
    await _repo.update(
      v.id,
      streamId: widget.streamId,
      unit: unit,
      description: description,
      displayDecimals: displayDecimals,
      version: v.version,
    );
    await _refresh();
  });

  Future<void> _editDescription(Variable v) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _DescriptionDialog(name: v.name, initial: v.description),
    );
    if (text == null || !mounted) return;
    if (text == (v.description ?? '')) return;
    // '' clears it (the server stores null).
    await _patch(v, description: text);
  }

  Future<void> _showUses(Variable v, {bool blocking = false}) async {
    final picked = await showVariableUsages(
      context,
      repository: _repo,
      variableId: v.id,
      name: v.name,
      streamId: widget.streamId,
      title: blocking ? '${v.name} is in use' : null,
      message: blocking ? 'Change these fields first, then delete it.' : null,
      isKnown: _isKnown,
      variableUnits: _unitsByName,
    );
    if (picked != null && mounted) _open(picked);
  }

  Future<void> _showAttention() async {
    final picked = await showVariableAttention(
      context,
      repository: _repo,
      streamId: widget.streamId,
      isKnown: _isKnown,
    );
    if (picked != null && mounted) _open(picked);
  }

  bool _isKnown(String lower) =>
      _list.any((v) => v.name.toLowerCase() == lower);

  /// A usages / attention row: a variable jumps to its row (its value
  /// opens when it needs fixing); a field goes to its stream's timeline,
  /// opening the event.
  void _open(VariableUsage u) {
    if (u.entity == 'variable') {
      final v = _find(u.entityId);
      if (v == null) return;
      _jumpTo(v.id);
      if (u.error != null && _owner) _startEdit(v, _Edit.value);
      return;
    }
    final stream = u.streamId;
    final router = GoRouter.maybeOf(context);
    if (stream == null || router == null) return;
    Navigator.of(context).pop(_lastCreated);
    router.go(
      u.isEvent
          ? '/streams/$stream/timeline?event=${Uri.encodeQueryComponent(u.entityId)}'
          : '/streams/$stream/timeline',
    );
  }

  Future<void> _delete(Variable v) async {
    if (v.usageCount > 0) return _showUses(v, blocking: true);
    final ok = await showConfirmDialog(
      context,
      title: 'Delete ${v.name}?',
      message: 'No field uses it. You can undo this right after.',
    );
    if (!ok || !mounted) return;
    final done = await _run(() async {
      await _repo.delete(v.id, streamId: widget.streamId);
      await _refresh();
    });
    if (!done) {
      // Someone started using it meanwhile: show where.
      if (mounted && _error != null) {
        final fresh = _find(v.id);
        if (fresh != null && fresh.usageCount > 0) {
          setState(() => _error = null);
          await _showUses(fresh, blocking: true);
        }
      }
      return;
    }
    _offerUndo('Deleted ${v.name}', () async {
      await _repo.create(
        streamId: widget.streamId,
        name: v.name,
        expr: v.expr,
        unit: v.unit,
        description: v.description,
        displayDecimals: v.displayDecimals,
      );
      await _refresh();
    });
  }

  // ---- layout ----

  static const double _unitWidth = 40;
  static const double _usesWidth = 48;
  static const double _menuWidth = 40;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final async = _watchList();
    final list = sortedVariables(async.valueOrNull ?? const <Variable>[]);
    // Live updates: an edit of a row that went away closes.
    final id = _editingId;
    if (id != null && async.hasValue && !list.any((v) => v.id == id)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _editingId == id && _find(id) == null) {
          _cancelEdit(because: 'This variable was deleted');
        }
      });
    }
    final owner = _owner;
    final narrow = MediaQuery.sizeOf(context).width < 420;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: AppTheme.textMuted,
    );
    final attention =
        ((ref.watch(variableAttentionProvider(widget.streamId)).valueOrNull ??
                    const {})['count']
                as num?)
            ?.toInt() ??
        0;
    return Actions(
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            _dismiss();
            return null;
          },
        ),
      },
      child: FocusScope(
        node: _scope,
        child: _body(theme, async, list, owner, narrow, muted, attention),
      ),
    );
  }

  String get _description {
    final role = _role;
    if (role == null || role.isOwner) {
      return 'Shared by all your streams. Use them in any amount or number '
          'field by typing its name. Anyone you share a stream with can see '
          'these names and values.';
    }
    if (role.canEdit) {
      return 'The owner\'s variables, shared by all their streams. You can '
          'use them in formulas; only the owner changes them.';
    }
    return 'View only: you have viewer access. These are the owner\'s '
        'variables.';
  }

  Widget _body(
    ThemeData theme,
    AsyncValue<List<Variable>> async,
    List<Variable> list,
    bool owner,
    bool narrow,
    TextStyle? muted,
    int attention,
  ) {
    return Padding(
      key: const ValueKey('variables-manager'),
      padding: EdgeInsets.fromLTRB(narrow ? 12 : 20, 14, narrow ? 4 : 10, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.data_object, size: 20, color: AppTheme.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Variables', style: theme.textTheme.titleLarge),
              ),
              IconButton(
                key: const ValueKey('variables-close'),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(_lastCreated),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 10),
            child: Text(
              _description,
              key: const ValueKey('variables-description'),
              style: muted,
            ),
          ),
          if (attention > 0)
            Padding(
              padding: const EdgeInsets.only(right: 6, bottom: 10),
              child: _attentionBanner(theme, attention),
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
                      'Couldn\'t load variables: ${friendlyError(async.error!)}',
                    ),
                  ),
                  TextButton(
                    onPressed: () => widget.streamId == null
                        ? ref.invalidate(myVariablesProvider)
                        : ref.invalidate(variablesProvider(widget.streamId!)),
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
                  key: const ValueKey('variables-table'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _headerRow(muted, owner, narrow),
                    const Divider(height: 1),
                    if (list.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Text(
                          owner
                              ? 'No variables yet. Add one below, e.g. '
                                    'rent = 1200.'
                              : 'The owner has no variables yet.',
                          key: const ValueKey('variables-empty'),
                          style: muted,
                        ),
                      ),
                    for (final v in list) ...[
                      _row(v, owner, narrow),
                      const Divider(height: 1),
                    ],
                  ],
                ),
              ),
            ),
          if (owner && async.valueOrNull != null)
            Padding(
              key: const ValueKey('variable-new-footer'),
              padding: const EdgeInsets.only(top: 10, right: 6),
              child: _newRow(narrow),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 10),
              child: Text(
                _error!,
                key: const ValueKey('variables-error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (_undo != null)
            Padding(
              padding: const EdgeInsets.only(top: 12, right: 10),
              child: Container(
                key: const ValueKey('variable-undo'),
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
                      key: const ValueKey('variable-undo-button'),
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

  Widget _attentionBanner(ThemeData theme, int n) {
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        key: const ValueKey('variables-attention'),
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        decoration: BoxDecoration(
          color: AppTheme.warning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.warning.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              size: 20,
              color: AppTheme.warning,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${n == 1 ? '1 field needs' : '$n fields need'} attention: '
                '${n == 1 ? 'its formula no longer works. It keeps its' : 'their formulas no longer work. They keep their'} '
                'last value until fixed.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            TextButton(
              key: const ValueKey('variables-attention-show'),
              onPressed: _showAttention,
              child: const Text('Show'),
            ),
          ],
        ),
      ),
    );
  }

  double _valueWidth(bool narrow) => narrow ? 104 : 140;

  Widget _headerRow(TextStyle? style, bool owner, bool narrow) {
    final s = style?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.5);
    Widget right(String t, double w, {String? tip, bool center = false}) {
      final Widget cell = SizedBox(
        width: w,
        child: Align(
          alignment: center ? Alignment.center : Alignment.centerRight,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(t, style: s, maxLines: 1),
          ),
        ),
      );
      return tip == null ? cell : Tooltip(message: tip, child: cell);
    }

    return Padding(
      key: const ValueKey('variables-header'),
      padding: const EdgeInsets.only(bottom: 4, top: 4),
      child: Row(
        children: [
          const SizedBox(width: 8),
          Expanded(child: Text('NAME', style: s)),
          right('VALUE', _valueWidth(narrow)),
          if (!narrow) right('UNIT', _unitWidth, center: true),
          right('USES', _usesWidth, tip: 'Fields that use this in all streams'),
          if (owner) const SizedBox(width: _menuWidth),
        ],
      ),
    );
  }

  VariableValue _vv(Variable v) =>
      VariableValue(v.name, v.value, _unitOf(v.unit));

  String _formatted(Variable v) => formatVariableValue(
    _vv(v),
    decimals: v.displayDecimals ?? defaultVariableDecimals(v.unit),
  );

  static bool _isFormula(Variable v) => Decimal.tryParse(v.expr.trim()) == null;

  Widget _badge(String unit) {
    final u = _unitOf(unit);
    return Tooltip(
      message: _unitNames[unit] ?? 'Number',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppTheme.border),
        ),
        child: Text(
          unitBadge(u),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppTheme.textMuted,
          ),
        ),
      ),
    );
  }

  Widget _token(String name, TextStyle? base) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    decoration: BoxDecoration(
      color: FormulaStyle.knownBackground,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: base?.copyWith(
        color: FormulaStyle.known,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _row(Variable v, bool owner, bool narrow) {
    final theme = Theme.of(context);
    final b = _button;
    final editingName = owner && _editingId == v.id && _editing == _Edit.name;
    final editingValue = owner && _editingId == v.id && _editing == _Edit.value;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: AppTheme.textMuted,
    );
    final uses = v.usageCount;
    final usesText = uses == 1 ? 'used by 1 field' : 'used by $uses fields';

    final Widget name = editingName
        ? CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _dismiss,
            },
            child: TextField(
              key: ValueKey('variable-name-field-${v.id}'),
              controller: _editName,
              focusNode: _editNameFocus,
              maxLength: maxVariableNameLength,
              autocorrect: false,
              enableSuggestions: false,
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
                  key: ValueKey('variable-name-save-${v.id}'),
                  tooltip: 'Save name',
                  padding: EdgeInsets.zero,
                  iconSize: 20,
                  onPressed: _busy ? null : _commitName,
                  icon: const Icon(Icons.check_rounded, color: AppTheme.accent),
                ),
              ),
              onChanged: (t) {
                if (_editError != null) {
                  setState(
                    () => _editError = variableNameProblem(
                      t,
                      _names,
                      self: v.name,
                    ),
                  );
                }
              },
              onSubmitted: (_) => _commitName(),
              onEditingComplete: () {},
              onTapOutside: (_) => _editNameFocus.unfocus(),
            ),
          )
        : Semantics(
            label:
                'Variable ${v.name}, value ${spokenVariableValue(_vv(v))}, '
                '$usesText',
            button: owner,
            excludeSemantics: true,
            child: InkWell(
              key: ValueKey('variable-name-${v.id}'),
              borderRadius: BorderRadius.circular(6),
              onTap: owner && !_busy ? () => _startEdit(v, _Edit.name) : null,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: b),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Tooltip(
                    message: v.description == null
                        ? v.name
                        : '${v.name}: ${v.description}',
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _token(v.name, theme.textTheme.bodyMedium),
                        if (v.description != null &&
                            v.description!.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              v.description!,
                              key: ValueKey('variable-description-${v.id}'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: muted,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );

    final Widget row;
    if (editingValue) {
      row = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 2, child: name),
          const SizedBox(width: 6),
          Expanded(
            flex: 3,
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): _dismiss,
              },
              child: KeyedSubtree(
                key: _editValueKey,
                child: FormulaField(
                  key: ValueKey('variable-value-field-${v.id}'),
                  spec: fieldSpecs['variable.value']!,
                  scope: _fieldScope(),
                  formulasEnabled: true,
                  controller: _editValue,
                  focusNode: _editValueFocus,
                  dense: true,
                  hintText: '0',
                  onSubmitted: (_) => _commitValue(),
                ),
              ),
            ),
          ),
          IconButton(
            key: ValueKey('variable-value-save-${v.id}'),
            tooltip: 'Save value',
            padding: EdgeInsets.zero,
            constraints: BoxConstraints.tightFor(width: b, height: b + 8),
            iconSize: 20,
            onPressed: _busy ? null : _commitValue,
            icon: const Icon(Icons.check_rounded, color: AppTheme.accent),
          ),
        ],
      );
    } else {
      row = Row(
        crossAxisAlignment: editingName
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          Expanded(child: name),
          _valueCell(v, owner, narrow, theme, muted),
          if (!narrow)
            SizedBox(
              width: _unitWidth,
              height: b,
              child: Center(child: _badge(v.unit)),
            ),
          SizedBox(
            width: _usesWidth,
            height: b,
            child: Tooltip(
              message: 'Fields that use this in all streams',
              child: InkWell(
                key: ValueKey('variable-uses-${v.id}'),
                borderRadius: BorderRadius.circular(6),
                onTap: () => _showUses(v),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      '$uses',
                      semanticsLabel: '$usesText in all streams',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppTheme.textMuted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (owner) _menu(v),
        ],
      );
    }
    final flash = _flashId == v.id;
    return Semantics(
      key: _rowKeys.putIfAbsent(v.id, GlobalKey.new),
      container: true,
      explicitChildNodes: true,
      child: AnimatedContainer(
        key: ValueKey('variable-row-${v.id}'),
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: flash ? AppTheme.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            row,
            if (editingValue &&
                _editError != null &&
                _editError != _editValue.formula.message)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 8),
                child: Text(
                  _editError!,
                  key: const ValueKey('variable-value-error'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _valueCell(
    Variable v,
    bool owner,
    bool narrow,
    ThemeData theme,
    TextStyle? muted,
  ) {
    final problem = v.problem;
    final formula = _isFormula(v);
    final base = theme.textTheme.bodyMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final valueStyle = problem == null
        ? base
        : base?.copyWith(
            color: AppTheme.warning,
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.wavy,
            decorationColor: AppTheme.warning,
          );
    Widget value = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (formula)
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: Text(
              '✦',
              style: TextStyle(fontSize: 11, color: AppTheme.accent),
            ),
          ),
        Flexible(
          child: Text(
            _formatted(v),
            key: ValueKey('variable-value-${v.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: valueStyle,
          ),
        ),
        if (narrow) ...[const SizedBox(width: 4), _badge(v.unit)],
      ],
    );
    if (problem != null) {
      value = Tooltip(
        key: ValueKey('variable-problem-${v.id}'),
        message: '${problem['message'] ?? 'This formula no longer works'}',
        child: value,
      );
    }
    return SizedBox(
      width: _valueWidth(narrow),
      child: InkWell(
        key: ValueKey('variable-value-cell-${v.id}'),
        borderRadius: BorderRadius.circular(6),
        onTap: owner && !_busy ? () => _startEdit(v, _Edit.value) : null,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: _button),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                value,
                if (formula)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      v.expr,
                      key: ValueKey('variable-expr-${v.id}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted?.copyWith(color: AppTheme.textFaint),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The manager's own fields resolve against the same set; they never
  /// offer "Manage variables…" (we're in it).
  VariableScope _fieldScope() {
    final async = widget.streamId == null
        ? ref.watch(myVariablesProvider)
        : ref.watch(variablesProvider(widget.streamId!));
    return VariableScope.fromVariables(
      async.valueOrNull ?? const [],
      streamId: widget.streamId,
      loading: async.isLoading && !async.hasValue,
    );
  }

  Widget _menu(Variable v) {
    final current = v.displayDecimals ?? defaultVariableDecimals(v.unit);
    Widget check(bool on) => SizedBox(
      width: 20,
      child: on
          ? const Icon(Icons.check_rounded, size: 18, color: AppTheme.accent)
          : null,
    );
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          key: const ValueKey('variable-menu-description'),
          leadingIcon: const Icon(Icons.notes_rounded, size: 18),
          onPressed: () => _editDescription(v),
          child: const Text('Description…'),
        ),
        SubmenuButton(
          key: const ValueKey('variable-menu-unit'),
          leadingIcon: const Icon(Icons.straighten_rounded, size: 18),
          menuChildren: [
            for (final u in _units)
              MenuItemButton(
                key: ValueKey('variable-unit-$u'),
                leadingIcon: check(v.unit == u),
                onPressed: v.unit == u ? null : () => _patch(v, unit: u),
                child: Text('${_unitNames[u]} (${unitBadge(_unitOf(u))})'),
              ),
          ],
          child: const Text('Unit'),
        ),
        SubmenuButton(
          key: const ValueKey('variable-menu-decimals'),
          leadingIcon: const Icon(Icons.pin_outlined, size: 18),
          menuChildren: [
            // Not settable back once a precision is chosen (the API keeps
            // the field unless given one), so it only shows the default.
            if (defaultVariableDecimals(v.unit) == null)
              MenuItemButton(
                key: const ValueKey('variable-decimals-auto'),
                leadingIcon: check(current == null),
                onPressed: null,
                child: const Text('As written (default)'),
              ),
            for (var d = 0; d <= 6; d++)
              MenuItemButton(
                key: ValueKey('variable-decimals-$d'),
                leadingIcon: check(current == d),
                onPressed: current == d
                    ? null
                    : () => _patch(v, displayDecimals: d),
                child: Text(
                  d == defaultVariableDecimals(v.unit) ? '$d (default)' : '$d',
                ),
              ),
          ],
          child: const Text('Decimals'),
        ),
        MenuItemButton(
          key: const ValueKey('variable-menu-uses'),
          leadingIcon: const Icon(Icons.manage_search_rounded, size: 18),
          onPressed: () => _showUses(v),
          child: const Text('Show uses'),
        ),
        MenuItemButton(
          key: const ValueKey('variable-menu-delete'),
          leadingIcon: Icon(
            Icons.delete_outline_rounded,
            size: 18,
            color: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => _delete(v),
          child: Text(
            'Delete',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        key: ValueKey('variable-menu-${v.id}'),
        tooltip: 'More for ${v.name}',
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tightFor(
          width: _menuWidth,
          height: _button,
        ),
        iconSize: 20,
        onPressed: _busy
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.more_vert_rounded),
      ),
    );
  }

  Widget _newRow(bool narrow) {
    final theme = Theme.of(context);
    final b = _button;
    final nameField = TextField(
      key: const ValueKey('variable-new-name'),
      controller: _newName,
      focusNode: _newNameFocus,
      maxLength: maxVariableNameLength,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: TextInputAction.next,
      decoration: const InputDecoration(
        hintText: 'name',
        isDense: true,
        counterText: '',
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      ),
      onChanged: (t) => setState(() => _newError = _newNameProblem(t)),
      onSubmitted: (_) => _create(),
    );
    final valueField = FormulaField(
      key: const ValueKey('variable-new-value'),
      spec: fieldSpecs['variable.value']!,
      scope: _fieldScope(),
      formulasEnabled: true,
      controller: _newValue,
      focusNode: _newValueFocus,
      dense: true,
      hintText: 'value',
      allowEmpty: true,
      onSubmitted: (_) => _create(),
    );
    final unit = PopupMenuButton<String>(
      key: const ValueKey('variable-new-unit'),
      tooltip: 'Unit: ${_unitNames[_newUnit]}',
      initialValue: _newUnit,
      onSelected: (u) => setState(() => _newUnit = u),
      itemBuilder: (_) => [
        for (final u in _units)
          PopupMenuItem(
            key: ValueKey('variable-new-unit-$u'),
            value: u,
            child: Text('${_unitNames[u]} (${unitBadge(_unitOf(u))})'),
          ),
      ],
      child: SizedBox(
        width: b,
        height: b,
        child: Center(child: _badge(_newUnit)),
      ),
    );
    final add = IconButton(
      key: const ValueKey('variable-new-add'),
      tooltip: 'Add variable',
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: b, height: b),
      onPressed: _busy ? null : _create,
      icon: const Icon(Icons.add_rounded),
      color: AppTheme.accent,
    );
    final sign = theme.textTheme.titleMedium?.copyWith(
      color: AppTheme.textMuted,
    );
    Widget top(Widget child) =>
        Padding(padding: const EdgeInsets.only(top: 8), child: child);
    final Widget content = narrow
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: nameField),
                  SizedBox(
                    width: 24,
                    child: Center(child: Text('=', style: sign)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: valueField),
                  top(unit),
                  top(add),
                ],
              ),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 2, child: top(nameField)),
              top(
                SizedBox(
                  width: 24,
                  height: b,
                  child: Center(child: Text('=', style: sign)),
                ),
              ),
              Expanded(flex: 3, child: valueField),
              top(unit),
              top(add),
            ],
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CustomPaint(
          key: const ValueKey('variable-new-row'),
          painter: _DashedPillPainter(color: AppTheme.textFaint, radius: 10),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 2, 8),
            child: content,
          ),
        ),
        if (_newError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              _newError!,
              key: const ValueKey('variable-new-error'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}

class _DescriptionDialog extends StatefulWidget {
  const _DescriptionDialog({required this.name, this.initial});
  final String name;
  final String? initial;

  @override
  State<_DescriptionDialog> createState() => _DescriptionDialogState();
}

class _DescriptionDialogState extends State<_DescriptionDialog> {
  late final _text = TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop(_text.text.trim());

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Describe ${widget.name}'),
    content: SizedBox(
      width: 360,
      child: TextField(
        key: const ValueKey('variable-description-field'),
        controller: _text,
        autofocus: true,
        maxLength: 200,
        maxLines: 3,
        minLines: 1,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          hintText: 'e.g. Weekly rent, Glebe flat',
        ),
        onSubmitted: (_) => _save(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('variable-description-save'),
        onPressed: _save,
        child: const Text('Save'),
      ),
    ],
  );
}

/// The categories manager's dashed outline (same dash, colour and radius).
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
        canvas.drawPath(m.extractPath(d, (d + 6).clamp(0, m.length)), paint);
        d += 10;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedPillPainter old) =>
      old.color != color || old.radius != radius;
}
