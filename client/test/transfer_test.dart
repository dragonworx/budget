import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/events/event_editor.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/widgets/stream_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_streams.dart';

final _streams = [
  testStream('a', 'Everyday'),
  testStream('s', 'Savings'),
  testStream('b', 'Ops', shared: true, role: Role.editor, ownerName: 'Sam'),
  testStream('v', 'Kids', shared: true, role: Role.viewer, ownerName: 'Sam'),
];

FakeStreamRepository _repo() =>
    FakeStreamRepository(streams: List.of(_streams));

class _Txs extends EventRepository {
  _Txs() : super(ApiClient());
  final created = <Map<String, dynamic>>[];
  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async => [];
  @override
  Future<BudgetEvent> create(String streamId, BudgetEvent draft) async {
    created.add(draft.toCreateJson());
    return draft;
  }
}

BudgetEvent _transfer(EventDirection dir, String peer) => BudgetEvent.fromJson({
  'id': 't1',
  'streamId': 'a',
  'name': 'Save',
  'direction': dir.name,
  'amount': '10',
  'startDate': '2026-10-20',
  'recurrenceMode': 'once',
  'endMode': 'never',
  'transfer': {
    'id': 'x',
    'peerEventId': 't2',
    'peerStreamId': 'b',
    'peerStreamName': peer,
  },
});

void main() {
  test('transfer JSON parses and patches carry the destination', () {
    final t = _transfer(EventDirection.debit, 'Ops');
    expect(t.isTransfer, isTrue);
    expect(t.transfer!.peerStreamName, 'Ops');
    expect(t.toCreateJson()['transferToStreamId'], 'b');
    expect(eventLabel(t), 'Save · To: Ops');
    expect(
      eventLabel(_transfer(EventDirection.credit, 'Ops')),
      'Save · From: Ops',
    );
    expect(
      transferPhrase(_transfer(EventDirection.credit, 'Ops')),
      'From: Ops',
    );
    expect(transferPhrase(t), 'To: Ops');
    // An unnamed incoming transfer reads just "From: <stream>".
    expect(
      eventLabel(_transfer(EventDirection.credit, 'Ops').copyWith(name: '')),
      'From: Ops',
    );
    // A plain series explicitly sends null (unlinks on patch).
    final plain = t.copyWith(clearTransfer: true);
    expect(plain.toCreateJson().containsKey('transferToStreamId'), isTrue);
    expect(plain.toCreateJson()['transferToStreamId'], isNull);
    expect(eventLabel(plain), 'Save');
  });

  Future<_Txs> pumpEditor(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final txs = _Txs();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamRepositoryProvider.overrideWithValue(_repo()),
          eventRepositoryProvider.overrideWithValue(txs),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: EventEditor(
              streamId: 'a',
              initialDate: DateTime(2026, 10, 20),
              onDone: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('editor-name')), 'Save');
    await tester.enterText(find.byKey(const ValueKey('editor-amount')), '10');
    await tester.tap(find.byKey(const ValueKey('editor-kind-transfer')));
    await tester.pumpAndSettle();
    expect(find.text('To stream'), findsOneWidget);
    expect(find.text('Solve from a target total…'), findsNothing);
    return txs;
  }

  testWidgets('desktop: Transfer offers every stream I can edit except the '
      'source, mine then shared', (tester) async {
    final txs = await pumpEditor(tester, const Size(1200, 1600));
    // Saving without a destination is blocked.
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('Pick the other stream'), findsOneWidget);
    expect(txs.created, isEmpty);

    await tester.tap(find.byKey(const ValueKey('editor-transfer-stream')));
    await tester.pumpAndSettle();
    expect(find.byType(SubmenuButton), findsNothing);
    expect(find.byKey(const ValueKey('transfer-header-mine')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('transfer-header-shared')),
      findsOneWidget,
    );
    // Headers are not focusable menu items.
    expect(
      find.ancestor(
        of: find.text('Shared with me'),
        matching: find.byType(MenuItemButton),
      ),
      findsNothing,
    );
    // The source and read-only streams are not offered.
    expect(find.byKey(const ValueKey('transfer-stream-a')), findsNothing);
    expect(find.byKey(const ValueKey('transfer-stream-v')), findsNothing);
    expect(find.byKey(const ValueKey('transfer-stream-s')), findsOneWidget);
    expect(find.byKey(const ValueKey('transfer-new-stream')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('transfer-stream-b')));
    await tester.pumpAndSettle();
    expect(find.text('To: Ops'), findsOneWidget);
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(txs.created.single['transferToStreamId'], 'b');
    expect(txs.created.single['direction'], 'debit');
  });

  testWidgets('phone: the transfer picker is an on-screen dropdown', (
    tester,
  ) async {
    await pumpEditor(tester, const Size(390, 1600));
    await tester.tap(find.byKey(const ValueKey('editor-transfer-stream')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Projects:'), findsNothing);
    expect(find.byKey(const ValueKey('transfer-stream-a')), findsNothing);
    final item = tester.getRect(
      find.byKey(const ValueKey('transfer-stream-s')),
    );
    expect(item.right, lessThanOrEqualTo(390));
    expect(item.height, greaterThanOrEqualTo(44));
    await tester.tap(find.byKey(const ValueKey('transfer-stream-s')));
    await tester.pumpAndSettle();
    expect(find.text('To: Savings'), findsOneWidget);
  });

  testWidgets('StreamPicker marks the current stream', (tester) async {
    BudgetStream? picked;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [streamRepositoryProvider.overrideWithValue(_repo())],
        child: MaterialApp(
          home: Scaffold(
            body: StreamPicker(
              keyPrefix: 'nav',
              currentStreamId: 'a',
              onSelected: (a) => picked = a,
              builder: (context, open) =>
                  TextButton(onPressed: open, child: const Text('Jump')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Jump'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nav-stream-s')));
    await tester.pumpAndSettle();
    expect(picked?.id, 's');
  });
}
