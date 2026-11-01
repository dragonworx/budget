import 'package:decimal/decimal.dart';

import 'ast.dart';
import 'dialect.dart';
import 'errors.dart';
import 'lexer.dart';
import 'token.dart';

/// Grammar limits (variables-plan-review.md, "Limits").
const int maxFormulaLength = 500;
const int maxFormulaTokens = 200;
const int maxBracketDepth = 32;
const int maxUnaryChain = 8;
const int maxIntegerDigits = 15;
const int maxFractionDigits = 10;

class ParseResult {
  final Expr? expr;
  final List<FormulaToken> tokens;
  final FormulaError? error;
  const ParseResult(this.expr, this.tokens, this.error);
  bool get ok => error == null;
}

/// Binding powers (low → high).
const int _bpAdd = 10, _bpMul = 20, _bpPrefix = 30, _bpPow = 35;

class _Fail implements Exception {
  final FormulaError error;
  _Fail(this.error);
}

/// Parses [text] with [dialect]. Never throws on user input; the first
/// error (leftmost, as the parser meets it) wins.
ParseResult parseFormula(String text,
    {FormulaDialect dialect = FormulaDialect.v1}) {
  final tokens = tokenize(text);
  if (text.length > maxFormulaLength) {
    return ParseResult(
        null,
        tokens,
        FormulaError(
            FormulaErrorCode.tooLong,
            'A formula can have at most $maxFormulaLength characters',
            maxFormulaLength,
            text.length));
  }
  final sig = [
    for (final t in tokens)
      if (!t.isTrivia) t
  ];
  if (sig.length == 1) {
    return ParseResult(null, tokens,
        const FormulaError(FormulaErrorCode.empty, 'Enter a formula', 0, 0));
  }
  if (sig.length - 1 > maxFormulaTokens) {
    final t = sig[maxFormulaTokens];
    return ParseResult(
        null,
        tokens,
        FormulaError(FormulaErrorCode.tooLong, 'This formula is too long',
            t.start, text.length));
  }
  final p = _Parser(text, sig, dialect);
  try {
    final e = p.parseTop();
    return ParseResult(e, tokens, null);
  } on _Fail catch (f) {
    return ParseResult(null, tokens, f.error);
  }
}

class _Parser {
  final String text;
  final List<FormulaToken> t;
  final FormulaDialect dialect;
  int pos = 0;
  int depth = 0;
  _Parser(this.text, this.t, this.dialect);

  FormulaToken get peek => t[pos];
  FormulaToken next() => t[pos++];

  Never fail(FormulaErrorCode c, String m, int s, int e, {String? hint}) =>
      throw _Fail(FormulaError(c, m, s, e, hint: hint));

  Expr parseTop() {
    final e = parseExpr(0);
    final k = peek;
    if (k.kind == TokenKind.rparen) {
      fail(FormulaErrorCode.unmatchedParen, 'This ) has no matching (', k.start,
          k.end);
    }
    if (k.kind != TokenKind.eof) infixProblem(k, e);
    return e;
  }

  Expr parseExpr(int minBp, [int chain = 0]) {
    var left = parsePrefix(chain);
    while (true) {
      final k = peek;
      final (bp, op) = switch (k.kind) {
        TokenKind.plus => (_bpAdd, BinaryOp.add),
        TokenKind.minus => (_bpAdd, BinaryOp.subtract),
        TokenKind.star => (_bpMul, BinaryOp.multiply),
        TokenKind.slash => (_bpMul, BinaryOp.divide),
        TokenKind.caret when dialect.power => (_bpPow, BinaryOp.power),
        _ => (-1, BinaryOp.add),
      };
      if (bp >= 0) {
        if (bp <= minBp) return left;
        next();
        // `^` is right-associative: its right side binds at bp - 1.
        final right = parseExpr(op == BinaryOp.power ? bp - 1 : bp);
        left = Binary(op, left, right, k.start);
        continue;
      }
      if (k.kind == TokenKind.percent && dialect.percentLiterals) {
        next();
        left = PercentLit(left, k.end);
        continue;
      }
      if (k.kind == TokenKind.eof ||
          k.kind == TokenKind.rparen ||
          (k.kind == TokenKind.comma && depth > 0 && inCall > 0)) {
        return left;
      }
      infixProblem(k, left);
    }
  }

