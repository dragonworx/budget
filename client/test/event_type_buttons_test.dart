// The event type buttons: the list badges' colours, one row at every
// width (five with Loan), and the same look in a new and a saved event.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/events/event_type_buttons.dart';
import 'package:budget_client/features/events/event_types.dart';
import 'package:budget_client/theme/app_theme.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'loan_editor_test.dart' show pumpEditor;
import 'support/fake_loans.dart';

const _kinds = ['credit', 'debit', 'transfer', 'loan', 'sync'];

BudgetEvent _std(String id, EventDirection dir) => BudgetEvent(
  id: id,
  streamId: 'acc',
  name: 'Home loan',
  direction: dir,
  amount: Decimal.fromInt(50),
  startDate: DateTime(2027, 1, 15),
  recurrenceMode: RecurrenceMode.every,
  interval: 1,
  unit: RecurrenceUnit.months,
  endMode: EndMode.never,
  enabled: true,
  version: 1,
);

void main() {
  test('each type wears its list badge colour', () {
    expect(EventType.credit.color, AppTheme.creditColor);
    expect(EventType.debit.color, AppTheme.debitColor);
    expect(EventType.transfer.color, AppTheme.transferColor);
    expect(EventType.sync.color, AppTheme.syncColor);
    // A loan's row wears the debit badge.
    expect(loanTypeColor, AppTheme.debitColor);
  });

  test('Sync wears a tick, from one shared icon', () {
    expect(syncTypeIcon, Icons.check_rounded);
    expect(EventType.sync.icon, syncTypeIcon);
  });

  testWidgets('a saved sync: tick in the header badge and the selector', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      existing: _std('s', EventDirection.credit).copyWith(kind: 'sync'),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('editor-sync-badge')),
        matching: find.byIcon(syncTypeIcon),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('editor-kind-sync')),
        matching: find.byIcon(syncTypeIcon),
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.sync), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });

  test('one fit rule for a row', () {
    expect(typeButtonFit(560, 5), TypeButtonFit.iconAndLabel);
    expect(typeButtonFit(360, 5), TypeButtonFit.label);
    expect(typeButtonFit(250, 5), TypeButtonFit.icon);
    expect(typeButtonFit(300, 4), TypeButtonFit.label);
  });

  final views = <String, BudgetEvent?>{
    'new': null,
    'credit': _std('c', EventDirection.credit),
    'debit': _std('d', EventDirection.debit),
    'transfer': _std(
      't',
      EventDirection.debit,
    ).copyWith(transfer: const TransferLink(peerStreamId: 'pay')),
    'loan': loanEvent().copyWith(version: 1),
    'sync': _std('s', EventDirection.credit).copyWith(kind: 'sync'),
  };

  for (final width in [320.0, 390.0, 600.0, 844.0, 1200.0]) {
    testWidgets('${width.toInt()}px: one row of five, identical in new and '
        'every saved type', (tester) async {
      Map<String, Object>? first;
      // Errors from anywhere else in the editor (e.g. the footer under the
      // wide test font) are not this test's subject; the type row's must be.
      final rowErrors = <String>[];
      final old = FlutterError.onError;
      FlutterError.onError = (d) {
        final text = d.toString();
        if (text.contains('event_type_buttons.dart')) rowErrors.add(text);
      };
      addTearDown(() => FlutterError.onError = old);
      for (final MapEntry(key: view, value: e) in views.entries) {
        await tester.pumpWidget(const SizedBox()); // a fresh editor state
        await pumpEditor(tester, existing: e, width: width);
        final bar = find.byKey(const ValueKey('editor-kind'));
        final origin = tester.getTopLeft(bar);
        final w = tester.widget<EventTypeButtons<Object?>>(bar);
        final shape = <String, Object>{
          'labels': [for (final b in w.buttons) b.label],
          'icons': [for (final b in w.buttons) b.icon],
          'colours': [for (final b in w.buttons) b.color],
          'size': tester.getSize(bar),
          for (final k in _kinds)
            k: tester
                .getRect(find.byKey(ValueKey('editor-kind-$k')))
                .shift(-origin),
        };
        final tops = {
          for (final k in _kinds)
            tester.getTopLeft(find.byKey(ValueKey('editor-kind-$k'))).dy,
        };
        expect(tops, hasLength(1), reason: '$view: one row');
        for (final k in _kinds) {
          final r = shape[k]! as Rect;
          expect(r.left, greaterThanOrEqualTo(-0.5), reason: '$view $k');
          expect(
            r.right,
            lessThanOrEqualTo((shape['size']! as Size).width + 0.5),
            reason: '$view $k',
          );
        }
        if (first == null) {
          first = shape;
        } else {
          expect(shape, first, reason: '$view looks like new');
        }
        expect(rowErrors, isEmpty, reason: view);
        await tester.pump(const Duration(seconds: 2));
      }
      FlutterError.onError = old;
    });
  }

  testWidgets('a saved loan or sync: the same buttons, none tappable; a '
      'saved series can still switch Credit / Debit / Transfer', (
    tester,
  ) async {
    bool enabled(String k) => tester
        .getSemantics(find.byKey(ValueKey('editor-kind-$k')))
        .flagsCollection
        .isEnabled
        .toBoolOrNull()!;
    final handle = tester.ensureSemantics();
    await pumpEditor(tester, existing: views['sync']);
    expect(
      tester
          .widget<EventTypeButtons<Object?>>(
            find.byKey(const ValueKey('editor-kind')),
          )
          .onTap,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    await pumpEditor(tester, existing: views['debit']);
    expect(
      [for (final k in _kinds) enabled(k)],
      [true, true, true, false, false],
    );
    await tester.pumpWidget(const SizedBox());
    await pumpEditor(tester);
    expect([for (final k in _kinds) enabled(k)], everyElement(isTrue));
    await tester.pumpWidget(const SizedBox());
    await pumpEditor(tester, inStream: [loanEvent()]);
    expect(enabled('loan'), isFalse);
    handle.dispose();
    await tester.pump(const Duration(seconds: 2));
  });
}
