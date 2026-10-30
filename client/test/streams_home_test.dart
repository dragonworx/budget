// Landing after sign-in: the last-used stream opens directly; with none, the
// Streams home shows an empty state with New stream; creating one lands in
// it. There are no projects.
import 'package:budget_client/app.dart';
import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/data/models.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:budget_client/widgets/stream_icon.dart';

import 'support/fake_streams.dart';
import 'support/fake_auth.dart';

Future<ProviderContainer> _app(
  WidgetTester tester,
  FakeStreamRepository repo, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final c = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(user: adminUser),
      ),
      streamRepositoryProvider.overrideWithValue(repo),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: c, child: const BudgetApp()),
  );
  await tester.pumpAndSettle();
  return c;
}

String _path(ProviderContainer c) =>
    c.read(routerProvider).routerDelegate.currentConfiguration.uri.path;

void main() {
  testWidgets('lands on the last-used stream', (tester) async {
    final repo = FakeStreamRepository(
      streams: [testStream('a1', 'Everyday'), testStream('a2', 'Savings')],
      lastStreamId: 'a2',
    );
    final c = await _app(tester, repo, size: const Size(1200, 900));
    expect(_path(c), '/streams/a2/timeline');
    // Opening another stream (even from cache) records it server-side.
    c.read(routerProvider).go('/streams/a1/timeline');
    await tester.pumpAndSettle();
    c.read(routerProvider).go('/streams/a2/timeline');
    await tester.pumpAndSettle();
    expect(repo.opened, ['a2', 'a1', 'a2']);
  });

  testWidgets('lands once per session: going to the Streams home stays there', (
    tester,
  ) async {
    final repo = FakeStreamRepository(
      streams: [testStream('a1', 'Everyday')],
      lastStreamId: 'a1',
    );
    final c = await _app(tester, repo);
    expect(_path(c), '/streams/a1/timeline');
    c.read(routerProvider).go('/');
    await tester.pumpAndSettle();
    expect(_path(c), '/');
    expect(find.byKey(const ValueKey('stream-card-a1')), findsOneWidget);
    c.read(routerProvider).go(streamsPath);
    await tester.pumpAndSettle();
    expect(_path(c), streamsPath);
  });

  testWidgets('no last stream: the Streams home lists mine and shared', (
    tester,
  ) async {
    final repo = FakeStreamRepository(
      streams: [
        testStream('a1', 'Everyday'),
        testStream(
          'b1',
          'Joint',
          shared: true,
          role: Role.editor,
          ownerName: 'Sam',
        ),
      ],
      lastStreamId: 'gone',
    );
    final c = await _app(tester, repo);
    expect(_path(c), '/');
    expect(find.text('Streams'), findsWidgets);
    expect(find.byKey(const ValueKey('new-stream')), findsOneWidget);
    expect(find.byKey(const ValueKey('mine-heading')), findsOneWidget);
    expect(find.byKey(const ValueKey('shared-heading')), findsOneWidget);
    expect(find.byKey(const ValueKey('role-chip-editor')), findsOneWidget);
    expect(find.textContaining('roject'), findsNothing);
  });

  testWidgets('first sign-in: empty state, New stream creates and lands in '
      'it', (tester) async {
    final repo = FakeStreamRepository();
    final c = await _app(tester, repo);
    expect(_path(c), '/');
    expect(find.byKey(const ValueKey('streams-empty')), findsOneWidget);
    // The empty state shows the bucket stream icon at 30px.
    final emptyIcon = find.descendant(
      of: find.byKey(const ValueKey('streams-empty')),
      matching: find.byType(StreamIcon),
    );
    expect(emptyIcon, findsOneWidget);
    expect(tester.getSize(emptyIcon), const Size(30, 30));
    expect(find.textContaining('roject'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('new-stream')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('stream-name')),
      'Everyday',
    );
    await tester.tap(find.byKey(const ValueKey('stream-save')));
    await tester.pumpAndSettle();
    expect(repo.created.single.name, 'Everyday');
    expect(_path(c), '/streams/new-1/timeline');
  });

  for (final size in const [Size(390, 844), Size(1440, 900)]) {
    testWidgets('${size.width.toInt()}px: the header stream menu has no '
        'Manage streams (mine, shared, New stream stay); the back arrow '
        '("All streams") opens the Streams home', (tester) async {
      final repo = FakeStreamRepository(
        streams: [
          testStream('a1', 'Everyday'),
          testStream('a2', 'Savings'),
          testStream('b1', 'Kids', shared: true, role: Role.viewer),
        ],
        lastStreamId: 'a1',
      );
      final c = await _app(tester, repo, size: size);
      expect(_path(c), '/streams/a1/timeline');
      await tester.tap(find.byKey(const ValueKey('header-stream-picker')));
      await tester.pumpAndSettle();
      // No "My streams" label: the menu starts with my streams.
      expect(find.byKey(const ValueKey('nav-header-mine')), findsNothing);
      expect(find.text('My streams'), findsNothing);
      expect(
        tester.getRect(find.byKey(const ValueKey('nav-stream-a1'))).top,
        lessThan(
          tester.getRect(find.byKey(const ValueKey('nav-stream-a2'))).top,
        ),
      );
      expect(find.byKey(const ValueKey('nav-stream-a2')), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-header-shared')), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-stream-b1')), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-new-stream')), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-manage-streams')), findsNothing);
      expect(find.text('Manage streams'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      final back = find.byKey(const ValueKey('timeline-back'));
      expect(back, findsOneWidget);
      expect(find.byTooltip('All streams'), findsOneWidget);
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(_path(c), streamsPath);
      expect(find.byKey(const ValueKey('stream-card-a1')), findsOneWidget);
      // Stream cards lead with the bucket stream icon (22px in its tile).
      final cardIcon = find.descendant(
        of: find.byKey(const ValueKey('stream-card-a1')),
        matching: find.byType(StreamIcon),
      );
      expect(cardIcon, findsOneWidget);
      expect(tester.getSize(cardIcon), const Size(22, 22));
      expect(find.byIcon(Icons.account_balance_wallet_rounded), findsNothing);
    });
  }

  // The header stream picker fills the room between the brand and the
  // actions: the arrow at its right end, the empty space after the name a
  // tap target too; the actions stay on screen.
  for (final (size, docked) in const [
    (Size(320, 640), false),
    (Size(412, 915), false),
    (Size(932, 430), false),
    (Size(1440, 900), false),
    (Size(1440, 900), true),
  ]) {
    final label =
        '${size.width.toInt()}x${size.height.toInt()}'
        '${docked ? ' docked' : ''}';
    for (final name in const ['Bills', 'Savings for a long holiday abroad']) {
      testWidgets('$label, "$name": a raised stream trigger at the left of '
          'the stretched area; the trigger, the arrow and the empty space '
          'after it open the menu', (tester) async {
        page.localSet('budget_events_docked', docked ? '1' : '0');
        addTearDown(page.clearLocal);
        final repo = FakeStreamRepository(
          streams: [testStream('a1', name), testStream('a2', 'Other')],
          lastStreamId: 'a1',
        );
        await _app(tester, repo, size: size);
        expect(tester.takeException(), isNull);
        final area = tester.getRect(
          find.byKey(const ValueKey('header-stream-area')),
        );
        final chip = tester.getRect(
          find.byKey(const ValueKey('header-stream-picker')),
        );
        final arrow = tester.getRect(
          find.byKey(const ValueKey('header-stream-arrow')),
        );
        // Raised: a lighter surface than the header, a border and a shadow.
        final deco =
            tester
                    .widget<DecoratedBox>(
                      find.byKey(const ValueKey('header-stream-surface')),
                    )
                    .decoration
                as BoxDecoration;
        expect(deco.color, AppTheme.raised);
        expect(deco.color, isNot(AppTheme.bg));
        expect(deco.border, isNotNull);
        expect(deco.boxShadow, isNotEmpty);
        // The trigger sits at the area's left, inside it; the arrow ends it.
        expect(chip.left, closeTo(area.left, 1.5));
        expect(chip.right, lessThanOrEqualTo(area.right + 0.5));
        expect(chip.height, greaterThanOrEqualTo(36));
        expect(arrow.right, lessThanOrEqualTo(chip.right));
        expect(chip.right - arrow.right, lessThan(8));
        // The stretched area still reaches the actions (the toolbar's 16px
        // middle spacing plus the actions' own leading gap).
        final actions = find.descendant(
          of: find.byType(AppBar),
          matching: find.byWidgetPredicate(
            (w) =>
                w is IconButton ||
                w is ButtonStyleButton ||
                w is PopupMenuButton,
          ),
        );
        final rights = [
          for (final e in actions.evaluate())
            tester.getRect(find.byWidget(e.widget)),
        ].where((r) => r.left >= area.right - 0.5).toList();
        expect(rights, isNotEmpty);
        final firstAction = rights
            .map((r) => r.left)
            .reduce((a, b) => a < b ? a : b);
        // Only the sync dot and the small lead gap sit before New event
        // today (the first button).
        expect(firstAction - area.right, lessThanOrEqualTo(30));
        for (final r in rights) {
          expect(r.right, lessThanOrEqualTo(size.width));
        }
        // The name leads the trigger; a long one ellipsises.
        final text = tester.renderObject<RenderParagraph>(
          find.descendant(of: find.text(name), matching: find.byType(RichText)),
        );
        final textBox = tester.getRect(
          find.descendant(of: find.text(name), matching: find.byType(RichText)),
        );
        if (textBox.width > 0) {
          expect(textBox.left, greaterThan(chip.left));
          expect(textBox.left, lessThan(chip.left + 14));
        }
        final glyphs = text.getMaxIntrinsicWidth(double.infinity);
        if (glyphs > area.width - 40) expect(text.didExceedMaxLines, isTrue);
        Future<void> opens(Offset at, String why) async {
          await tester.tapAt(at);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('nav-stream-a2')),
            findsOneWidget,
            reason: why,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('nav-stream-a2')), findsNothing);
        }

        await opens(arrow.center, 'arrow');
        await opens(Offset(chip.left + 6, chip.center.dy), 'trigger');
        if (area.right - chip.right > 12) {
          final x = (chip.right + area.right) / 2;
          await opens(Offset(x, area.center.dy), 'empty space');
          await opens(Offset(x, area.bottom - 3), 'empty space, low');
        }
      });
    }
  }
}
