// Landing after sign-in: the last-used stream opens directly; with none, the
// Streams home shows an empty state with New stream; creating one lands in
// it. There are no projects.
import 'package:budget_client/app.dart';
import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/data/models.dart';
import 'package:decimal/decimal.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:budget_client/widgets/stream_icon.dart';
import 'package:budget_client/features/streams/stream_home_layout.dart';
import 'package:budget_client/features/timeline/stack_lanes.dart';
import 'package:budget_client/widgets/app_menu_anchor.dart';

import 'support/fake_streams.dart';
import 'support/fake_auth.dart';

Future<ProviderContainer> _app(
  WidgetTester tester,
  FakeStreamRepository repo, {
  Size size = const Size(390, 844),
  String? layout,
  Map<String, Decimal>? todayBalances,
  bool clearLocal = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  if (clearLocal) page.clearLocal();
  if (layout != null) writeStreamHomeLayout(layout);
  final c = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(user: adminUser),
      ),
      streamRepositoryProvider.overrideWithValue(repo),
      if (todayBalances != null)
        todayBalanceProvider.overrideWith((ref, id) async => todayBalances[id]),
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
    // The empty state shows the painted stream icon at 30px.
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
      final c = await _app(tester, repo, size: size, layout: 'grid');
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
      // Stream cards lead with the painted stream icon (20px in its 32px tile).
      final cardIcon = find.descendant(
        of: find.byKey(const ValueKey('stream-card-a1')),
        matching: find.byType(StreamIcon),
      );
      expect(cardIcon, findsOneWidget);
      expect(tester.getSize(cardIcon), const Size(20, 20));
      expect(
        tester.getSize(find.byKey(const ValueKey('stream-card-icon-a1'))),
        const Size(32, 32),
      );
      expect(find.byIcon(Icons.account_balance_wallet_rounded), findsNothing);
    });
  }

  // The header stream picker fills the room between the brand and the
  // actions, portrait and landscape: the raised trigger stretches across
  // it, name centred, arrow pinned at the right end; the actions stay
  // on screen.
  for (final (size, docked) in const [
    (Size(320, 640), false),
    (Size(412, 915), false),
    (Size(667, 375), false),
    (Size(844, 390), false),
    (Size(932, 430), false),
    (Size(1024, 768), false),
    (Size(1440, 900), false),
    (Size(1440, 900), true),
  ]) {
    final label =
        '${size.width.toInt()}x${size.height.toInt()}'
        '${docked ? ' docked' : ''}';
    for (final name in const ['Bills', 'Savings for a long holiday abroad']) {
      testWidgets('$label, "$name": the raised stream trigger stretches '
          'across the free header space, arrow pinned right; the trigger, '
          'the arrow and the strip around it open the menu', (tester) async {
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
        // The trigger spans the whole area (2px short of it below 360);
        // the arrow is pinned at its right edge.
        expect(chip.left, closeTo(area.left, 1.5));
        expect(chip.right, lessThanOrEqualTo(area.right + 0.5));
        expect(chip.right, greaterThan(area.right - 3));
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
                w is PopupMenuButton ||
                w is AppMenuAnchor,
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
        // The name is centred in the trigger; a long one ellipsises and
        // stays clear of the arrow.
        expect(
          tester.widget<Text>(find.text(name)).textAlign,
          TextAlign.center,
        );
        final text = tester.renderObject<RenderParagraph>(
          find.descendant(of: find.text(name), matching: find.byType(RichText)),
        );
        final textBox = tester.getRect(
          find.descendant(of: find.text(name), matching: find.byType(RichText)),
        );
        expect(textBox.center.dx, closeTo(chip.center.dx, 2));
        expect(textBox.right, lessThanOrEqualTo(arrow.left + 1));
        // A short name on a wide header: the arrow stays at the far right,
        // not next to the name.
        if (name == 'Bills' && size.width >= 600) {
          expect(arrow.left - textBox.right, greaterThan(48));
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
        await opens(Offset(chip.center.dx, chip.center.dy), 'middle');
        if (area.bottom - chip.bottom > 2) {
          await opens(Offset(chip.center.dx, area.bottom - 1), 'strip below');
        }
      });
    }
  }

  testWidgets('P1–P3: the card is the timeline tap target; ⋮ and a '
      'long-press open the menu without navigating', (tester) async {
    final repo = FakeStreamRepository(
      streams: [testStream('a1', 'Everyday'), testStream('a2', 'Savings')],
    );
    final c = await _app(
      tester,
      repo,
      size: const Size(390, 844),
      layout: 'grid',
    );
    expect(_path(c), '/');

    expect(find.text('Open timeline'), findsNothing);
    expect(find.text('BALANCE TODAY'), findsNothing);
    expect(find.text('My streams · balance today'), findsOneWidget);
    expect(find.byKey(const ValueKey('shared-heading')), findsNothing);

    final meta = find.byKey(const ValueKey('stream-card-meta-a1'));
    expect(meta, findsOneWidget);
    expect(
      tester.widget<Text>(meta).data,
      anyOf('Seed \$0 · 1 Jan 2026', 'Seed \$0 · 1 Jan'),
    );
    expect(tester.widget<Text>(meta).style?.color, AppTheme.cardMeta);
    expect(tester.widget<Text>(meta).style?.fontSize, 12);
    expect(find.byKey(const ValueKey('stream-card-alert-a1')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('stream-card-a1')),
        matching: find.text('Alert < \$0'),
      ),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('stream-card-alert-a1'))).height,
      16,
    );

    final chevron = find.byKey(const ValueKey('stream-card-chevron-a1'));
    expect(chevron, findsOneWidget);
    expect(tester.getSize(chevron), const Size(16, 16));

    final menu = find.byTooltip('Stream actions');
    expect(menu, findsWidgets);
    final menuSize = tester.getSize(menu.first);
    expect(menuSize.width, greaterThanOrEqualTo(44));
    expect(menuSize.height, greaterThanOrEqualTo(44));

    // ⋮ opens the menu and does not open the timeline.
    await tester.tap(menu.first);
    await tester.pumpAndSettle();
    expect(find.text('Stream settings'), findsOneWidget);
    expect(_path(c), '/');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Stream settings'), findsNothing);

    // A finger long-press on the card opens the same menu, still no navigation.
    // Aim at the hero number, well clear of the ⋮ hit area.
    final card = find.byKey(const ValueKey('stream-card-a1'));
    await tester.longPress(card);
    await tester.pumpAndSettle();
    expect(find.text('Stream settings'), findsOneWidget);
    expect(_path(c), '/');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    final sem = tester.getSemantics(card);
    expect(sem.label, contains('Everyday'));
    expect(sem.label, contains('Balance today'));
    expect(sem.label, contains('Open timeline'));
    expect(sem.label, contains('Seed \$0 · 1 Jan'));
    expect(sem.label, contains('Alert < \$0'));

    // Enter / Space on a focused card opens the timeline.
    final focus = find.byKey(const ValueKey('stream-card-focus-a1'));
    expect(focus, findsOneWidget);
    final ink = find
        .descendant(of: focus, matching: find.byType(InkWell))
        .first;
    final node = Focus.of(tester.element(ink));
    node.requestFocus();
    await tester.pump();
    expect(node.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_path(c), '/streams/a1/timeline');
  });

  testWidgets('tapping the card body opens the timeline', (tester) async {
    final repo = FakeStreamRepository(streams: [testStream('a1', 'Everyday')]);
    final c = await _app(tester, repo);
    expect(_path(c), '/');
    await tester.tap(find.byKey(const ValueKey('stream-card-a1')));
    await tester.pumpAndSettle();
    expect(_path(c), '/streams/a1/timeline');
  });

  testWidgets('Shared with me heading also names balance today', (
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
    await _app(tester, repo, layout: 'grid');
    expect(find.text('My streams · balance today'), findsOneWidget);
    expect(find.text('Shared with me · balance today'), findsOneWidget);
    expect(find.text('Shared by Sam'), findsOneWidget);
    // Shared editor can still open the ⋮? canShare is owner-only, canEdit is true
    // for editors so the menu is present. Chevron too.
    expect(
      find.byKey(const ValueKey('stream-card-chevron-b1')),
      findsOneWidget,
    );
  });

  testWidgets('P7: phone header is a 22/28 title, count, and compact + New '
      'on one row; the list starts near 110dp', (tester) async {
    final repo = FakeStreamRepository(
      streams: [testStream('a1', 'Everyday'), testStream('a2', 'Savings')],
      lastStreamId: 'gone',
    );
    await _app(tester, repo, size: const Size(390, 844));

    expect(find.text('2 streams'), findsOneWidget);
    expect(find.textContaining('open one to plan'), findsNothing);
    expect(find.textContaining('Plan each stream'), findsNothing);

    final title = tester.widget<Text>(
      find.byKey(const ValueKey('streams-title')),
    );
    expect(title.style?.fontSize, 22);
    expect(title.style?.height, closeTo(28 / 22, 0.001));

    expect(find.text('New'), findsOneWidget);
    expect(find.text('New stream'), findsNothing);
    final newBtn = find.byKey(const ValueKey('new-stream'));
    expect(newBtn, findsOneWidget);
    final filled = find.descendant(
      of: newBtn,
      matching: find.byType(FilledButton),
    );
    expect(tester.getSize(filled).height, 36);

    final listTop = tester
        .getRect(find.byKey(const ValueKey('mine-heading')))
        .top;
    expect(listTop, closeTo(112, 8));

    final heading = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('mine-heading')),
        matching: find.text('My streams · balance today'),
      ),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('mine-heading'))).height,
      44,
    );
    expect(heading.style?.fontSize, 12);
    expect(heading.style?.fontWeight, FontWeight.w600);
    expect(heading.style?.color, AppTheme.textMuted);
  });

  testWidgets('P7: desktop title is 24/32; a single stream is singular', (
    tester,
  ) async {
    final repo = FakeStreamRepository(
      streams: [testStream('a1', 'Everyday')],
      lastStreamId: 'gone',
    );
    await _app(tester, repo, size: const Size(1440, 900));
    final title = tester.widget<Text>(
      find.byKey(const ValueKey('streams-title')),
    );
    expect(title.style?.fontSize, 24);
    expect(title.style?.height, closeTo(32 / 24, 0.001));
    expect(find.text('1 stream'), findsOneWidget);
    expect(find.text('1 streams'), findsNothing);
  });

  testWidgets('P7: the explainer lives in the empty state, not the header', (
    tester,
  ) async {
    await _app(tester, FakeStreamRepository());
    expect(find.byKey(const ValueKey('streams-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('streams-count')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('streams-empty')),
        matching: find.textContaining("Plan each stream's balance over time"),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('new-stream')), findsOneWidget);
  });

  testWidgets('P7: section headers stay pinned while the list scrolls', (
    tester,
  ) async {
    final repo = FakeStreamRepository(
      streams: [for (var i = 0; i < 8; i++) testStream('a$i', 'Stream $i')],
      lastStreamId: 'gone',
    );
    await _app(tester, repo, size: const Size(390, 500));
    final heading = find.byKey(const ValueKey('mine-heading'));
    final before = tester.getRect(heading).top;
    expect(before, closeTo(112, 8));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -280));
    await tester.pumpAndSettle();
    expect(tester.getRect(heading).top, closeTo(before, 1));
    expect(find.text('My streams · balance today'), findsOneWidget);
  });

  testWidgets(
    'P4: the compact card is 112dp with 15/600 name and 22/600 tabular balance',
    (tester) async {
      final repo = FakeStreamRepository(
        streams: [testStream('a1', 'Everyday')],
        lastStreamId: 'gone',
      );
      await _app(tester, repo, size: const Size(390, 844), layout: 'grid');
      final card = find.byKey(const ValueKey('stream-card-a1'));
      expect(tester.getSize(card).height, 112);

      final material = tester.widget<Material>(
        find.ancestor(of: card, matching: find.byType(Material)).first,
      );
      final shape = material.shape as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(12));

      final name = tester.widget<Text>(
        find.descendant(of: card, matching: find.text('Everyday')).first,
      );
      expect(name.style?.fontSize, 15);
      expect(name.style?.fontWeight, FontWeight.w600);
      expect(name.maxLines, 1);
      expect(name.overflow, TextOverflow.ellipsis);

      final balance = tester.widget<Text>(
        find
            .descendant(
              of: card,
              matching: find.byWidgetPredicate(
                (w) =>
                    w is Text &&
                    w.style?.fontSize == 22 &&
                    w.style?.fontWeight == FontWeight.w600,
              ),
            )
            .first,
      );
      expect(
        balance.style?.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
      expect(balance.maxLines, 1);
      expect(balance.overflow, TextOverflow.ellipsis);

      // Phone padding 12: the 32dp icon sits 12 in from the card top-left.
      final cardRect = tester.getRect(card);
      final iconRect = tester.getRect(
        find.byKey(const ValueKey('stream-card-icon-a1')),
      );
      expect(iconRect.left, closeTo(cardRect.left + 12, 0.5));
      expect(iconRect.top, closeTo(cardRect.top + 12, 0.5));

      final menu = tester.getRect(find.byTooltip('Stream actions').first);
      final chevron = tester.getRect(
        find.byKey(const ValueKey('stream-card-chevron-a1')),
      );
      expect(menu.width, 44);
      expect(menu.height, 44);
      expect(menu.right, closeTo(cardRect.right, 0.5));
      expect(menu.top, closeTo(cardRect.top, 0.5));
      expect(menu.left, greaterThanOrEqualTo(chevron.right + 8 - 0.5));
    },
  );

  testWidgets(
    'P4: long names and balances ellipsize at 320px without overflowing',
    (tester) async {
      final repo = FakeStreamRepository(
        streams: [
          testStream(
            'a1',
            'A very long stream name that must ellipsize on a narrow phone',
          ),
        ],
        lastStreamId: 'gone',
      );
      await _app(tester, repo, size: const Size(320, 640), layout: 'grid');
      final card = find.byKey(const ValueKey('stream-card-a1'));
      expect(card, findsOneWidget);
      expect(tester.getSize(card).height, 112);
      expect(tester.takeException(), isNull);
      final name = tester.widget<Text>(
        find.descendant(of: card, matching: find.byType(Text)).first,
      );
      expect(name.maxLines, 1);
      expect(name.overflow, TextOverflow.ellipsis);
    },
  );

  testWidgets(
    'P6/P9: grid columns, page padding and gaps follow the breakpoints',
    (tester) async {
      final cases = <(Size, int, double, double, double)>[
        // size, columns, page pad, grid gap, content inset (PageBody sides)
        (const Size(320, 640), 1, 16, 8, 0),
        (const Size(412, 915), 1, 16, 8, 0),
        (const Size(599, 800), 1, 16, 8, 0),
        (const Size(600, 800), 2, 24, 12, 0),
        (const Size(899, 800), 2, 24, 12, 0),
        (const Size(900, 800), 3, 24, 12, 0),
        (const Size(1024, 768), 3, 24, 12, 0),
        (const Size(1199, 800), 3, 24, 12, 0),
        (const Size(1200, 800), 4, 32, 12, 0),
        (const Size(1440, 900), 4, 32, 12, (1440 - 1280) / 2),
        (const Size(1600, 900), 5, 32, 12, 0),
      ];
      for (final (size, cols, pad, gap, inset) in cases) {
        final repo = FakeStreamRepository(
          streams: [
            for (var i = 0; i < 10; i++) testStream('a$i', 'Stream $i'),
          ],
          lastStreamId: 'gone',
        );
        await _app(tester, repo, size: size, layout: 'grid');
        final row = [
          for (var i = 0; i < cols; i++)
            tester.getRect(find.byKey(ValueKey('stream-card-a$i'))),
        ]..sort((a, b) => a.left.compareTo(b.left));
        expect(row.first.height, 112, reason: '${size.width} card height');
        expect(row.length, cols, reason: '${size.width} columns');
        expect(
          row.first.left,
          closeTo(inset + pad, 1),
          reason: '${size.width} left padding',
        );
        if (row.length >= 2) {
          expect(
            row[1].left - row[0].right,
            closeTo(gap, 1),
            reason: '${size.width} grid gap',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'P6: phone landscape (width 915) is 3 compact columns, not a list',
    (tester) async {
      final repo = FakeStreamRepository(
        streams: [for (var i = 0; i < 6; i++) testStream('a$i', 'Stream $i')],
        lastStreamId: 'gone',
      );
      await _app(tester, repo, size: const Size(915, 412));
      final rects = [
        for (var i = 0; i < 6; i++)
          tester.getRect(find.byKey(ValueKey('stream-card-a$i'))),
      ];
      final firstTop = rects.first.top;
      final row = [
        for (final r in rects)
          if ((r.top - firstTop).abs() < 1) r,
      ];
      expect(row.length, 3);
      expect(rects.first.height, 112);
      // Phone gap 8 even in landscape (shortest side 412).
      final sorted = [...row]..sort((a, b) => a.left.compareTo(b.left));
      expect(sorted[1].left - sorted[0].right, closeTo(8, 1));
    },
  );

  testWidgets('P4: desktop card uses 16dp padding', (tester) async {
    final repo = FakeStreamRepository(
      streams: [testStream('a1', 'Everyday')],
      lastStreamId: 'gone',
    );
    await _app(tester, repo, size: const Size(1440, 900));
    final cardRect = tester.getRect(
      find.byKey(const ValueKey('stream-card-a1')),
    );
    final iconRect = tester.getRect(
      find.byKey(const ValueKey('stream-card-icon-a1')),
    );
    expect(iconRect.left, closeTo(cardRect.left + 16, 0.5));
    expect(iconRect.top, closeTo(cardRect.top + 16, 0.5));
    expect(cardRect.height, 112);
  });

  testWidgets(
    'P5: phones default to list mode; rows are 64 with a chip and hide the seed',
    (tester) async {
      final repo = FakeStreamRepository(
        streams: [testStream('a1', 'Everyday'), testStream('a2', 'Savings')],
        lastStreamId: 'gone',
      );
      await _app(tester, repo, size: const Size(412, 915));
      expect(find.byKey(const ValueKey('streams-layout-toggle')), findsWidgets);
      final card = find.byKey(const ValueKey('stream-card-a1'));
      expect(tester.getSize(card).height, 64);
      expect(find.byKey(const ValueKey('stream-card-meta-a1')), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('stream-card-icon-a1'))),
        const Size(28, 28),
      );
      final balance = tester.widget<Text>(
        find
            .descendant(
              of: card,
              matching: find.byWidgetPredicate(
                (w) =>
                    w is Text &&
                    w.style?.fontSize == 16 &&
                    w.style?.fontWeight == FontWeight.w600,
              ),
            )
            .first,
      );
      expect(
        balance.style?.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
      expect(
        find.byKey(const ValueKey('stream-card-alert-a1')),
        findsOneWidget,
      );
      final name = tester.getRect(
        find.descendant(of: card, matching: find.text('Everyday')).first,
      );
      final chip = tester.getRect(
        find.byKey(const ValueKey('stream-card-alert-a1')),
      );
      expect(chip.top, greaterThan(name.bottom - 1));
    },
  );

  testWidgets(
    'P5: the section-header toggle switches to grid and is remembered',
    (tester) async {
      final repo = FakeStreamRepository(
        streams: [testStream('a1', 'Everyday'), testStream('a2', 'Savings')],
        lastStreamId: 'gone',
      );
      await _app(tester, repo, size: const Size(412, 915));
      expect(
        tester.getSize(find.byKey(const ValueKey('stream-card-a1'))).height,
        64,
      );
      await tester.tap(
        find.byKey(const ValueKey('streams-layout-toggle')).first,
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('stream-card-a1'))).height,
        112,
      );
      expect(find.byKey(const ValueKey('stream-card-meta-a1')), findsOneWidget);
      expect(page.localGet(kStreamHomeLayoutKey), 'grid');

      await tester.pumpWidget(const SizedBox.shrink());
      await _app(tester, repo, size: const Size(412, 915), clearLocal: false);
      // Preference was written; a fresh app at phone width stays on grid.
      expect(
        tester.getSize(find.byKey(const ValueKey('stream-card-a1'))).height,
        112,
      );
    },
  );

  testWidgets(
    'P5: desktop defaults to grid; list mode still opens the timeline and menu',
    (tester) async {
      final repo = FakeStreamRepository(
        streams: [testStream('a1', 'Everyday')],
        lastStreamId: 'gone',
      );
      final c = await _app(tester, repo, size: const Size(1440, 900));
      expect(
        tester.getSize(find.byKey(const ValueKey('stream-card-a1'))).height,
        112,
      );
      await tester.tap(
        find.byKey(const ValueKey('streams-layout-toggle')).first,
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('stream-card-a1'))).height,
        64,
      );
      expect(find.byKey(const ValueKey('stream-card-meta-a1')), findsNothing);

      final menu = find.byTooltip('Stream actions');
      await tester.tap(menu.first);
      await tester.pumpAndSettle();
      expect(find.text('Stream settings'), findsOneWidget);
      expect(_path(c), '/');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('stream-card-a1')));
      await tester.pumpAndSettle();
      expect(_path(c), '/streams/a1/timeline');
    },
  );

  testWidgets('P5: a 915px-tall phone in list mode fits about 11 streams', (
    tester,
  ) async {
    final repo = FakeStreamRepository(
      streams: [for (var i = 0; i < 14; i++) testStream('a$i', 'Stream $i')],
      lastStreamId: 'gone',
    );
    await _app(tester, repo, size: const Size(412, 915));
    final screen = tester.view.physicalSize;
    var fully = 0;
    for (var i = 0; i < 14; i++) {
      final f = find.byKey(ValueKey('stream-card-a$i'));
      if (f.evaluate().isEmpty) continue;
      final r = tester.getRect(f);
      if (r.top >= 56 && r.bottom <= screen.height + 0.5) fully++;
    }
    expect(fully, greaterThanOrEqualTo(11));
  });

  testWidgets(
    'P8/P10: 10k+ drops cents; red only with a crossed alert, chip included',
    (tester) async {
      final wages = testStream('wages', 'Wages');
      final loanStream = BudgetStream(
        id: 'loan',
        name: 'Mortgage',
        seedBalance: Decimal.zero,
        seedDate: DateTime(2026, 1, 1),
        lossThreshold: Decimal.zero,
        hasLoan: true,
      );
      final ok = testStream('ok', 'Everyday');
      final repo = FakeStreamRepository(
        streams: [wages, loanStream, ok],
        lastStreamId: 'gone',
      );
      await _app(
        tester,
        repo,
        size: const Size(1440, 900),
        layout: 'grid',
        todayBalances: {
          'wages': Decimal.parse('-1980'),
          'loan': Decimal.parse('-395139.85'),
          'ok': Decimal.parse('6400'),
        },
      );

      Color? balanceColor(String id) {
        final t = tester.widget<Text>(
          find
              .descendant(
                of: find.byKey(ValueKey('stream-card-$id')),
                matching: find.byWidgetPredicate(
                  (w) => w is Text && w.style?.fontSize == 22,
                ),
              )
              .first,
        );
        return t.style?.color;
      }

      // Wages is below its $0 threshold (testStream default): red + red chip.
      expect(balanceColor('wages'), AppTheme.debitColor);
      expect(find.text('-\$1,980.00'), findsOneWidget);
      final wagesChip = tester.widget<StreamAlertChip>(
        find.byKey(const ValueKey('stream-card-alert-wages')),
      );
      expect(wagesChip.alert, isTrue);

      // Mortgage is a loan: large negative stays neutral, no chip, cents dropped.
      expect(balanceColor('loan'), AppTheme.text);
      expect(find.text('-\$395,140'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('stream-card-alert-loan')),
        findsNothing,
      );

      expect(balanceColor('ok'), AppTheme.text);
      expect(find.text('\$6,400.00'), findsOneWidget);
      final okChip = tester.widget<StreamAlertChip>(
        find.byKey(const ValueKey('stream-card-alert-ok')),
      );
      expect(okChip.alert, isFalse);
    },
  );

  test('P11: pickStreamColor prefers an unused palette entry', () {
    expect(pickStreamColor(const []), colorToHex(laneColors[0]));
    expect(
      pickStreamColor([colorToHex(laneColors[0]), colorToHex(laneColors[2])]),
      colorToHex(laneColors[1]),
    );
  });

  testWidgets('P11: the stream colour tints the wave icon and its tile', (
    tester,
  ) async {
    const hex = '#B8488E';
    final repo = FakeStreamRepository(
      streams: [testStream('pink', 'Wages', color: hex)],
      lastStreamId: 'gone',
    );
    await _app(tester, repo, size: const Size(1440, 900), layout: 'grid');
    final icon = tester.widget<StreamIcon>(
      find.descendant(
        of: find.byKey(const ValueKey('stream-card-icon-pink')),
        matching: find.byType(StreamIcon),
      ),
    );
    expect(icon.color, colorFromHex(hex));
  });
}
