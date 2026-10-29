import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens the event editor's category drop-down.
Future<void> openCategoryMenu(WidgetTester tester) async {
  final field = find.byKey(const ValueKey('editor-category-field'));
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.tap(field);
  await tester.pumpAndSettle();
}

/// Picks category [id] in the event editor: open the menu, tap its row.
Future<void> pickCategory(WidgetTester tester, String id) async {
  await openCategoryMenu(tester);
  final row = find.byKey(ValueKey('editor-category-$id'));
  await tester.ensureVisible(row.last);
  await tester.pumpAndSettle();
  await tester.tap(row.last);
  await tester.pumpAndSettle();
}
