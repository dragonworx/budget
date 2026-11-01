// Randomised properties. Seed 20261101; 2,000 cases per property in the
// default run, 20,000 more with `dart test -P fuzz`.
import 'dart:math';

import 'package:budget_formula/budget_formula.dart';
import 'package:test/test.dart';

import 'support.dart';

// --- an independent exact-fraction oracle (no `rational` package) ---------

class Frac {
  final BigInt n, d; // d > 0, reduced
  Frac._(this.n, this.d);
  factory Frac(BigInt n, BigInt d) {
    if (d.isNegative) {
      n = -n;
      d = -d;
    }
    final g = n.gcd(d);
    return g == BigInt.one || g == BigInt.zero
        ? Frac._(n, d)
        : Frac._(n ~/ g, d ~/ g);
  }
  static Frac dec(String s) {
    final t = s.replaceAll('_', '');
    final i = t.indexOf('.');
    if (i < 0) return Frac(BigInt.parse(t), BigInt.one);
    final frac = t.substring(i + 1);
    return Frac(BigInt.parse(t.substring(0, i) + frac),
        BigInt.from(10).pow(frac.length));
  }

  Frac operator +(Frac o) => Frac(n * o.d + o.n * d, d * o.d);
  Frac operator -(Frac o) => Frac(n * o.d - o.n * d, d * o.d);
  Frac operator *(Frac o) => Frac(n * o.n, d * o.d);
  Frac operator /(Frac o) => Frac(n * o.d, d * o.n);
  Frac operator -() => Frac._(-n, d);
  bool get isZero => n == BigInt.zero;
  bool get tooBig => n.abs() > BigInt.from(10).pow(15) * d;
  int get bits => max(n.bitLength, d.bitLength);
}

class OracleFail implements Exception {
  final String code;
  OracleFail(this.code);
}

// --- generated formulas -----------------------------------------------------

final vals = {
  'rent': Frac.dec('1200'),
  'weeks': Frac.dec('52'),
  'rate': Frac.dec('5.5'),
  'some_var_name': Frac.dec('5'),
  'another_var_name': Frac.dec('3'),
  'zero': Frac.dec('0'),
};

sealed class G {}

class GNum extends G {
  final String text;
  GNum(this.text);
}

class GVar extends G {
  final String name;
  GVar(this.name);
}

class GNeg extends G {
  final G e;
  final bool plus;
  GNeg(this.e, this.plus);
}

class GBin extends G {
  final String op;
  final G l, r;
  GBin(this.op, this.l, this.r);
}

class GParen extends G {
  final G e;
  GParen(this.e);
}

class Gen {
  final Random rnd;
  bool bigBits = false;
  Gen(this.rnd);

  String number() {
    final ip = rnd.nextInt(4) == 0
        ? '0'
        : '${rnd.nextInt(pow(10, 1 + rnd.nextInt(5)).toInt())}';
    var s = ip;
    if (rnd.nextInt(5) == 0 && ip.length >= 2) {
      s = '${ip.substring(0, 1)}_${ip.substring(1)}';
    }
    if (rnd.nextInt(3) == 0) s += '.${rnd.nextInt(1000)}';
    return s;
  }

  G tree(int depth) {
    if (depth <= 0 || rnd.nextInt(4) == 0) {
      if (rnd.nextInt(3) == 0) {
        final n = vals.keys.elementAt(rnd.nextInt(vals.length));
        return GVar(rnd.nextBool() ? n : n.toUpperCase());
      }
      return GNum(number());
    }
    switch (rnd.nextInt(10)) {
      case 0:
        return GNeg(tree(depth - 1), rnd.nextInt(4) == 0);
      case 1:
        return GParen(tree(depth - 1));
      default:
        return GBin('+-*/'[rnd.nextInt(4)], tree(depth - 1), tree(depth - 1));
    }
  }

  String sp() => switch (rnd.nextInt(8)) {
        0 => '  ',
        1 => '\t',
        2 => '\u00a0',
        3 || 4 => ' ',
        _ => '',
      };

  String opText(String op) {
    if (rnd.nextInt(4) != 0) return op;
    return switch (op) {
      '-' => ['−', '–', '—'][rnd.nextInt(3)],
      '*' => ['×', '·'][rnd.nextInt(2)],
      '/' => '÷',
      _ => op,
    };
  }

  static int prec(G g) => switch (g) {
        GBin(:final op) => op == '+' || op == '-' ? 10 : 20,
        GNeg() => 30,
        _ => 40,
      };

  String show(G g) => switch (g) {
        GNum(:final text) => text,
        GVar(:final name) => '\$$name',
        GNeg(:final e, :final plus) =>
          '${plus ? '+' : opText('-')}${sp()}${prec(e) < 30 ? '(${show(e)})' : show(e)}',
        GParen(:final e) => '(${sp()}${show(e)}${sp()})',
        GBin(:final op, :final l, :final r) => () {
            final p = prec(g);
            final ls = prec(l) < p ? '(${show(l)})' : show(l);
            final rs = prec(r) <= p ? '(${show(r)})' : show(r);
            return '$ls${sp()}${opText(op)}${sp()}$rs';
          }(),
      };

