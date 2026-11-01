// FormulaEditingController: token styling, composing, never mutating the
// text, and caret positions matching an unstyled field.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:budget_client/theme/app_theme.dart';
import 'package:budget_client/widgets/formula/formula_field.dart';
import 'package:budget_client/widgets/formula/formula_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'formula_support.dart';
import 'plain_golden_support.dart';

/// (text, kind) per child span: kinds read back from the styles.
List<(String, String)> kinds(TextSpan span) {
  final out = <(String, String)>[];
  for (final c in span.children ?? const <InlineSpan>[]) {
    final t = c as TextSpan;
    final s = t.style;
    final kind = s == null
        ? 'plain'
        : s.backgroundColor == AppTheme.accentSoft
        ? 'known'
        : s.color == AppTheme.warning
        ? 'unknown'
        : s.decorationStyle == TextDecorationStyle.wavy
        ? 'error'
        : s.color == AppTheme.textMuted
        ? 'muted'
        : 'other';
    out.add((t.text!, kind));
  }
  return out;
}

void main() {
  late BuildContext ctx;
  Future<void> withContext(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );
  }

  FormulaEditingController ctl(String text, {bool loading = false}) =>
      FormulaEditingController(
        text: text,
        spec: amountSpec,
        scope: sampleScope(loading: loading),
      );

  testWidgets('span kinds for sample formulas', (tester) async {
    await withContext(tester);
    TextSpan build(FormulaEditingController c) =>
        c.buildTextSpan(context: ctx, withComposing: true);
    expect(kinds(build(ctl(r'$rent / 4'))), [
      (r'$rent', 'known'),
      (' ', 'plain'),
      ('/', 'muted'),
      (' ', 'plain'),
      ('4', 'plain'),
    ]);
    expect(kinds(build(ctl(r'($rent+50)*2'))), [
      ('(', 'muted'),
      (r'$rent', 'known'),
      ('+', 'muted'),
      ('50', 'plain'),
      (')', 'muted'),
      ('*', 'muted'),
      ('2', 'plain'),
    ]);
    expect(kinds(build(ctl(r'$rnet * 2'))).first, (r'$rnet', 'unknown'));
    expect(kinds(build(ctl(r'$5 + 1'))).first, (r'$', 'muted'));
    // A parse error is underlined; the text colour stays.
    expect(kinds(build(ctl('2 + '))).last.$2, 'error');
    // While loading, unknown names are not flagged.
    expect(kinds(build(ctl(r'$later * 2', loading: true))).first, (
      r'$later',
      'plain',
    ));
  });

  testWidgets('plain text and formulas off: the default span', (tester) async {
    await withContext(tester);
    for (final t in ['1,250.50', '-5', 'abc', '']) {
      final s = ctl(t).buildTextSpan(context: ctx, withComposing: true);
      expect(s.children, isNull, reason: t);
      expect(s.text, t);
    }
    final off = FormulaEditingController(
      text: r'$rent / 4',
      spec: amountSpec,
      scope: sampleScope(),
      formulasEnabled: false,
    );
    expect(
      off.buildTextSpan(context: ctx, withComposing: true).children,
      isNull,
    );
  });

  testWidgets('composing text is not styled', (tester) async {
    await withContext(tester);
    final c = ctl(r'$rent / 4');
    c.value = c.value.copyWith(composing: const TextRange(start: 0, end: 5));
    final s = c.buildTextSpan(context: ctx, withComposing: true);
    expect(kinds(s).where((k) => k.$2 == 'known'), isEmpty);
  });

  testWidgets('buildTextSpan never changes the text (1,000 fuzz strings)', (
    tester,
  ) async {
    await withContext(tester);
    final rnd = Random(11);
    const alphabet = [
      r'$',
      'rent',
      'rego',
      'x',
      '1',
      '2.5',
      ',',
      '+',
      '-',
      '−',
      '*',
      '×',
      '/',
      '÷',
      '(',
      ')',
      ' ',
      '%',
      '^',
      'é',
      '😀',
      'round(',
      '.',
      '_',
    ];
    for (var i = 0; i < 1000; i++) {
      final text = [
        for (var j = rnd.nextInt(12); j > 0; j--)
          alphabet[rnd.nextInt(alphabet.length)],
      ].join();
      final c = ctl(text);
      final span = c.buildTextSpan(context: ctx, withComposing: true);
      expect(c.text, text);
      expect(span.toPlainText(), text, reason: text);
      c.dispose();
    }
  });

  testWidgets('caret positions match an unstyled field', (tester) async {
    const text = r'$rent * 2 + $weeks - $nope';
    final styled = ctl(text);
    final plain = TextEditingController(text: text);
    addTearDown(styled.dispose);
    addTearDown(plain.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme,
        home: Scaffold(
          body: Column(
            children: [
              TextField(key: const ValueKey('s'), controller: styled),
              TextField(key: const ValueKey('p'), controller: plain),
            ],
          ),
        ),
      ),
    );
    RenderEditable editable(String k) => tester
        .state<EditableTextState>(
          find.descendant(
            of: find.byKey(ValueKey(k)),
            matching: find.byType(EditableText),
          ),
        )
        .renderEditable;
    final s = editable('s'), p = editable('p');
    for (var i = 0; i <= text.length; i++) {
      final pos = TextPosition(offset: i);
      expect(
        s.getLocalRectForCaret(pos).left,
        p.getLocalRectForCaret(pos).left,
        reason: 'caret $i',
      );
    }
    // Tapping at each character's left edge puts the caret there.
    for (var i = 0; i < text.length; i++) {
      final r = s.getLocalRectForCaret(TextPosition(offset: i));
      final at = s.localToGlobal(Offset(r.left + 1, r.center.dy));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 500));
      expect(styled.selection.baseOffset, i, reason: 'tap $i');
    }
  });

  test('legacy corpus: plain inputs give today\'s messages', () {
    final corpus = (jsonDecode(
      File('../server/packages/budget_formula/test/legacy_corpus.json')
          .readAsStringSync(),
    ) as List).cast<String>();
    expect(corpus.length, greaterThan(200));
    var checkedOn = 0;
    for (final s in corpus) {
      final off = FormulaEditingController(
        text: s,
        spec: amountSpec,
        scope: sampleScope(),
        formulasEnabled: false,
      ).formula;
      expect(off.message, legacyAmountMessage(s), reason: 'off: "$s"');
      expect(off.expr, isNull);
      final on = ctl(s).formula;
      if (!on.isFormula) {
        checkedOn++;
        expect(on.message, legacyAmountMessage(s), reason: 'on: "$s"');
        expect(on.expr, isNull);
        if (on.message == null) expect(on.value, off.value);
      }
    }
    expect(checkedOn, greaterThan(150));
  });

  test('values and expr', () {
    final f = ctl(r'$rent / 4').formula;
    expect(f.isFormula, isTrue);
    expect(f.value.toString(), '300');
    expect(f.expr, r'$rent / 4');
    expect(f.isValid, isTrue);
    final p = ctl('1,250.50').formula;
    expect(p.isPlain, isTrue);
    expect(p.value.toString(), '1250.5');
    expect(p.expr, isNull);
    expect(formatFieldValue(f.value!, amountSpec), r'$300.00');
  });
}
