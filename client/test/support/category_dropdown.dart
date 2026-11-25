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

/// Picks category [id] in the event editor: open the menu, drill into a
/// parent if needed, tap its row.
Future<void> pickCategory(WidgetTester tester, String id) async {
  await openCategoryMenu(tester);
  var row = find.byKey(ValueKey('editor-category-$id'));
  if (row.evaluate().isEmpty) {
    final drills = find.byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey &&
          k.value is String &&
          (k.value as String).startsWith('editor-category-drill-');
    });
    final count = drills.evaluate().length;
    for (var i = 0; i < count; i++) {
      final current = find.byWidgetPredicate((w) {
        final k = w.key;
        return k is ValueKey &&
            k.value is String &&
            (k.value as String).startsWith('editor-category-drill-');
      });
      if (i >= current.evaluate().length) break;
      await tester.tap(current.at(i));
      await tester.pumpAndSettle();
      row = find.byKey(ValueKey('editor-category-$id'));
      if (row.evaluate().isNotEmpty) break;
      final back = find.byKey(const ValueKey('editor-category-back'));
      if (back.evaluate().isNotEmpty) {
        await tester.tap(back);
        await tester.pumpAndSettle();
      }
    }
  }
  row = find.byKey(ValueKey('editor-category-$id'));
  await tester.ensureVisible(row.last);
  await tester.pumpAndSettle();
  await tester.tap(row.last);
  await tester.pumpAndSettle();
}