  int inCall = 0;

  /// [k] follows a complete operand but isn't an operator.
  Never infixProblem(FormulaToken k, Expr left) {
    if (k.kind == TokenKind.identifier && k.lexeme.toLowerCase() == 'x') {
      fail(FormulaErrorCode.missingOperator, 'Use * to multiply', k.start,
          k.end);
    }
    final prev = t[pos - 1];
    if (k.kind == TokenKind.identifier &&
        prev.kind == TokenKind.number &&
        prev.end == k.start &&
        _exponentTail.hasMatch(k.lexeme)) {
      fail(
          FormulaErrorCode.badNumber,
          "Exponents like 1e3 aren't supported; write the number out",
          prev.start,
          k.end);
    }
    reserved(k);
    if (k.kind == TokenKind.invalid) unexpectedChar(k);
    final save = pos, saveDepth = depth;
    var end = k.end;
    try {
      end = parsePrefix(0).end;
    } on _Fail {
      // Keep the token's own span.
    }
    pos = save;
    depth = saveDepth;
    fail(FormulaErrorCode.missingOperator,
        'Add an operator between ${prev.lexeme} and ${k.lexeme}', k.start, end);
  }

  Never unexpectedChar(FormulaToken k) => fail(
      FormulaErrorCode.unexpectedCharacter,
      k.lexeme.trim().isEmpty
          ? "This character can't be used in a formula"
          : "${k.lexeme} can't be used in a formula",
      k.start,
      k.end);

  /// Throws the v1 message for a reserved token (no-op otherwise).
  void reserved(FormulaToken k) {
    switch (k.kind) {
      case TokenKind.percent:
        fail(
            FormulaErrorCode.reservedSyntax,
            "Percent signs aren't supported yet. Write 5 / 100 for 5%.",
            k.start,
            k.end);
      case TokenKind.caret:
        fail(FormulaErrorCode.reservedSyntax, "Powers aren't supported yet",
            k.start, k.end);
      case TokenKind.comma:
        fail(
            FormulaErrorCode.reservedSyntax,
            "Commas can't be used inside a formula; write 1250 or 1_250",
            k.start,
            k.end);
      case TokenKind.semicolon:
        fail(FormulaErrorCode.reservedSyntax,
            "Semicolons can't be used inside a formula", k.start, k.end);
      case TokenKind.identifier:
        // [k] is t[pos] here (callers peek, or step back before calling).
        if (t[pos + 1 < t.length ? pos + 1 : pos].kind == TokenKind.lparen) {
          fail(FormulaErrorCode.reservedSyntax,
              "Functions like round() aren't supported yet", k.start, k.end);
        }
        fail(
            FormulaErrorCode.reservedSyntax,
            'Variable names start with \$ (did you mean \$${k.lexeme}?)',
            k.start,
            k.end,
            hint: 'Did you mean \$${k.lexeme}?');
      default:
        return;
    }
  }

  Expr parsePrefix(int chain) {
    final k = next();
    switch (k.kind) {
      case TokenKind.number:
        return number(k, k.start, currency: false);
      case TokenKind.currencySigil:
        final n = next(); // the lexer guarantees a number follows
        if (n.kind != TokenKind.number) unexpectedChar(k);
        return number(n, k.start, currency: true);
      case TokenKind.variable:
        if (k.name!.isEmpty) {
          fail(FormulaErrorCode.expectedOperand,
              r'Type a variable name after $', k.start, k.end);
        }
        return VarRef(k.name!, k.start, k.end);
      case TokenKind.plus || TokenKind.minus:
        if (chain + 1 > maxUnaryChain) {
          fail(FormulaErrorCode.tooDeep, 'Too many signs in a row', k.start,
              k.end);
        }
        // Prefix signs bind tighter than * / but looser than ^ and %
        // (when enabled): -2 ^ 2 = -(2 ^ 2).
        final operand = parseExpr(_bpPrefix, chain + 1);
        return Unary(k.kind == TokenKind.plus ? UnaryOp.plus : UnaryOp.minus,
            operand, k.start);
      case TokenKind.lparen:
        if (depth + 1 > maxBracketDepth) {
          fail(FormulaErrorCode.tooDeep, 'Too many brackets inside each other',
              k.start, k.end);
        }
        depth++;
        final inner = parseExpr(0);
        final close = peek;
        if (close.kind != TokenKind.rparen) {
          if (close.kind == TokenKind.eof) {
            fail(FormulaErrorCode.unclosedParen, 'This ( is never closed',
                k.start, k.end);
          }
          infixProblem(close, inner);
        }
        next();
        depth--;
        return Group(inner, k.start, close.end);
      case TokenKind.identifier
          when dialect.functions.containsKey(k.lexeme.toLowerCase()) &&
              peek.kind == TokenKind.lparen:
        return call(k);
      case TokenKind.eof:
        fail(FormulaErrorCode.expectedOperand,
            'Add a number or a \$variable here', k.start, k.end);
      case TokenKind.rparen:
        fail(FormulaErrorCode.expectedOperand,
            'Add a number or a \$variable before )', k.start, k.end);
      case TokenKind.star || TokenKind.slash:
        fail(FormulaErrorCode.unexpectedToken,
            'Put a number or a \$variable before ${k.ascii}', k.start, k.end);
      case TokenKind.invalid:
        unexpectedChar(k);
      default:
        pos--;
        reserved(k);
        pos++;
        unexpectedChar(k);
    }
  }

