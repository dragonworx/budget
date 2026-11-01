// The text controller behind FormulaField: resolves its text on every
// change and styles formula tokens without ever changing the text.
import 'package:budget_formula/budget_formula.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import 'formula_style.dart';
import 'variable_scope.dart';

/// What a formula field's text means; callers read this instead of
/// parsing the text.
class FormulaValue {
  const FormulaValue({
    required this.text,
    required this.isEmpty,
    required this.isPlain,
    required this.isFormula,
    this.value,
    this.expr,
    this.error,
    this.message,
    this.hints = const [],
    this.pending = false,
    this.flagged = false,
  });

  /// The raw text.
  final String text;
  final bool isEmpty, isPlain, isFormula;

  /// Resolved and rounded (plain: exactly today's parser's value).
  final Decimal? value;

  /// The canonical text to send as `<field>Expr`; null when plain.
  final String? expr;

  /// The first problem (with its span).
  final FormulaError? error;

  /// What the field shows under itself for [error] (null when valid or
  /// [pending]).
  final String? message;
  final List<FormulaHint> hints;

  /// Variables are still loading and the text uses one not yet known: not
  /// flagged, but not usable yet either ([value] is null).
  final bool pending;

  /// The server marked the stored formula broken and it hasn't changed.
  final bool flagged;

  bool get isValid => error == null && !pending && (value != null || isEmpty);

  int? get intValue {
    final v = value;
    if (v == null || !v.isInteger) return null;
    return v.toBigInt().toInt();
  }

  @override
  String toString() =>
      'FormulaValue("$text" ${isPlain ? 'plain' : (isFormula ? 'formula' : 'empty')}'
      ' value=$value expr=$expr message=$message pending=$pending)';
}

/// True when [text] has nothing that only a formula has (no `$name`,
/// operator or bracket): such text is validated exactly as today.
bool looksPlain(String text) {
  for (final t in tokenize(text)) {
    switch (t.kind) {
      case TokenKind.variable ||
          TokenKind.plus ||
          TokenKind.minus ||
          TokenKind.star ||
          TokenKind.slash ||
          TokenKind.lparen ||
          TokenKind.rparen:
        return false;
      default:
    }
  }
  return true;
}

class FormulaEditingController extends TextEditingController {
  FormulaEditingController({
    super.text,
    this._spec,
    VariableScope? scope,
    bool formulasEnabled = true,
  }) : _scope = scope ?? VariableScope.empty,
       _enabled = formulasEnabled;

  FieldSpec? _spec;
  VariableScope _scope;
  bool _enabled;
  String? _flagText;
  String? _flagMessage;

  FieldSpec get spec => _spec ?? fieldSpecs['event.amount']!;
  VariableScope get scope => _scope;
  bool get formulasEnabled => _enabled;

  /// Called by the field; [notify] false while the field is rebuilding
  /// anyway (it rebuilds the text with the new state).
  void configure({
    FieldSpec? spec,
    VariableScope? scope,
    bool? formulasEnabled,
    bool notify = true,
  }) {
    var changed = false;
    if (spec != null && !identical(spec, _spec)) {
      _spec = spec;
      changed = true;
    }
    if (scope != null && !identical(scope, _scope)) {
      _scope = scope;
      changed = true;
    }
    if (formulasEnabled != null && formulasEnabled != _enabled) {
      _enabled = formulasEnabled;
      changed = true;
    }
    if (changed) {
      _cache = null;
      if (notify) notifyListeners();
    }
  }

  set scope(VariableScope s) => configure(scope: s);
  set formulasEnabled(bool on) => configure(formulasEnabled: on);

  /// The server says the stored formula no longer resolves (010
  /// `exprErrors`): an error until the text changes.
  void flag(String message, Decimal savedValue) {
    _flagText = text;
    _flagMessage =
        'This formula no longer works: $message. '
        'Saved value: ${formatFieldValue(savedValue, spec)}.';
    _cache = null;
    notifyListeners();
  }

  FormulaValue? _cache;
  String? _cacheText;

  /// The current text, resolved.
  FormulaValue get formula {
    final t = text;
    final c = _cache;
    if (c != null && _cacheText == t) return c;
    _cacheText = t;
    return _cache = _resolve(t);
  }

  /// The whole number typed: a formula's resolved value (null unless it
  /// is a whole number), else today's `int.tryParse(text.trim())` even
  /// out of range (steppers, live phrases read it as they did).
  int? get typedInt {
    final f = formula;
    return f.isFormula ? f.intValue : parseLegacyInt(text);
  }

  /// Whether [text] is (being) a formula: styled, previewed. Text today's
  /// parser accepts (`-5`, `1,250.50`) never is.
  bool get showsFormula => _enabled && formula.isFormula;

  FormulaValue _resolve(String t) {
    final s = spec;
    if (_flagText != null && t == _flagText) {
      return FormulaValue(
        text: t,
        isEmpty: false,
        isPlain: false,
        isFormula: true,
        error: FormulaError(
          FormulaErrorCode.unknownVariable,
          _flagMessage!,
          0,
          t.length,
        ),
        message: _flagMessage,
        flagged: true,
      );
    }
    if (_flagText != null) {
      _flagText = null;
      _flagMessage = null;
    }
    final empty = t.trim().isEmpty;
    if (!_enabled || looksPlain(t)) {
      // Today's validation, word for word.
      if (!empty && s.legacyParse(t) == null) {
        final m = s.messages[FieldMessage.invalid] ?? 'Enter a number';
        return FormulaValue(
          text: t,
          isEmpty: false,
          isPlain: false,
          isFormula: false,
          error: FormulaError(FormulaErrorCode.badNumber, m, 0, t.length),
          message: m,
        );
      }
      final r = resolveField(t, s, VariableLookup.none);
      return FormulaValue(
        text: t,
        isEmpty: empty,
        isPlain: !empty || r.isPlain,
        isFormula: false,
        value: r.value,
        error: r.error,
        message: r.error?.message,
      );
    }
    final r = resolveField(t, s, _scope);
    final e = r.error;
    final pending =
        e != null &&
        e.code == FormulaErrorCode.unknownVariable &&
        _scope.loading;
    return FormulaValue(
      text: t,
      isEmpty: false,
      isPlain: r.isPlain,
      isFormula: r.isFormula,
      value: r.value,
      expr: r.isFormula ? r.canonicalText : null,
      error: e,
      message: e == null || pending
          ? null
          : [e.message, if (e.hint != null) e.hint].join(' '),
      hints: r.hints,
      pending: pending,
    );
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final v = value;
    final composing =
        withComposing && v.composing.isValid && !v.composing.isCollapsed;
    if (composing || !showsFormula) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final f = formula;
    final t = v.text;
    // Unknown names get their own (warning) look; other errors underline.
    final err = f.error?.code == FormulaErrorCode.unknownVariable || f.flagged
        ? null
        : f.error;
    final spans = highlight(t, _scope.isKnown, error: err);
    return TextSpan(
      style: style,
      children: [
        for (final sp in spans)
          TextSpan(
            text: t.substring(sp.start, sp.end),
            style: sp.style == SpanStyle.variableUnknown && _scope.loading
                ? null
                : FormulaStyle.span(sp.style, style),
          ),
      ],
    );
  }
}
