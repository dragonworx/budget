// FormulaField (spec 011): the numeric input every amount, rate and count
// will use. Plain numbers behave exactly as today; formulas (grammar v1)
// are styled, previewed and validated live, with `$` autocomplete.
import 'dart:async';
import 'dart:math' as math;

import 'package:budget_formula/budget_formula.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../boot/page_stub.dart'
    if (dart.library.js_interop) '../../boot/page_web.dart';
import '../../data/models.dart';
import '../../theme/app_theme.dart';
import 'formula_cheat_sheet.dart';
import 'formula_controller.dart';
import 'formula_keys_row.dart';
import 'formula_style.dart';
import 'formula_suggestions.dart';
import 'variable_scope.dart';

export 'formula_controller.dart' show FormulaEditingController, FormulaValue;
export 'variable_scope.dart';

class FormulaField extends StatefulWidget {
  const FormulaField({
    super.key,
    required this.spec,
    this.legacyFormatters = const [],
    this.legacyKeyboardType = const TextInputType.numberWithOptions(
      decimal: true,
    ),
    required this.scope,
    this.controller,
    this.focusNode,
    this.label,
    this.prefixText,
    this.suffixText,
    this.hintText,
    this.helperText,
    this.autofocus = false,
    this.enabled = true,
    this.readOnly = false,
    this.allowEmpty = false,
    this.extraValidator,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction = TextInputAction.done,
    this.dense = false,
    this.textAlign = TextAlign.start,
    this.autovalidateMode = AutovalidateMode.onUserInteraction,
    this.formulasEnabled,
    this.touchMode,
  });

  /// Range, scale, unit, today's parser and messages.
  final FieldSpec spec;

  /// Today's input formatters; applied only while formulas are off.
  final List<TextInputFormatter> legacyFormatters;

  /// Today's keyboard; used only while formulas are off.
  final TextInputType legacyKeyboardType;
  final VariableScope scope;
  final FormulaEditingController? controller;
  final FocusNode? focusNode;
  final String? label, prefixText, suffixText, hintText, helperText;
  final bool autofocus, enabled, readOnly;

  /// Empty means the spec's empty value (e.g. a threshold of 0).
  final bool allowEmpty;

  /// Field-specific checks after resolution.
  final String? Function(FormulaValue value)? extraValidator;
  final ValueChanged<FormulaValue>? onChanged;

  /// Enter / keyboard Done, only when no suggestion list is open.
  final ValueChanged<FormulaValue>? onSubmitted;
  final TextInputAction textInputAction;
  final bool dense;
  final TextAlign textAlign;
  final AutovalidateMode autovalidateMode;

  /// Null: `features.variables`.
  final bool? formulasEnabled;

  /// Null: iOS / Android. Forces the touch layout (operator row, picker
  /// dialog, 48 px rows) for tests and the demo.
  final bool? touchMode;

  @override
  State<FormulaField> createState() => _FormulaFieldState();
}

class _FormulaFieldState extends State<FormulaField> {
  FormulaEditingController? _ownController;
  FocusNode? _ownFocus;
  final _link = LayerLink();
  final _portal = OverlayPortalController();
  final _targetKey = GlobalKey();
  final _formKey = GlobalKey<FormFieldState<FormulaValue>>();
  final _scroll = ScrollController();

  CompletionContext? _ctx;
  List<VariableValue> _items = const [];
  int _hi = 0;
  bool _picker = false;
  CompletionContext? _pickerCtx;

  /// (text, caret) where the list was closed by Esc or an insertion: it
  /// stays closed until either changes.
  (String, int)? _quiet;

  /// Set for 400 ms after a key inserted a suggestion: the web engine
  /// also sends the keyboard action for that Enter.
  Timer? _swallowSubmit;

  /// Set for 400 ms after Esc closed the list (key repeat must not close
  /// the dialog too).
  Timer? _escGuard;
  bool _helpOpen = false;
  late String _lastText;
  int? _announced;