  Frac value(G g) {
    final Frac v = switch (g) {
      GNum(:final text) => Frac.dec(text),
      GVar(:final name) => vals[name.toLowerCase()]!,
      GNeg(:final e, :final plus) => plus ? value(e) : -value(e),
      GParen(:final e) => value(e),
      GBin(:final op, :final l, :final r) => () {
          final a = value(l), b = value(r);
          switch (op) {
            case '+':
              return a + b;
            case '-':
              return a - b;
            case '*':
              return a * b;
            default:
              if (b.isZero) throw OracleFail('division_by_zero');
              return a / b;
          }
        }(),
    };
    if (v.tooBig) throw OracleFail('overflow');
    if (v.bits > 200) bigBits = true;
    return v;
  }
}

const garbageAlphabet =
    r'0123456789 .._$$$$+-*/()()%^,;xXeE—−×÷·  abcRrent😀' '\u00a0\n';

String garbage(Random rnd) {
  final chars = garbageAlphabet.runes.toList();
  final n = rnd.nextInt(30);
  return String.fromCharCodes(
      [for (var i = 0; i < n; i++) chars[rnd.nextInt(chars.length)]]);
}

void main() {
  const n = 2000;

  void props(int cases) {
    test('generated formulas: parse, exact value vs oracle, round-trips', () {
      final rnd = Random(20261101);
      var checked = 0, errs = 0;
      for (var i = 0; i < cases; i++) {
        final gen = Gen(rnd);
        final g = gen.tree(1 + rnd.nextInt(6));
        final text = '${gen.sp()}${gen.show(g)}${gen.sp()}';
        if (text.length > maxFormulaLength) continue;
        final p = parseFormula(text);
        if (p.tokens
                .where((t) => !t.isTrivia && t.kind != TokenKind.eof)
                .length >
            maxFormulaTokens) {
          continue;
        }
        expect(p.error, isNull, reason: '$text ${p.error}');
        final r = evaluate(p.expr!, stdVars);
        try {
          final want = gen.value(g);
          expect(r, isA<EvalOk>(), reason: '$text $r');
          final got = (r as EvalOk).value;
          if (!gen.bigBits) {
            expect(got.numerator, want.n, reason: text);
            expect(got.denominator, want.d, reason: text);
          }
          checked++;
        } on OracleFail catch (f) {
          expect(r, isA<EvalErr>(), reason: '$text: oracle ${f.code}');
          expect((r as EvalErr).error.codeName, f.code, reason: text);
          errs++;
        }
        // prettyPrint round-trip.
        final pp = prettyPrint(p.expr!);
        final p2 = parseFormula(pp);
        expect(p2.error, isNull, reason: pp);
        expect(prettyPrint(p2.expr!), pp);
        expect(evaluate(p2.expr!, stdVars).toString(), r.toString(),
            reason: pp);
        // rename round-trip.
        final there = renameVariable(text, 'rent', 'zz_tmp');
        expect(
            renameVariable(there, 'zz_tmp', 'rent'),
            text.replaceAll(
                RegExp(r'\$rent\b', caseSensitive: false), r'$rent'));
        // canonical text means the same thing.
        final c = parseFormula(canonicalise(text, stdVars));
        expect(evaluate(c.expr!, stdVars).toString(), r.toString(),
            reason: text);
      }
      expect(checked, greaterThan(cases ~/ 3));
      expect(errs, greaterThan(0));
    });

    test('arbitrary text: nothing throws, spans tile, errors are in range', () {
      final rnd = Random(20261101);
      final specs = fieldSpecs.values.toList();
      for (var i = 0; i < cases; i++) {
        final text = garbage(rnd);
        final toks = tokenize(text);
        var pos = 0;
        for (final t in toks) {
          expect(t.start, pos, reason: text);
          pos = t.end;
        }
        expect(pos, text.length);
        final p = parseFormula(text);
        final e = p.error ??
            (evaluate(p.expr!, stdVars) is EvalErr
                ? (evaluate(p.expr!, stdVars) as EvalErr).error
                : null);
        if (e != null) {
          expect(e.start, inInclusiveRange(0, text.length), reason: '$text $e');
          expect(e.end, inInclusiveRange(e.start, text.length),
              reason: '$text $e');
          expect(e.message, isNotEmpty);
        }
        final hl = highlight(text, (n) => n == 'rent', error: e);
        pos = 0;
        for (final s in hl) {
          expect(s.start, pos, reason: text);
          expect(s.end, greaterThan(s.start), reason: text);
          pos = s.end;
        }
        expect(pos, text.length, reason: text);
        for (var c = 0; c <= text.length; c++) {
          final ctx = completionAt(text, c);
          if (ctx != null) {
            expect(text[ctx.replaceStart], r'$');
            expect(ctx.replaceEnd, greaterThanOrEqualTo(c));
          }
        }
        final r = resolveField(text, specs[i % specs.length], stdVars);
        expect(r.value == null || r.error == null, isTrue);
        canonicalise(text, stdVars);
        expect(renameVariable(text, 'nope_never', 'x'), text);
      }
    });
  }

  group('default', () => props(n));
  group('full', () => props(20000), tags: 'fuzz');
}
