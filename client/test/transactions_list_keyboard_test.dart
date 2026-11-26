// Opening the Transactions list (and tapping in it) must not leave a
// keyboard-primer hotspot from the covered timeline FAB, and must not
// prime the soft keyboard except when New opens the editor.
import 'package:budget_client/boot/kb_hotspot.dart';
import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/timeline/timeline_page.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth.dart';
import 'support/fake_categories.dart';

void main() {
  setUp(() {
    page.kbHotspots.clear();
    page.primeSoftKeyboardCalls = 0;
    page.releaseSoftKeyboardCalls = 0;
    page.softKeyboardFieldPointerCalls = 0;
  });

  testWidgets('a hotspot covered by an overlay is unregistered', (
    tester,
  ) async {
    final covered = ValueNotifier(false);
    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: covered,
          builder: (context, _) => Stack(
            children: [
              const Center(
                child: KbHotspot(
                  id: 'under',
                  kind: 'decimal',
                  child: SizedBox(
                    width: 80,
                    height: 80,
                    child: ColoredBox(color: Color(0xFFFF0000)),
                  ),
                ),
              ),
              if (covered.value)
                const ModalBarrier(
                  color: Color(0x80000000),
                  dismissible: false,
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(page.kbHotspots.containsKey('under'), isTrue);

    covered.value = true;
    await tester.pump();
    expect(page.kbHotspots.containsKey('under'), isFalse);

    covered.value = false;
    await tester.pump();
    expect(page.kbHotspots.containsKey('under'), isTrue);
  });

  testWidgets('opening the Transactions overlay unregisters the timeline FAB; '
      'taps in the list do not prime the keyboard; New still does', (
    tester,
  ) async {
    await _pumpPhone(tester);
    expect(page.kbHotspots.containsKey('add-event-fab'), isTrue);

    await tester.tap(find.byKey(const ValueKey('open-events')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('events-panel-body')), findsOneWidget);
    expect(find.text('Transactions'), findsOneWidget);
    expect(page.kbHotspots.containsKey('add-event-fab'), isFalse);
    expect(page.kbHotspots.containsKey('pick-add'), isFalse);
    expect(page.kbHotspots.containsKey('sel-add'), isFalse);
    expect(page.kbHotspots.containsKey('panel-new-event'), isTrue);

    final primed = page.primeSoftKeyboardCalls;
    await tester.tap(find.text('Debit'));
    await tester.pumpAndSettle();
    expect(find.text('Rent'), findsWidgets);
    expect(page.primeSoftKeyboardCalls, primed);
    expect(find.byKey(const ValueKey('events-panel-body')), findsOneWidget);

    // Opening an existing transaction must not prime or focus Amount.
    await tester.tap(find.text('Rent'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(page.primeSoftKeyboardCalls, primed);
    final amount = find.descendant(
      of: find.byKey(const ValueKey('editor-amount')),
      matching: find.byType(EditableText),
    );
    expect(amount, findsOneWidget);
    expect(tester.widget<EditableText>(amount).focusNode!.hasFocus, isFalse);

    // Back to the list, then New may still prime / focus Amount.
    final back = find.byKey(const ValueKey('editor-back'));
    if (back.evaluate().isNotEmpty) {
      await tester.tap(back);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byKey(const ValueKey('events-panel-body')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('panel-new-event')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(page.primeSoftKeyboardCalls, primed + 1);
  });

  // DEV-12: after adding (or abandoning) one new transaction, Amount
  // must still accept focus and text the next time New is opened.
  testWidgets(
    'opening New a second time still focuses Amount and accepts text',
    (tester) async {
      await _pumpPhone(tester);
      await tester.tap(find.byKey(const ValueKey('open-events')));
      await tester.pumpAndSettle();

      Finder amount() => find.descendant(
        of: find.byKey(const ValueKey('editor-amount')),
        matching: find.byType(EditableText),
      );

      Future<void> openNew() async {
        await tester.tap(find.byKey(const ValueKey('panel-new-event')));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.byKey(const ValueKey('editor-amount')), findsOneWidget);
        expect(
          tester.widget<EditableText>(amount()).focusNode!.hasFocus,
          isTrue,
        );
      }

      await openNew();
      await tester.enterText(amount(), '12.50');
      await tester.pump();
      expect(tester.widget<EditableText>(amount()).controller!.text, '12.50');

      final released = page.releaseSoftKeyboardCalls;
      await tester.tap(find.byKey(const ValueKey('editor-back')));
      await tester.pumpAndSettle();
      final discard = find.text('Discard');
      if (discard.evaluate().isNotEmpty) {
        await tester.tap(discard);
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const ValueKey('events-panel-body')), findsOneWidget);
      expect(page.releaseSoftKeyboardCalls, greaterThan(released));

      await openNew();
      await tester.enterText(amount(), '33.00');
      await tester.pump();
      expect(tester.widget<EditableText>(amount()).controller!.text, '33.00');
      expect(tester.widget<EditableText>(amount()).focusNode!.hasFocus, isTrue);

      // A tap on Amount is forwarded so a stuck iOS focus patch can drop.
      final pointers = page.softKeyboardFieldPointerCalls;
      await tester.tap(amount());
      await tester.pump();
      expect(page.softKeyboardFieldPointerCalls, greaterThan(pointers));
    },
  );
}

final _now = DateTime.now();
final _today = DateTime(_now.year, _now.month, _now.day);
DateTime _d(int o) => DateTime(_today.year, _today.month, _today.day + o);

final _stream = BudgetStream(
  id: 'a',
  ownerId: 'u1',
  name: 'Everyday',
  seedBalance: Decimal.parse('1000'),
  seedDate: _d(-60),
  lossThreshold: Decimal.zero,
  role: Role.owner,
);

final _txs = [
  BudgetEvent(
    id: 'rent',
    streamId: 'a',
    name: 'Rent',
    direction: EventDirection.debit,
    amount: Decimal.parse('500'),
    startDate: _d(-10),
    recurrenceMode: RecurrenceMode.once,
    endMode: EndMode.never,
  ),
];

class _Repo extends StreamRepository {
  _Repo() : super(ApiClient());
  @override
  Future<StreamList> list() async => StreamList([_stream]);
  @override
  Future<BudgetStream> get(String id) async => _stream;
  @override
  Future<void> markOpened(String id) async {}
  @override
  Future<BalanceSeries> balance(
    String streamId, {
    required DateTime from,
    required DateTime to,
  }) async => BalanceSeries(
    points: [
      for (
        var d = from;
        !d.isAfter(to);
        d = DateTime(d.year, d.month, d.day + 1)
      )
        BalancePoint(date: d, closingBalance: Decimal.parse('1000')),
    ],
    occurrences: const [],
  );
}

class _TxRepo extends EventRepository {
  _TxRepo() : super(ApiClient());
  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async => _txs;
}

Future<void> _pumpPhone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final c = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(user: adminUser),
      ),
      streamRepositoryProvider.overrideWithValue(_Repo()),
      categoryRepositoryProvider.overrideWith(
        (ref) => FakeCategoryRepository(ref.watch(eventRepositoryProvider)),
      ),
      eventRepositoryProvider.overrideWithValue(_TxRepo()),
    ],
  );
  addTearDown(c.dispose);
  await c.read(authProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: TimelinePage(streamId: 'a')),
    ),
  );
  await tester.pumpAndSettle();
}
