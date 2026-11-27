import 'package:budget_client/widgets/app_menu_anchor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Finder get _panel => find.byKey(const ValueKey('app-menu-panel'));

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required Alignment align,
  EdgeInsets viewPadding = EdgeInsets.zero,
  int items = 8,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size, viewPadding: viewPadding),
        child: Scaffold(
          body: Stack(
            children: [
              Align(
                alignment: align,
                child: AppMenuAnchor(
                  menuChildren: [
                    for (var i = 1; i <= items; i++)
                      MenuItemButton(
                        onPressed: () {},
                        child: Text('Item $i'),
                      ),
                  ],
                  builder: (context, controller, _) => IconButton(
                    key: const ValueKey('anchor'),
                    icon: const Icon(Icons.more_vert),
                    onPressed: () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('anchor')));
  await tester.pumpAndSettle();
}

void _expectInside(WidgetTester tester, Size size, {EdgeInsets pad = EdgeInsets.zero}) {
  const margin = 8.0;
  final r = tester.getRect(_panel);
  expect(r.left, greaterThanOrEqualTo(pad.left + margin - 0.5));
  expect(r.top, greaterThanOrEqualTo(pad.top + margin - 0.5));
  expect(r.right, lessThanOrEqualTo(size.width - pad.right - margin + 0.5));
  expect(r.bottom, lessThanOrEqualTo(size.height - pad.bottom - margin + 0.5));
}

void main() {
  const phone = Size(320, 568);

  testWidgets('top-left stays inside the viewport minus margins', (tester) async {
    await _pump(tester, size: phone, align: Alignment.topLeft);
    await _open(tester);
    expect(_panel, findsOneWidget);
    _expectInside(tester, phone);
  });

  testWidgets('top-right stays inside the viewport minus margins', (tester) async {
    await _pump(tester, size: phone, align: Alignment.topRight);
    await _open(tester);
    _expectInside(tester, phone);
  });

  testWidgets('bottom-left stays inside the viewport minus margins', (tester) async {
    await _pump(tester, size: phone, align: Alignment.bottomLeft);
    await _open(tester);
    _expectInside(tester, phone);
    // Flipped above the low anchor.
    final menu = tester.getRect(_panel);
    final anchor = tester.getRect(find.byKey(const ValueKey('anchor')));
    expect(menu.bottom, lessThanOrEqualTo(anchor.top + 0.5));
  });

  testWidgets('bottom-right stays inside the viewport minus margins', (tester) async {
    await _pump(tester, size: phone, align: Alignment.bottomRight);
    await _open(tester);
    _expectInside(tester, phone);
    final menu = tester.getRect(_panel);
    final anchor = tester.getRect(find.byKey(const ValueKey('anchor')));
    expect(menu.bottom, lessThanOrEqualTo(anchor.top + 0.5));
    expect(menu.right, lessThanOrEqualTo(phone.width - 8 + 0.5));
  });

  testWidgets('a long menu on the bottom row at 320×568 stays on screen and scrolls', (
    tester,
  ) async {
    await _pump(
      tester,
      size: phone,
      align: Alignment.bottomRight,
      items: 20,
    );
    await _open(tester);
    _expectInside(tester, phone);
    expect(_panel, findsOneWidget);
    // The last items are not all in view at once: the panel is shorter
    // than an unconstrained 20-row menu.
    final r = tester.getRect(_panel);
    expect(r.height, lessThanOrEqualTo(phone.height - 16));
    // 20 rows would exceed the padded viewport if they were not capped.
    expect(r.height, lessThan(20 * 48));
  });

  testWidgets('safe-area insets shrink the allowed box', (tester) async {
    const pad = EdgeInsets.fromLTRB(0, 44, 0, 34);
    await _pump(
      tester,
      size: phone,
      align: Alignment.bottomRight,
      viewPadding: pad,
    );
    await _open(tester);
    _expectInside(tester, phone, pad: pad);
  });
}
