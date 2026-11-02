import 'names.dart';
import 'token.dart';

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
bool _isNameStart(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;
bool _isNamePart(int c) => _isNameStart(c) || _isDigit(c);
bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0xA0 || c == 0x202F;

/// Splits [text] into tokens covering every code unit, in order, ending
/// with a zero-width [TokenKind.eof]. Total: never throws. Number lexemes
/// are taken greedily over `[0-9_.]` and checked by the parser, so `5.`,
/// `1__250` and `1.2.3` get a precise message.
List<FormulaToken> tokenize(String text) {
  final out = <FormulaToken>[];
  final n = text.length;
  var i = 0;
  void add(TokenKind k, int s, int e, {String? name}) =>
      out.add(FormulaToken(k, s, e, text.substring(s, e), name: name));
  int numberEnd(int s) {
    var e = s;
    while (e < n) {
      final c = text.codeUnitAt(e);
      if (_isDigit(c) || c == 0x5F || c == 0x2E) {
        e++;
      } else {
        break;
      }
    }
    return e;
  }

  while (i < n) {
    final c = text.codeUnitAt(i);
    final next = i + 1 < n ? text.codeUnitAt(i + 1) : -1;
    if (_isSpace(c)) {
      var e = i + 1;
      while (e < n && _isSpace(text.codeUnitAt(e))) {
        e++;
      }
      add(TokenKind.whitespace, i, e);
      i = e;
    } else if (_isDigit(c) || (c == 0x2E && _isDigit(next))) {
      final e = numberEnd(i);
      add(TokenKind.number, i, e);
      i = e;
    } else if (c == 0x24 /* $ */) {
      if (_isDigit(next) || next == 0x2E) {
        add(TokenKind.currencySigil, i, i + 1);
        i++;
      } else {
        // The retired `$name` form (or a lone `$`): one reserved token, so
        // the parser can say "write rent, not $rent".
        var e = i + 1;
        while (e < n && _isNamePart(text.codeUnitAt(e))) {
          e++;
        }
        add(TokenKind.identifier, i, e, name: text.substring(i + 1, e));
        i = e;
      }
    } else if (_isNameStart(c)) {
      var e = i + 1;
      while (e < n && _isNamePart(text.codeUnitAt(e))) {
        e++;
      }
      final lexeme = text.substring(i, e);
      if (c == 0x5F || isReservedName(lexeme)) {
        add(TokenKind.identifier, i, e);
      } else {
        add(TokenKind.variable, i, e, name: lexeme);
      }
      i = e;
    } else {
      final kind = switch (c) {
        0x2B => TokenKind.plus,
        0x2D || 0x2212 || 0x2013 || 0x2014 => TokenKind.minus,
        0x2A || 0xD7 || 0xB7 => TokenKind.star,
        0x2F || 0xF7 => TokenKind.slash,
        0x28 => TokenKind.lparen,
        0x29 => TokenKind.rparen,
        0x25 => TokenKind.percent,
        0x5E => TokenKind.caret,
        0x2C => TokenKind.comma,
        0x3B => TokenKind.semicolon,
        _ => TokenKind.invalid,
      };
      // A surrogate pair (emoji) is one invalid token of length 2.
      final pair = kind == TokenKind.invalid &&
          c >= 0xD800 &&
          c <= 0xDBFF &&
          next >= 0xDC00 &&
          next <= 0xDFFF;
      add(kind, i, i + (pair ? 2 : 1));
      i += pair ? 2 : 1;
    }
  }
  out.add(FormulaToken(TokenKind.eof, n, n, ''));
  return out;
}
