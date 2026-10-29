// The Events list's compact rows: exactly two lines of text (name + amount,
// then frequency · start, with transfer / end appended while they fit),
// one consistent height, no overflow with long names or amounts, a colour
// bar in the event's graph colour, and a semantics label that still says
// everything (including what the second line ellipsised).
import 'dart:math' as math;

import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/events/events_panel.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/theme/app_theme.dart';
import 'package:budget_client/widgets/money_text.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_categories.dart';

final _stream = BudgetStream(
  id: 'p',
  ownerId: 'u1',
  name: 'Everyday',
  seedBalance: Decimal.parse('1000'),
  seedDate: DateTime(2026, 1, 1),
  lossThreshold: Decimal.zero,
  role: Role.owner,
);

BudgetEvent _ev(
  String id, {
  String? name,
  String amount = '25',
  EventDirection dir = EventDirection.debit,
  RecurrenceMode mode = RecurrenceMode.every,
  int interval = 1,
  RecurrenceUnit unit = RecurrenceUnit.months,
  EndMode end = EndMode.never,
  DateTime? endDate,
  int? count,
  bool enabled = true,
  TransferLink? transfer,
  String? color,
  DateTime? start,
  List<int> days = const [],
}) => BudgetEvent(
  id: id,
  streamId: 'p',
  name: name ?? id,
  direction: dir,
  amount: Decimal.parse(amount),
  startDate: start ?? DateTime(2026, 11, 5),
  days: days,
  recurrenceMode: mode,
  interval: mode == RecurrenceMode.once ? null : interval,
  unit: mode == RecurrenceMode.once ? null : unit,
  endMode: end,
  endDate: endDate,
  occurrenceCount: count,
  enabled: enabled,
  transfer: transfer,
  color: color,
);

final _long =
    'An extraordinarily long event name that would never fit on one line '
    'of a phone, even sideways, with more words after it';

final _items = [
  _ev('rent', name: 'Rent', amount: '2100', color: '#B8488E'),
  _ev(
    'wages',
    name: 'Wages',
    amount: '1800',
    dir: EventDirection.credit,
    interval: 2,
    unit: RecurrenceUnit.weeks,
  ),
  _ev('once', name: 'Car rego', mode: RecurrenceMode.once, amount: '880'),
  _ev(
    'save',
    name: 'Save',
    amount: '500',
    end: EndMode.untilDate,
    endDate: DateTime(2027, 6, 30),
    transfer: const TransferLink(peerStreamId: 's', peerStreamName: 'Savings'),
  ),
  _ev(
    'gym',
    name: 'Gym',
    amount: '60',
    enabled: false,
    count: 12,
    end: EndMode.count,
  ),
  _ev('long', name: _long, amount: '123456789.99'),
  _ev(
    'longx',
    name: _long,
    amount: '98765.43',
    transfer: const TransferLink(peerStreamId: 's', peerStreamName: 'Savings'),
  ),
  _ev(
    'topup',
    name: 'Top up',
    amount: '75',
    dir: EventDirection.credit,
    transfer: const TransferLink(
      peerStreamId: 'h',
      peerStreamName: 'The family holiday and emergency fund account',
    ),
  ),
];

/// Structured rules (rule + days) for line 2.
final _structured = [
  _ev(
    'monTue',
    name: 'Gym class',
    unit: RecurrenceUnit.weeks,
    days: const [2, 1],
    start: DateTime(2026, 10, 8),
  ),
  _ev('m115', name: 'Pay', days: const [15, 1], start: DateTime(2026, 10, 8)),
  _ev(
    'm31',
    name: 'Quarterly',
    interval: 3,
    days: const [31],
    start: DateTime(2026, 10, 8),
    end: EndMode.count,
    count: 4,
  ),
];

class _StreamRepo extends StreamRepository {
  _StreamRepo() : super(ApiClient());
  @override
  Future<BudgetStream> get(String id) async => _stream;
}

class _EventRepo extends EventRepository {
  _EventRepo([this.items]) : super(ApiClient());
  final List<BudgetEvent>? items;
  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async =>
      items ?? _items;
}