  FormulaEditingController get _c => widget.controller ?? _ownController!;
  FocusNode get _focus => widget.focusNode ?? _ownFocus!;
  bool get _formulas => widget.formulasEnabled ?? ServerFeatures.variables;
  bool get _touch =>
      widget.touchMode ??
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android ||
          coarsePointer);
  bool get _open => _portal.isShowing;
  String get _keyBase {
    final k = widget.key;
    return k is ValueKey<String> ? k.value : 'formula';
  }

  FieldSpec get _spec => widget.allowEmpty && !widget.spec.allowEmpty
      ? FieldSpec(
          id: widget.spec.id,
          unit: widget.spec.unit,
          scale: widget.spec.scale,
          legacyParse: widget.spec.legacyParse,
          min: widget.spec.min,
          minExclusive: widget.spec.minExclusive,
          max: widget.spec.max,
          signed: widget.spec.signed,
          formulaMax: widget.spec.formulaMax,
          checkPlainRange: widget.spec.checkPlainRange,
          allowEmpty: true,
          emptyValue: widget.spec.emptyValue ?? Decimal.zero,
          messages: widget.spec.messages,
        )
      : widget.spec;
  FieldSpec? _specCache;
  FieldSpec? _specFor;

  FieldSpec get _effectiveSpec {
    if (_specCache == null || !identical(_specFor, widget.spec)) {
      _specFor = widget.spec;
      _specCache = _spec;
    }
    return _specCache!;
  }

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) _ownController = FormulaEditingController();
    if (widget.focusNode == null) _ownFocus = FocusNode(debugLabel: 'formula');
    _configure();
    _c.addListener(_onValue);
    _focus.addListener(_onFocus);
    _lastText = _c.text;
  }

  /// The widget's settings win when they change (a new scope from the
  /// provider, i.e. a live hint); a scope set on the controller directly
  /// stays until then.
  void _configure({bool scope = true}) => _c.configure(
    spec: _effectiveSpec,
    scope: scope ? widget.scope : null,
    formulasEnabled: _formulas,
    notify: false,
  );

  @override
  void didUpdateWidget(FormulaField old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      (old.controller ?? _ownController)?.removeListener(_onValue);
      if (widget.controller == null) {
        _ownController ??= FormulaEditingController(text: old.controller?.text);
      } else {
        _ownController?.dispose();
        _ownController = null;
      }
      _c.addListener(_onValue);
      _lastText = _c.text;
    }
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _ownFocus)?.removeListener(_onFocus);
      if (widget.focusNode == null) {
        _ownFocus ??= FocusNode(debugLabel: 'formula');
      } else {
        _ownFocus?.dispose();
        _ownFocus = null;
      }
      _focus.addListener(_onFocus);
    }
    _configure(
      scope:
          old.controller != widget.controller ||
          !identical(old.scope, widget.scope),
    );
    if (_open) {
      // New variables (live hint): refresh the list after this frame.
      SchedulerBinding.instance.addPostFrameCallback((_) => _sync());
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onValue);
    _focus.removeListener(_onFocus);
    _ownController?.dispose();
    _ownFocus?.dispose();
    _scroll.dispose();
    _swallowSubmit?.cancel();
    _escGuard?.cancel();
    super.dispose();
  }

  // --- state sync -------------------------------------------------------

  void _onFocus() {
    if (!mounted) return;
    if (!_focus.hasFocus) {
      _close();
    } else {
      _sync();
    }
    _rebuild();
  }

  void _onValue() {
    final t = _c.text;
    if (t != _lastText) {
      _lastText = t;
      _picker = false;
    }
    _sync();
    // Scope (live hint) or server flag changes keep the text: redraw the
    // line under the field too; a flag shows at once.
    _rebuild();
    if (_c.formula.flagged) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _formKey.currentState?.validate();
      });
    }
  }

  void _rebuild() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _rebuild());
      return;
    }
    setState(() {});
  }

  void _sync() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _sync());
      return;
    }
    final can =
        _formulas && _focus.hasFocus && widget.enabled && !widget.readOnly;
    final t = _c.text;
    final sel = _c.selection;
    final caret = sel.isValid ? sel.baseOffset : t.length;
    if (_quiet != null && _quiet != (t, caret)) _quiet = null;
    CompletionContext? ctx;
    if (can && _picker) {
      ctx = _pickerCtx;
    } else if (can && sel.isValid && sel.isCollapsed && _quiet == null) {
      ctx = completionAt(t, caret);
    }
    if (ctx == null) {
      _close();
      return;
    }
    final items = rankCompletions(ctx.prefix, _c.scope.variables);
    final moved =
        _ctx?.prefix != ctx.prefix || _ctx?.replaceStart != ctx.replaceStart;
    setState(() {
      _ctx = ctx;
      _items = items;
      if (moved || _hi >= items.length) _hi = 0;
    });
    if (!_portal.isShowing) _portal.show();
    if (moved && _scroll.hasClients) _scroll.jumpTo(0);
    if (_announced != items.length) {
      _announced = items.length;
      final n = items.length;
      SemanticsService.sendAnnouncement(
        View.of(context),
        n == 0
            ? 'No variable suggestions'
            : '$n variable ${n == 1 ? 'suggestion' : 'suggestions'}',
        TextDirection.ltr,
      );
    }
  }

  void _close({bool quiet = false}) {
    if (quiet) {
      final sel = _c.selection;
      _quiet = (_c.text, sel.isValid ? sel.baseOffset : _c.text.length);
    }
    _picker = false;
    _announced = null;
    if (_portal.isShowing) {
      _portal.hide();
      if (mounted) setState(() => _ctx = null);
    } else {
      _ctx = null;
    }
  }

  void _changed() {
    final f = _c.formula;
    _formKey.currentState?.didChange(f);
    widget.onChanged?.call(f);
  }

  // --- editing ------------------------------------------------------------

  void _insert(VariableValue v) => _insertName(v.name);

  void _insertName(String name) {
    final ctx = _ctx;
    if (ctx == null) return;
    final t = _c.text;
    final rep = '\$$name';
    final start = ctx.replaceStart.clamp(0, t.length);
    final end = ctx.replaceEnd.clamp(start, t.length);
    final next = t.replaceRange(start, end, rep);
    final caret = start + rep.length;
    _picker = false;
    _quiet = (next, caret);
    _c.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: caret),
    );
    _close(quiet: true);
    _changed();
    if (!_focus.hasFocus) _focus.requestFocus();
  }

  void _type(String s) {
    final t = _c.text;
    final sel = _c.selection.isValid
        ? _c.selection
        : TextSelection.collapsed(offset: t.length);
    final next = t.replaceRange(sel.start, sel.end, s);
    _c.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: sel.start + s.length),
    );
    _changed();
    if (!_focus.hasFocus) _focus.requestFocus();
  }

  /// Opens the manager (owner, 012); a variable created there replaces the
  /// `$…` being typed ([createName] prefills its add row).
  Future<void> _openManager({String? createName, CompletionContext? at}) async {
    final open = _c.scope.manage;
    if (open == null) return;
    final ctx = at ?? _ctx;
    _close(quiet: true);
    final name = await open(context, createName: createName);
    if (!mounted || name == null || ctx == null) return;
    _ctx = ctx;
    _insertName(name);
  }

  Future<void> _openPicker() async {
    final t = _c.text;
    final sel = _c.selection.isValid
        ? _c.selection
        : TextSelection.collapsed(offset: t.length);
    final token = sel.isCollapsed ? completionAt(t, sel.baseOffset) : null;
    final ctx = token ?? CompletionContext(sel.start, sel.end, '');
    if (_touch) {
      final v = await showVariablePicker(
        context,
        scope: _c.scope,
        onManage: _c.scope.offersManage
            ? (name) => _openManager(createName: name, at: ctx)
            : null,
      );
      if (!mounted || v == null) return;
      _ctx = ctx;
      _insert(v);
      return;
    }
    _pickerCtx = ctx;
    _picker = true;
    _quiet = null;
    if (!_focus.hasFocus) {
      _focus.requestFocus();
      _c.selection = sel;
    }
    _sync();
  }

  void _move(int d) {
    final n = _items.length;
    if (n == 0) return;
    setState(() => _hi = (_hi + d) % n < 0 ? n - 1 : (_hi + d) % n);
    if (_scroll.hasClients) {
      final rowH = _touch ? suggestionRowTouch : suggestionRowDesktop;
      final top = 4 + _hi * rowH;
      final view = _scroll.position.viewportDimension;
      if (top < _scroll.offset) {
        _scroll.jumpTo(top - 4);
      } else if (top + rowH > _scroll.offset + view) {
        _scroll.jumpTo(top + rowH + 4 - view);
      }
    }
  }

  void _accept() {
    if (_items.isEmpty) {
      _close(quiet: true);
      return;
    }
    _armSwallow();
    _insert(_items[_hi.clamp(0, _items.length - 1)]);
  }

  void _armSwallow() {
    _swallowSubmit?.cancel();
    _swallowSubmit = Timer(const Duration(milliseconds: 400), () {
      _swallowSubmit = null;
    });
  }

  /// Consumes the pending swallow, if any.
  bool _swallowed() {
    final t = _swallowSubmit;
    if (t == null) return false;
    t.cancel();
    _swallowSubmit = null;
    return true;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (!_open) {
      // Key repeat right after Esc closed the list: don't close the dialog.
      if (k == LogicalKeyboardKey.escape && _escGuard != null) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      _move(1);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _move(-1);
    } else if (e is KeyRepeatEvent) {
      return KeyEventResult.ignored;
    } else if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.tab) {
      _accept();
    } else if (k == LogicalKeyboardKey.escape) {
      _escGuard?.cancel();
      _escGuard = Timer(const Duration(milliseconds: 400), () {
        _escGuard = null;
      });
      _close(quiet: true);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Formulas on: Enter / Done while the list is open inserts instead.
  void _onEditingComplete() {
    if (_open) {
      _accept();
      _armSwallow();
      return;
    }
    if (_swallowSubmit != null) return;
    _c.clearComposing();
    switch (widget.textInputAction) {
      case TextInputAction.next:
        _focus.nextFocus();
      case TextInputAction.previous:
        _focus.previousFocus();
      default:
        _focus.unfocus();
    }
  }

  void _onSubmitted(String _) {
    if (_formulas && _swallowed()) return;
    widget.onSubmitted?.call(_c.formula);
  }

  String? _validate(FormulaValue? _) {
    final f = _c.formula;
    if (f.message != null) return f.message;
    if (f.pending) return null;
    return widget.extraValidator?.call(f);
  }

  // --- build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    _configure(scope: false);
    return FormField<FormulaValue>(
      key: _formKey,
      initialValue: _c.formula,
      enabled: widget.enabled,
      autovalidateMode: widget.autovalidateMode,
      validator: _validate,
      builder: _buildField,
    );
  }

  Widget _buildField(FormFieldState<FormulaValue> field) {
    final context = field.context;
    final theme = Theme.of(context);
    final on = _formulas;
    final f = _c.formula;
    final editable = widget.enabled && !widget.readOnly;
    final focused = _focus.hasFocus;
    final scope = _c.scope;
    final showPicker =
        on && editable && (scope.variables.isNotEmpty || scope.canManage);
    final showHelp =
        on &&
        editable &&
        (focused || _helpOpen || (!_touch && _c.showsFormula));
    // While a name is being completed ("$r" with the list open) the
    // "no variable" error would flash under the list: it shows once the
    // list closes. The value stays invalid either way.
    final errorText = _open && f.isFormula && f.message != null
        ? null
        : field.errorText;
    final preview = on && _c.showsFormula && errorText == null
        ? (f.pending
              ? '…'
              : (f.value == null ? null : formatFieldValue(f.value!, _c.spec)))
        : null;

    Widget? helper;
    if (preview != null) {
      final primary = theme.colorScheme.primary;
      helper = Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Icon(Icons.auto_awesome, size: 14, color: primary),
            ),
            TextSpan(
              text: ' = $preview',
              style: TextStyle(
                color: primary,
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w700,
              ),
            ),
            for (final h in f.hints)
              TextSpan(
                text: '  ${h.message}',
                style: const TextStyle(color: AppTheme.textFaint),
              ),
          ],
        ),
        key: ValueKey('$_keyBase-preview'),
        style: theme.textTheme.bodySmall,
      );
    }

    final suffix = <Widget>[
      if (showPicker)
        IconButton(
          key: ValueKey('$_keyBase-var-picker'),
          tooltip: 'Insert a variable',
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          iconSize: 18,
          icon: const Icon(Icons.data_object),
          onPressed: _openPicker,
        ),
      if (showHelp)
        FormulaHelpButton(
          buttonKey: ValueKey('$_keyBase-help'),
          onManage: _c.scope.offersManage && editable
              ? () => _openManager()
              : null,
          onOpenChanged: (open) => setState(() => _helpOpen = open),
        ),
    ];

    // Touch: the operator row sits right under the field box and the line
    // under the field moves below it, so the keys don't jump as the
    // preview or error comes and goes (the border still turns red).
    final showKeys = on && editable && focused && _touch;
    final lineBelowKeys = showKeys && (helper != null || errorText != null);

    var decoration = InputDecoration(
      labelText: widget.label,
      prefixText: widget.prefixText,
      suffixText: widget.suffixText,
      hintText: widget.hintText,
      helperText: helper == null ? widget.helperText : null,
      helper: lineBelowKeys ? null : helper,
      helperMaxLines: helper == null ? null : 3,
      isDense: widget.dense ? true : null,
      suffixIcon: suffix.isEmpty
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: suffix),
    ).applyDefaults(InputDecorationTheme.of(context));
    Widget? lineUnderKeys;
    if (errorText != null) {
      decoration = lineBelowKeys
          ? decoration.copyWith(error: const SizedBox.shrink())
          : decoration.copyWith(errorText: errorText);
    }
    if (lineBelowKeys) {
      final pad =
          decoration.contentPadding?.resolve(Directionality.of(context)) ??
          const EdgeInsets.symmetric(horizontal: 12);
      lineUnderKeys = Padding(
        padding: EdgeInsets.fromLTRB(pad.left, 6, pad.right, 0),
        child: errorText != null
            ? Semantics(
                liveRegion: true,
                child: Text(
                  errorText,
                  key: ValueKey('$_keyBase-error'),
                  maxLines: decoration.errorMaxLines ?? 3,
                  overflow: TextOverflow.ellipsis,
                  style:
                      decoration.errorStyle ??
                      theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                ),
              )
            : helper,
      );
    }

    final label = widget.label;
    final semantics = preview != null && f.isFormula
        ? '${label == null ? '' : '$label, '}formula ${f.text}, equals $preview'
        : null;

    final textField = TextField(
      controller: _c,
      focusNode: _focus,
      decoration: decoration,
      keyboardType: on ? TextInputType.text : widget.legacyKeyboardType,
      textInputAction: widget.textInputAction,
      textAlign: widget.textAlign,
      autofocus: widget.autofocus,
      readOnly: widget.readOnly,
      enabled: widget.enabled,
      autocorrect: !on,
      enableSuggestions: !on,
      smartDashesType: on ? SmartDashesType.disabled : SmartDashesType.enabled,
      smartQuotesType: on ? SmartQuotesType.disabled : SmartQuotesType.enabled,
      enableIMEPersonalizedLearning: !on,
      inputFormatters: on || widget.legacyFormatters.isEmpty
          ? null
          : widget.legacyFormatters,
      onChanged: (_) => _changed(),
      onEditingComplete: on ? _onEditingComplete : null,
      onSubmitted: _onSubmitted,
    );

    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _overlay,
        child: Column(
          key: _targetKey,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _onKey,
              child: Semantics(label: semantics, child: textField),
            ),
            if (showKeys)
              FormulaKeysRow(
                keyPrefix: _keyBase,
                onKey: _type,
                onPicker: showPicker ? _openPicker : null,
              ),
            ?lineUnderKeys,
          ],
        ),
      ),
    );
  }

  Widget _overlay(BuildContext context) {
    final box = _targetKey.currentContext?.findRenderObject() as RenderBox?;
    final ctx = _ctx;
    if (box == null || !box.hasSize || !box.attached || ctx == null) {
      return const SizedBox.shrink();
    }
    final mq = MediaQuery.of(context);
    final screen = mq.size;
    final origin = box.localToGlobal(Offset.zero);
    final size = box.size;
    final rowH = _touch ? suggestionRowTouch : suggestionRowDesktop;
    final manage = _c.scope.offersManage;
    final action =
        _items.isEmpty &&
        emptyActionFor(
              _c.scope,
              ctx.prefix,
              onManage: manage ? () {} : null,
              onCreate: manage ? (_) {} : null,
            ) !=
            null;
    final rows = action
        ? 2
        : math.max(1, math.min(_items.length, suggestionMaxRows));
    final want = rows * rowH + 8;
    const gap = 4.0;
    final below =
        screen.height -
        mq.viewInsets.bottom -
        (origin.dy + size.height) -
        gap -
        8;
    final above = origin.dy - mq.padding.top - gap - 8;
    final flip = below < 260 && above > below;
    final avail = flip ? above : below;
    final height = math.min(want, math.max(rowH + 8, avail));
    final width = math.min(size.width.clamp(240.0, 420.0), screen.width - 16);
    var dx = 0.0;
    final overflow = origin.dx + width - (screen.width - 8);
    if (overflow > 0) dx = -overflow;
    if (origin.dx + dx < 8) dx = 8 - origin.dx;
    return CompositedTransformFollower(
      link: _link,
      showWhenUnlinked: false,
      targetAnchor: flip ? Alignment.topLeft : Alignment.bottomLeft,
      followerAnchor: flip ? Alignment.bottomLeft : Alignment.topLeft,
      offset: Offset(dx, flip ? -gap : gap),
      child: Align(
        alignment: flip ? Alignment.bottomLeft : Alignment.topLeft,
        child: TextFieldTapRegion(
          child: SizedBox(
            key: ValueKey(
              flip ? 'formula-suggestions-above' : 'formula-suggestions-below',
            ),
            width: width,
            child: FormulaSuggestionList(
              items: _items,
              prefix: ctx.prefix,
              highlighted: _hi,
              scope: _c.scope,
              rowHeight: rowH,
              maxHeight: height,
              scrollController: _scroll,
              onPick: _insert,
              onManage: manage ? () => _openManager() : null,
              onCreate: manage ? (n) => _openManager(createName: n) : null,
              onHover: (i) {
                if (i != _hi) setState(() => _hi = i);
              },
            ),
          ),
        ),
      ),
    );
  }
}
