// Home app bar: the sync/connection dot sits inline after the Budgie
// wordmark, not beside the avatar; Refresh and the user menu stay on
// the right. Must not overflow at 320px or in landscape.
import 'package:budget_client/app.dart';
import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/state/realtime_providers.dart';
import 'package:budget_client/widgets/user_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth.dart';
import 'support/fake_streams.dart';

Future<void> _home(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  page.clearLocal();
  final c = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(user: adminUser),
      ),
      streamRepositoryProvider.overrideWithValue(
        FakeStreamRepository(streams: [testStream('a1', 'Everyday')]),
      ),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: c, child: const BudgetApp()),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final size in const [
    Size(320, 640),
    Size(412, 915),
    Size(915, 412),
    Size(640, 320),
    Size(1440, 900),
  ]) {
    testWidgets('Home app bar: sync dot sits after the title at '
        '${size.width.toInt()}×${size.height.toInt()}', (tester) async {
      await _home(tester, size);
      expect(tester.takeException(), isNull);

      expect(find.byType(RealtimeDot), findsOneWidget);
      expect(find.byKey(const ValueKey('brand-navbar')), findsOneWidget);
      expect(find.byTooltip('Refresh'), findsOneWidget);
      expect(find.byKey(const ValueKey('user-menu')), findsOneWidget);

      final title = tester.getRect(find.byKey(const ValueKey('brand-navbar')));
      final dot = tester.getRect(find.byType(RealtimeDot));
      final refresh = tester.getRect(find.byTooltip('Refresh'));
      final menu = tester.getRect(find.byKey(const ValueKey('user-menu')));
      final bar = tester.getRect(find.byType(AppBar));

      // Inline after the wordmark, vertically centred with it.
      expect(dot.left, greaterThanOrEqualTo(title.right));
      expect(dot.left - title.right, closeTo(10, 1.5));
      expect(dot.center.dy, closeTo(title.center.dy, 3));
      expect(dot.top, greaterThan(bar.top));
      expect(dot.bottom, lessThan(bar.bottom));

      // Right-side actions stay on the right and are clear of the dot.
      expect(refresh.left, greaterThan(dot.right + 16));
      expect(menu.left, greaterThanOrEqualTo(refresh.right - 1));
      expect(menu.right, lessThanOrEqualTo(size.width));
      expect(title.left, greaterThanOrEqualTo(bar.left));

      // Tooltip and semantics are unchanged.
      expect(
        find.byTooltip(RegExp(r'^(Live:|Connecting|Reconnecting|Offline:)')),
        findsOneWidget,
      );
      final handle = tester.ensureSemantics();
      expect(
        tester.getSemantics(find.byType(RealtimeDot)).label,
        matches(RegExp(r'^Sync \S')),
      );
      handle.dispose();
    });
  }

  testWidgets('the user menu on Home no longer includes a second sync dot', (
    tester,
  ) async {
    await _home(tester, const Size(390, 844));
    final menu = tester.getRect(find.byKey(const ValueKey('user-menu')));
    final dot = tester.getRect(find.byType(RealtimeDot));
    expect(dot.right, lessThan(menu.left));
    expect(find.byType(RealtimeDot), findsOneWidget);
    // The avatar is still the menu's trigger.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('user-menu')),
        matching: find.byType(UserAvatar),
      ),
      findsOneWidget,
    );
  });
}
