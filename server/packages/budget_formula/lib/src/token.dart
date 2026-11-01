/// Token kinds. Reserved kinds (`percent`, `caret`, `comma`, `semicolon`,
/// `identifier`) are recognised so v1 can explain them and v2 can enable
/// them without changing the lexer.
enum TokenKind {
  number,
  variable,
  currencySigil,
  plus,
  minus,
  star,
  slash,
  lparen,
  rparen,
  percent,
  caret,
  comma,
  semicolon,
  identifier,
  whitespace,
  invalid,
  eof,
}

/// One token. [start]/[end] are UTF-16 offsets (Flutter `TextRange` units).
class FormulaToken {
  final TokenKind kind;
  final int start;
  final int end;

  /// The exact source text (an alias like `×` stays `×`).
  final String lexeme;

  /// For [TokenKind.variable]: the name without `$`, as typed ('' for a
  /// lone `$`).
  final String? name;

  const FormulaToken(this.kind, this.start, this.end, this.lexeme, {this.name});

  bool get isTrivia => kind == TokenKind.whitespace;

  bool get isOperator =>
      kind == TokenKind.plus ||
      kind == TokenKind.minus ||
      kind == TokenKind.star ||
      kind == TokenKind.slash;

  /// The ASCII form of the token (aliases mapped, NBSP → space).
  String get ascii => switch (kind) {
        TokenKind.plus => '+',
        TokenKind.minus => '-',
        TokenKind.star => '*',
        TokenKind.slash => '/',
        TokenKind.whitespace =>
          lexeme.replaceAll(RegExp('[\u00A0\u202F]'), ' '),
        _ => lexeme,
      };

  @override
  String toString() => '${kind.name}[$start,$end)"$lexeme"';
}
