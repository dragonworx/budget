// Shared by the plain-field goldens: today's event amount field
// (event_editor.dart L961-996 at a86d378, copied verbatim) and the frame
// both it and FormulaField are rendered in.
import 'dart:async';

import 'package:budget_client/theme/app_theme.dart';
import 'package:budget_formula/budget_formula.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The amount `TextFormField` exactly as the event editor builds it.
Widget legacyAmountField({
  required TextEditingController controller,
  FocusNode? focusNode,
  bool every = false,
}) => TextFormField(
  key: const ValueKey('editor-amount'),
  controller: controller,
  focusNode: focusNode,
  decoration: InputDecoration(
    labelText: every ? 'Amount each time' : 'Amount',
    prefixText: '\$ ',
    hintText: '0.00',
  ),
  keyboardType: const TextInputType.numberWithOptions(decimal: true),
  textInputAction: TextInputAction.done,
  onFieldSubmitted: (_) {},
  onChanged: (_) {},
  autovalidateMode: AutovalidateMode.onUserInteraction,
  validator: legacyAmountMessage,
);

/// Today's amount validator (event_editor.dart L982-994), verbatim.
String? legacyAmountMessage(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Enter an amount';
  }
  final amount = parseLegacyMoney(value);
  if (amount == null) {
    return 'Enter a number, e.g. 1250 or 1,250.50';
  }
  if (amount == Decimal.zero) return 'Enter an amount above zero';
  if (amount < Decimal.zero) {
    return 'Use Money out instead of a negative amount';
  }
  return null;
}

/// The app theme, built once in a zone that swallows google_fonts' failed
/// fetches (no network in tests; text falls back to the test font).
final ThemeData testTheme = runZonedGuarded(AppTheme.dark, (_, _) {})!;

/// [field] in the app theme, [width] wide, inside a Form.
Future<void> pumpFieldFrame(
  WidgetTester tester,
  Widget field, {
  required double width,
  double height = 160,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: testTheme,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                RepaintBoundary(key: const ValueKey('frame'), child: field),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The plain cases both goldens cover: (name, text, interact).
const plainCases = [
  ('value', '1,250.50', false),
  ('empty', '', false),
  ('invalid', 'abc', true),
  ('zero', '0', true),
  ('negative', '-5', true),
];