Future<void> _pump(
  WidgetTester tester,
  Size size, [
  List<BudgetEvent>? items,
]) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        streamRepositoryProvider.overrideWithValue(_StreamRepo()),
        categoryRepositoryProvider.overrideWith(
          (ref) => FakeCategoryRepository(ref.watch(eventRepositoryProvider)),
        ),
        eventRepositoryProvider.overrideWithValue(_EventRepo(items)),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: EventsPanel(
            stream: _stream,
            skipsFor: (_) => const {},
            onPanelClosed: (_) {},
            onChanged: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _row(String id) => find
    .ancestor(
      of: find.byKey(ValueKey('row-line1-$id')),
      matching: find.byType(InkWell),
    )
    .first;

/// The row's text (icons are glyphs in RichText too: skipped).
List<String> _texts(WidgetTester tester, String id) => [
  for (final w in tester.widgetList<RichText>(
    find.descendant(of: _row(id), matching: find.byType(RichText)),
  ))
    if (w.text.style?.fontFamily != 'MaterialIcons') w.text.toPlainText(),
];

String _line2(WidgetTester tester, String id) => tester
    .widget<RichText>(
      find.descendant(
        of: find.byKey(ValueKey('row-line2-$id')),
        matching: find.byType(RichText),
      ),
    )
    .text
    .toPlainText();

void main() {
  for (final (label, size) in [
    ('phone', const Size(390, 844)),
    ('desktop', const Size(1440, 900)),
  ]) {
    testWidgets('$label: line 2 renders the structured rule, in two lines', (
      tester,
    ) async {
      await _pump(tester, size, _structured);
      // Built from the structured rule (rule + days).
      expect(
        _line2(tester, 'monTue'),
        'Every week on Mon, Tue · from 8 Oct 2026',
      );
      expect(
        _line2(tester, 'm115'),
        'Monthly on the 1st and 15th · from 8 Oct 2026',
      );
      expect(
        _line2(tester, 'm31'),
        'Every 3 months on the 31st · from 8 Oct 2026 · 4 times',
      );
      for (final t in _structured) {
        for (final key in ['row-line1-${t.id}', 'row-line2-${t.id}']) {
          expect(
            tester.getSize(find.byKey(ValueKey(key))).height,
            lessThan(24),
            reason: key,
          );
        }
      }
    });
  }

  test('rowDetail of a weekly Mon/Tue rule', () {
    final d = rowDetail(_structured.first);
    expect(d.frequency, 'Every week on Mon, Tue');
    expect(d.start, 'from 8 Oct 2026');
  });

  test('frequencyLabel: the structured rule\'s phrase', () {
    expect(frequencyLabel(_ev('a', mode: RecurrenceMode.once)), 'Once');
    expect(frequencyLabel(_ev('a', unit: RecurrenceUnit.days)), 'Every day');
    expect(frequencyLabel(_ev('a', unit: RecurrenceUnit.weeks)), 'Every week');
    expect(frequencyLabel(_ev('a')), 'Monthly');
    expect(frequencyLabel(_ev('a', unit: RecurrenceUnit.years)), 'Yearly');
    expect(
      frequencyLabel(_ev('a', interval: 2, unit: RecurrenceUnit.weeks)),
      'Every 2 weeks',
    );
    expect(
      frequencyLabel(_ev('a', interval: 3, unit: RecurrenceUnit.months)),
      'Every 3 months',
    );
  });

  test('rowDetail: start, transfer and end parts', () {
    final save = rowDetail(_items[3]);
    expect(save.frequency, 'Monthly');
    expect(save.start, 'from 5 Nov 2026');
    expect(save.transfer, 'To: Savings');
    expect(save.end, 'until 30 Jun 2027');
    expect(rowDetail(_items[4]).end, '12 times');
    final once = rowDetail(_items[2]);
    expect(once.start, '5 Nov 2026');
    expect(once.end, isNull);
    expect(once.transfer, isNull);
  });

  for (final (label, size) in [
    ('phone', const Size(390, 844)),
    ('desktop', const Size(1440, 900)),
  ]) {
    testWidgets('$label: every row has exactly two lines of text', (
      tester,
    ) async {
      await _pump(tester, size);
      expect(_texts(tester, 'rent'), [
        'Rent',
        formatSignedAmount(-2100),
        anything,
      ]);
      for (final t in _items) {
        // Every piece of text is on line 1 (name, amount) or line 2, and
        // the two lines sit one above the other: two rows of text.
        final texts = _texts(tester, t.id);
        final onLines = [
          for (final k in ['row-line1-${t.id}', 'row-line2-${t.id}'])
            for (final w in tester.widgetList<RichText>(
              find.descendant(
                of: find.byKey(ValueKey(k)),
                matching: find.byType(RichText),
              ),
            ))
              w.text.toPlainText(),
        ];
        expect(
          texts,
          hasLength(t.isTransfer ? 4 : 3),
          reason: '${t.id}: $texts',
        );
        expect(onLines, texts, reason: t.id);
        final bands = {
          for (final w
              in find
                  .descendant(of: _row(t.id), matching: find.byType(RichText))
                  .evaluate())
            if ((w.widget as RichText).text.style?.fontFamily !=
                'MaterialIcons')
              tester.getCenter(find.byWidget(w.widget)).dy.round() ~/ 12,
        };
        expect(bands, hasLength(2), reason: '${t.id}: $bands');
        // Each line is one line high.
        for (final key in ['row-line1-${t.id}', 'row-line2-${t.id}']) {
          expect(
            tester.getSize(find.byKey(ValueKey(key))).height,
            lessThan(24),
            reason: key,
          );
        }
      }
      expect(_line2(tester, 'rent'), 'Monthly · from 5 Nov 2026');
      expect(_line2(tester, 'wages'), 'Every 2 weeks · from 5 Nov 2026');
      expect(_line2(tester, 'once'), 'Once · 5 Nov 2026');
      expect(
        _line2(tester, 'save'),
        'Monthly · from 5 Nov 2026 · until 30 Jun 2027',
      );
      expect(_line2(tester, 'gym'), 'Monthly · from 5 Nov 2026 · 12 times');
      expect(find.text('Started 5 Nov 2026'), findsNothing);
    });

    testWidgets('$label: compact, equal-height rows; long names never '
        'overflow and the amount stays whole', (tester) async {
      await _pump(tester, size);
      expect(tester.takeException(), isNull);
      final heights = {
        for (final t in _items) tester.getSize(_row(t.id)).height,
      };
      expect(heights, hasLength(1), reason: '$heights');
      expect(heights.single, lessThanOrEqualTo(size.width < 600 ? 54 : 48));
      final row = tester.getRect(_row('long'));
      final name = tester.getRect(
        find.descendant(
          of: find.byKey(const ValueKey('row-line1-long')),
          matching: find.text(_long),
        ),
      );
      final amount = tester.getRect(
        find.byKey(const ValueKey('row-amount-long')),
      );
      expect(name.right, lessThanOrEqualTo(amount.left));
      expect(amount.right, lessThanOrEqualTo(row.right));
      final para = tester.renderObject<RenderParagraph>(
        find
            .descendant(
              of: find.byKey(const ValueKey('row-line1-long')),
              matching: find.byType(RichText),
            )
            .first,
      );
      expect(para.didExceedMaxLines, isTrue); // ellipsised, one line
      // The amount is the whole string, scaled if need be, never cut.
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('row-amount-long'))).data,
        formatSignedAmount(-123456789.99),
      );
    });

    testWidgets('$label: semantics still say everything', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, size);
      expect(
        find.bySemanticsLabel(
          RegExp(
            '^Save, transfer, To: Savings, '
            '${RegExp.escape(formatSignedAmount(-500))}, Monthly, from 5 Nov 2026, until 30 Jun 2027, '
            r'(next|ended) \w{3} \d+ \w{3} \d{4}$',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^Gym, .*excluded from balance$')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'Car rego, ${formatSignedAmount(-880)}, Once, on 5 Nov 2026',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  }

  for (final (label, size) in [
    ('phone', const Size(390, 844)),
    ('narrow phone (320 wide)', const Size(320, 1100)),
    ('desktop', const Size(1440, 900)),
  ]) {
    testWidgets('$label: a transfer\'s other stream sits on line 1 right '
        'after the name; the name ellipsises first, the amount stays whole', (
      tester,
    ) async {
      await _pump(tester, size);
      expect(tester.takeException(), isNull);
      Rect r(String key) => tester.getRect(find.byKey(ValueKey(key)));
      bool cut(Finder f) => tester
          .renderObject<RenderParagraph>(
            find.descendant(of: f, matching: find.byType(RichText)),
          )
          .didExceedMaxLines;
      for (final id in ['save', 'longx', 'topup']) {
        final line1 = find.byKey(ValueKey('row-line1-$id'));
        final transfer = find.byKey(ValueKey('row-transfer-$id'));
        expect(
          find.descendant(of: line1, matching: transfer),
          findsOneWidget,
          reason: id,
        );
        final name = find
            .descendant(of: line1, matching: find.byType(Text))
            .first;
        final n = tester.getRect(name);
        final x = r('row-transfer-$id');
        final a = r('row-amount-$id');
        final row = tester.getRect(_row(id));
        expect(n.right, lessThanOrEqualTo(x.left), reason: id);
        expect(x.right, lessThanOrEqualTo(a.left), reason: id);
        expect(a.right, lessThanOrEqualTo(row.right), reason: id);
        expect((x.center.dy - n.center.dy).abs(), lessThan(4), reason: id);
        // Line 2 no longer repeats it.
        expect(_line2(tester, id), isNot(contains('Savings')));
      }
      // The stream gets all it needs, up to all but 54px (or 30% of a
      // cramped line) of it, so the name keeps a few letters; the name is
      // what ellipsises.
      for (final id in ['longx', 'topup']) {
        final key = ValueKey('row-transfer-$id');
        final para = tester.renderObject<RenderParagraph>(
          find.descendant(of: find.byKey(key), matching: find.byType(RichText)),
        );
        final want = para.getMaxIntrinsicWidth(double.infinity);
        final line = tester
            .getRect(
              find
                  .ancestor(
                    of: find.byKey(key),
                    matching: find.byType(LayoutBuilder),
                  )
                  .first,
            )
            .width;
        final cap = math.max(0, line - 6 - math.min(48, (line - 6) * 0.3));
        final x = tester.getRect(find.byKey(key)).width;
        expect(x, closeTo(math.min(want, cap), 1), reason: id);
        expect(para.didExceedMaxLines, want > cap + 0.5, reason: id);
        final name = tester
            .getRect(
              find
                  .descendant(
                    of: find.byKey(ValueKey('row-line1-$id')),
                    matching: find.byType(Text),
                  )
                  .first,
            )
            .width;
        expect(name, greaterThanOrEqualTo(math.min(47.5, line - x - 6.5)));
        expect(x, lessThanOrEqualTo(line - 6 + 0.5));
        expect(x, greaterThan(0), reason: '$id: the stream always shows');
      }
      expect(
        cut(
          find.descendant(
            of: find.byKey(const ValueKey('row-line1-longx')),
            matching: find.text(_long),
          ),
        ),
        isTrue,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('row-transfer-longx')))
            .data,
        'To: Savings',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('row-transfer-topup')))
            .data,
        'From: The family holiday and emergency fund account',
      );
      final mine = tester.widget<Text>(
        find.byKey(const ValueKey('row-transfer-save')),
      );
      expect(mine.style?.color, AppTheme.transferColor);
    });
  }

  testWidgets('the colour bar wears the event\'s graph colour; a transfer '
      'shows ⇄ and an excluded row is dimmed', (tester) async {
    await _pump(tester, const Size(1440, 900));
    Color bar(String id) =>
        ((tester.widget<Container>(find.byKey(ValueKey('row-colour-$id'))))
                    .decoration!
                as BoxDecoration)
            .color!;
    expect(bar('rent'), const Color(0xFFB8488E));
    expect(bar('gym').a, lessThan(0.5));
    expect(
      find.descendant(
        of: _row('save'),
        matching: find.byIcon(Icons.swap_horiz_rounded),
      ),
      findsOneWidget,
    );
    final gym = tester.widget<RichText>(
      find.descendant(of: find.text('Gym'), matching: find.byType(RichText)),
    );
    expect(gym.text.style?.color, AppTheme.textFaint);
  });
}
