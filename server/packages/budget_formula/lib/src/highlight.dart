import 'errors.dart';
import 'lexer.dart';
import 'token.dart';

enum SpanStyle {
  number,
  variableKnown,
  variableUnknown,
  operator,
  paren,
  currency,
  whitespace,
  invalid,
  reserved,
}

class StyledSpan {
  final int start;
  final int end;
  final SpanStyle style;
  const StyledSpan(this.start, this.end, this.style);

  @override
  bool operator ==(Object other) =>
      other is StyledSpan &&
      other.start == start &&
      other.end == end &&
      other.style == style;
  @override
  int get hashCode => Object.hash(start, end, style);
  @override
  String toString() => '${style.name}[$start,$end)';
}

SpanStyle _style(FormulaToken t, bool Function(String) isKnown) =>
    switch (t.kind) {
      TokenKind.number => SpanStyle.number,
      TokenKind.variable => t.name!.isNotEmpty && isKnown(t.name!.toLowerCase())
          ? SpanStyle.variableKnown
          : SpanStyle.variableUnknown,
      TokenKind.currencySigil => SpanStyle.currency,
      TokenKind.plus ||
      TokenKind.minus ||
      TokenKind.star ||
      TokenKind.slash =>
        SpanStyle.operator,
      TokenKind.lparen || TokenKind.rparen => SpanStyle.paren,
      TokenKind.whitespace => SpanStyle.whitespace,
      TokenKind.invalid => SpanStyle.invalid,
      _ => SpanStyle.reserved,
    };

/// Styles for every character of [text]: ordered, non-overlapping spans
/// covering `[0, text.length)` exactly. [error]'s span is marked
/// [SpanStyle.invalid] (a zero-width span at the end marks the last
/// character). Never changes the text.
List<StyledSpan> highlight(String text, bool Function(String lowerName) isKnown,
    {FormulaError? error}) {
  final spans = <StyledSpan>[
    for (final t in tokenize(text))
      if (t.end > t.start) StyledSpan(t.start, t.end, _style(t, isKnown)),
  ];
  if (error == null || text.isEmpty) return spans;
  var es = error.start.clamp(0, text.length);
  var ee = error.end.clamp(es, text.length);
  if (es == ee) {
    if (es == text.length) {
      es = text.length - 1;
      // Keep a surrogate pair whole.
      if (es > 0 &&
          _isLow(text.codeUnitAt(es)) &&
          _isHigh(text.codeUnitAt(es - 1))) {
        es--;
      }
      ee = text.length;
    } else {
      ee = es + 1;
    }
  }
  final out = <StyledSpan>[];
  for (final s in spans) {
    if (s.end <= es || s.start >= ee) {
      out.add(s);
      continue;
    }
    if (s.start < es) out.add(StyledSpan(s.start, es, s.style));
    final a = s.start > es ? s.start : es, b = s.end < ee ? s.end : ee;
    out.add(StyledSpan(a, b, SpanStyle.invalid));
    if (s.end > ee) out.add(StyledSpan(ee, s.end, s.style));
  }
  return out;
}

bool _isHigh(int c) => c >= 0xD800 && c <= 0xDBFF;
bool _isLow(int c) => c >= 0xDC00 && c <= 0xDFFF;