  Expr call(FormulaToken name) {
    final fn = dialect.functions[name.lexeme.toLowerCase()]!;
    next(); // (
    depth++;
    inCall++;
    final args = <Expr>[];
    if (peek.kind != TokenKind.rparen) {
      while (true) {
        args.add(parseExpr(0));
        if (peek.kind == TokenKind.comma) {
          next();
          continue;
        }
        break;
      }
    }
    final close = peek;
    if (close.kind != TokenKind.rparen) {
      fail(FormulaErrorCode.unclosedParen, 'This ( is never closed', name.end,
          name.end + 1);
    }
    next();
    depth--;
    inCall--;
    if (args.length < fn.minArgs || args.length > fn.maxArgs) {
      fail(
          FormulaErrorCode.unexpectedToken,
          '${name.lexeme}() takes ${fn.minArgs == fn.maxArgs ? fn.minArgs : '${fn.minArgs}–${fn.maxArgs}'} values',
          name.start,
          close.end);
    }
    return Call(name.lexeme.toLowerCase(), args, name.start, close.end);
  }

  NumberLit number(FormulaToken k, int start, {required bool currency}) {
    final s = k.lexeme;
    final dots = '.'.allMatches(s).length;
    if (dots > 1) {
      fail(FormulaErrorCode.badNumber,
          'This number has more than one decimal point', k.start, k.end);
    }
    if (s.endsWith('.')) {
      fail(FormulaErrorCode.badNumber, 'Add digits after the decimal point',
          k.start, k.end);
    }
    if (!_numberShape.hasMatch(s)) {
      fail(FormulaErrorCode.badNumber, 'Use _ only between digits, e.g. 1_250',
          k.start, k.end);
    }
    final plain = s.replaceAll('_', '');
    final dot = plain.indexOf('.');
    final intDigits = dot < 0 ? plain.length : dot;
    final fracDigits = dot < 0 ? 0 : plain.length - dot - 1;
    if (intDigits > maxIntegerDigits) {
      fail(
          FormulaErrorCode.numberTooLong,
          'Numbers can have at most $maxIntegerDigits digits before the decimal point',
          k.start,
          k.end);
    }
    if (fracDigits > maxFractionDigits) {
      fail(
          FormulaErrorCode.numberTooLong,
          'Numbers can have at most $maxFractionDigits decimal places',
          k.start,
          k.end);
    }
    final digits = dot < 0 ? plain : plain.replaceFirst('.', '');
    final unscaled = digits.length <= 18
        ? BigInt.from(int.parse(digits))
        : BigInt.parse(digits);
    final value = fracDigits == 0
        ? Decimal.fromBigInt(unscaled)
        : Decimal.fromBigInt(unscaled).shift(-fracDigits);
    return NumberLit(value, s, start, k.end, currency: currency);
  }
}

final RegExp _exponentTail = RegExp(r'^[eE]\d*$');
final RegExp _numberShape = RegExp(r'^(\d(_?\d)*)?(\.\d(_?\d)*)?$');
