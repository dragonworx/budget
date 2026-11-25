import 'package:budget_client/data/models.dart';
import 'package:budget_client/theme/app_theme.dart';
import 'package:budget_client/widgets/category_dropdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Category _c(String id, String name, {String? parentId}) => Category(
  id: id,
  streamId: 's',
  name: name,
  color: '#3D6FD8',
  parentId: parentId,
  depth: parentId == null ? 0 : 1,
);

final _cats = [
  _c('shop', 'Shopping'),
  _c('groc', 'Groceries', parentId: 'shop'),
  _c('coffee', 'Coffee', parentId: 'shop'),
  _c('ins', 'Insurance'),
];

List<(String, FontWeight?)> _weights(Text t) {
  final span = t.textSpan;
  if (span == null) return [(t.data ?? '', t.style?.fontWeight)];
  final out = <(String, FontWeight?)>[];
  void walk(InlineSpan s, FontWeight? inherited) {
    if (s is! TextSpan) return;
    final w = s.style?.fontWeight ?? inherited;
    if (s.text != null && s.text!.isNotEmpty) out.add((s.text!, w));
    for (final c in s.children ?? const <InlineSpan>[]) {
      walk(c, w);
    }
  }

  walk(span, t.style?.fontWeight);
  return out;
}

Future<void> _pumpPath(
  WidgetTester tester, {
  required List<String> names,
  double width = 400,
  TextStyle? style,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: CategoryPathLabel(names: names, style: style),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('path label: parent regular, leaf bold; top-level just bold', (
    tester,
  ) async {
    await _pumpPath(tester, names: ['Shopping', 'Groceries']);
    final path = tester.widget<Text>(find.byType(Text));
    expect(path.textSpan!.toPlainText(), 'Shopping › Groceries');
    expect(_weights(path), [
      ('Shopping › ', FontWeight.w400),
      ('Groceries', FontWeight.w700),
    ]);

    await _pumpPath(tester, names: ['Insurance']);
    final leaf = tester.widget<Text>(find.byType(Text));
    expect(leaf.data, 'Insurance');
    expect(leaf.style?.fontWeight, FontWeight.w700);
  });

  testWidgets('path label ellipsizes a long name at 320px without overflow', (
    tester,
  ) async {
    final long = 'A very long category name ${'that keeps going ' * 4}'.trim();
    await _pumpPath(tester, names: ['Shopping', long], width: 320);
    expect(tester.takeException(), isNull);
    final text = tester.widget<Text>(find.byType(Text));
    expect(text.overflow, TextOverflow.ellipsis);
    expect(text.maxLines, 1);
    final box = tester.getSize(find.byType(Text));
    expect(box.width, lessThanOrEqualTo(320));
  });

  testWidgets('picker: folder icon + chevron; leaves bold and starrable', (
    tester,
  ) async {
    String? selected = 'ins';
    final favs = <String>['groc'];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: StatefulBuilder(
              builder: (context, setState) => CategoryDropdown(
                categories: _cats,
                selectedId: selected,
                onSelected: (c) => setState(() => selected = c?.id),
                triggerKey: const ValueKey('field'),
                itemKeyPrefix: 'row-',
                favoriteIds: favs,
                onToggleFavorite: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Closed field: top-level leaf is bold.
    final closed = tester.widget<CategoryPathLabel>(
      find.byType(CategoryPathLabel),
    );
    expect(closed.names, ['Insurance']);

    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('row-folder-shop')), findsOneWidget);
    final folderIcon = tester.widget<Icon>(
      find.byKey(const ValueKey('row-folder-shop')),
    );
    expect(folderIcon.icon, Icons.folder_outlined);
    expect(find.byKey(const ValueKey('row-expand-shop')), findsOneWidget);
    expect(find.byKey(const ValueKey('row-folder-ins')), findsNothing);
    expect(find.byKey(const ValueKey('row-star-ins')), findsOneWidget);
    expect(find.byKey(const ValueKey('row-star-shop')), findsNothing);

    // Favourites path: parent regular, leaf bold.
    final favsPath = tester
        .widgetList<CategoryPathLabel>(find.byType(CategoryPathLabel))
        .where((w) => w.names.length > 1);
    expect(favsPath.map((w) => w.names), [
      ['Shopping', 'Groceries'],
    ]);
    final pathTexts = tester.widgetList<Text>(find.byType(Text)).where((t) {
      final s = t.textSpan?.toPlainText() ?? t.data ?? '';
      return s.contains('Groceries') && s.contains('›');
    });
    expect(pathTexts, isNotEmpty);
    expect(_weights(pathTexts.first), [
      ('Shopping › ', FontWeight.w400),
      ('Groceries', FontWeight.w700),
    ]);

    await tester.tap(find.byKey(const ValueKey('row-expand-shop')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Icon>(find.byKey(const ValueKey('row-folder-shop'))).icon,
      Icons.folder_open,
    );
    expect(find.byKey(const ValueKey('row-groc')), findsWidgets);
    expect(find.byKey(const ValueKey('row-star-groc')), findsWidgets);
  });
}
