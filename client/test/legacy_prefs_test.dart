// Browser storage from before the Pools/Transactions -> Streams/Events
// rename moves to the new key names once, keeping values.
import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/state/app_prefs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(page.clearLocal);

  test('legacyLocalKey maps old names, leaves others alone', () {
    expect(legacyLocalKey('budget_tx_docked'), 'budget_events_docked');
    expect(
      legacyLocalKey('budgie.prefs.v1.pool.lastTab'),
      'budgie.prefs.v1.stream.lastTab',
    );
    expect(
      legacyLocalKey('budgie.prefs.v1.transactionsPanel.width'),
      'budgie.prefs.v1.eventsPanel.width',
    );
    expect(legacyLocalKey('budget_view:u1:p1'), isNull);
    expect(legacyLocalKey('budgie.prefs.v1.timeline.dockedListWidth'), isNull);
  });

  test('migrateLegacyLocalKeys moves values once; a new key wins', () {
    page.localSet('budget_tx_docked', '0');
    page.localSet('budgie.prefs.v1.poolSplitter', '320.0');
    page.localSet('budgie.prefs.v1.timeline.dockedListWidth', '400.0');
    page.localSet('budget_view:u1:p1', '{"a":1}');
    page.localSet('budget_combine:u1:p1', '["p2"]');
    page.localSet('budgie.prefs.v1.transactionFilter', 'old');
    page.localSet('budgie.prefs.v1.eventFilter', 'new');
    page.localSet('somebody.elses.pool', 'x'); // not ours: untouched

    migrateLegacyLocalKeys();

    expect(page.localGet('budget_events_docked'), '0');
    expect(page.localGet('budget_tx_docked'), isNull);
    expect(page.localGet('budgie.prefs.v1.streamSplitter'), '320.0');
    expect(page.localGet('budgie.prefs.v1.poolSplitter'), isNull);
    expect(page.localGet('budgie.prefs.v1.eventFilter'), 'new');
    expect(page.localGet('budgie.prefs.v1.transactionFilter'), isNull);
    expect(page.localGet('budgie.prefs.v1.timeline.dockedListWidth'), '400.0');
    expect(page.localGet('budget_view:u1:p1'), '{"a":1}');
    expect(page.localGet('budget_combine:u1:p1'), '["p2"]');
    expect(page.localGet('somebody.elses.pool'), 'x');

    // Idempotent.
    final before = {for (final k in page.localKeys()) k: page.localGet(k)};
    migrateLegacyLocalKeys();
    expect({for (final k in page.localKeys()) k: page.localGet(k)}, before);
  });
}
