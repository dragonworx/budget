import 'package:budget_formula/budget_formula.dart';
import 'package:test/test.dart';

List<String> kinds(String s) => [
      for (final t in tokenize(s))
        if (t.kind != TokenKind.eof) t.kind.name
    ];

void main() {
  test('basic kinds', () {
    expect(kinds(r'$rent * (12 + 3) / 4 - 1'), [
      'variable',
      'whitespace',
      'star',
      'whitespace',
      'lparen',
      'number',
      'whitespace',
      'plus',
      'whitespace',
      'number',
      'rparen',
      'whitespace',
      'slash',
      'whitespace',
      'number',
      'whitespace',
      'minus',
      'whitespace',
      'number',
    ]);
  });

  test('aliases', () {
    for (final m in ['−', '–', '—']) {
      expect(kinds('5${m}2'), ['number', 'minus', 'number']);
    }
    for (final m in ['×', '·']) {
      expect(kinds('5${m}2'), ['number', 'star', 'number']);
    }
    expect(kinds('5÷2'), ['number', 'slash', 'number']);
    expect(tokenize('5×2')[1].ascii, '*');
  });

  test('x is not an operator', () {
    expect(kinds('5x2'), ['number', 'identifier']);
  });

  test('currency sigil vs variable', () {
    expect(kinds(r'$5'), ['currencySigil', 'number']);
    expect(kinds(r'$.5'), ['currencySigil', 'number']);
    expect(kinds(r'$rent'), ['variable']);
    expect(kinds(r'$_a1'), ['variable']);
    expect(kinds(r'$'), ['variable']);
    expect(tokenize(r'$')[0].name, '');
    expect(kinds(r'$ 5'), ['variable', 'whitespace', 'number']);
    expect(tokenize(r'$Rent2')[0].name, 'Rent2');
  });

  test('reserved tokens', () {
    expect(
        kinds('5%^,;'), ['number', 'percent', 'caret', 'comma', 'semicolon']);
    expect(kinds('round'), ['identifier']);
  });

  test('whitespace kinds merge; newline is invalid', () {
    expect(kinds('1 \t\u00a0\u202f2'), ['number', 'whitespace', 'number']);
    expect(kinds('1\n2'), ['number', 'invalid', 'number']);
  });

  test('numbers are greedy over digits, _ and .', () {
    expect(tokenize('1_250.5_0')[0].lexeme, '1_250.5_0');
    expect(tokenize('1.2.3')[0].lexeme, '1.2.3');
    expect(kinds('_1'), ['identifier']);
    expect(kinds('.'), ['invalid']);
  });

  test('surrogate pair is one invalid token of length 2', () {
    final t = tokenize('1😀2');
    expect(t[1].kind, TokenKind.invalid);
    expect(t[1].start, 1);
    expect(t[1].end, 3);
    // A lone surrogate is one unit.
    final lone = tokenize('\ud83d');
    expect(lone[0].end, 1);
  });

  test('tokens tile the input', () {
    for (final s in [r'  $a+  ( 1_0 )%x😀', '', '   ', r'$$$', '—×÷']) {
      final t = tokenize(s);
      var pos = 0;
      for (final k in t) {
        expect(k.start, pos);
        expect(k.lexeme, s.substring(k.start, k.end));
        pos = k.end;
      }
      expect(pos, s.length);
      expect(t.last.kind, TokenKind.eof);
    }
  });
}
