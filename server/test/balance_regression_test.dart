// Non-loan streams must stay bit-for-bit identical (spec 002): the
// `/balance` and `/insights` JSON the engine produces for a fixture of
// varied streams is compared with golden files recorded from the engine
// as it was before loans (commit 1 of the loan work).
//
// Regenerate (only when a change is meant to alter non-loan output):
//   UPDATE_GOLDENS=1 dart test test/balance_regression_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:budget_server/domain/enums.dart';
import 'package:budget_server/domain/models.dart';
import 'package:budget_server/engine/balance_engine.dart';
import 'package:budget_server/engine/balance_insights.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

DateTime _d(int y, int m, int d) => DateTime.utc(y, m, d);
Decimal _m(String v) => Decimal.parse(v);

BudgetEvent _ev(
  String id,
  String dir,
  String amount,
  DateTime start, {
  RecurrenceMode mode = RecurrenceMode.every,
  int? interval = 1,
  RecurrenceUnit? unit = RecurrenceUnit.months,
  EndMode end = EndMode.never,
  DateTime? endDate,
  int? count,
  bool enabled = true,
  bool hidden = false,
  List<int> days = const [],
  Map<DateTime, AmountOverride> overrides = const {},
  TransferLink? transfer,
  int createdMinute = 0,
}) =>
    BudgetEvent(
      id: id,
      streamId: 's',
      name: id,
      direction: Direction.parse(dir),
      amount: _m(amount),
      startDate: start,
      recurrenceMode: mode,
      interval: mode == RecurrenceMode.once ? null : interval,
      unit: mode == RecurrenceMode.once ? null : unit,
      endMode: end,
      endDate: endDate,
      occurrenceCount: count,
      enabled: enabled,
      categoryHidden: hidden,
      days: days,
      overrides: overrides,
      transfer: transfer,
      createdAt: DateTime.utc(2026, 1, 1, 0, createdMinute),
      categoryId: 'cat',
    );

class _Fixture {
  _Fixture(this.name, this.seedBalance, this.seedDate, this.threshold,
      this.events, this.eventOrder, this.skipped, this.windows);
  final String name;
  final Decimal seedBalance;
  final DateTime seedDate;
  final Decimal threshold;
  final List<BudgetEvent> events;
  final List<String> eventOrder;
  final Map<String, Set<DateTime>> skipped;

  /// (from, to) balance windows; insights use the first window's start.
  final List<(DateTime, DateTime)> windows;
}

List<_Fixture> _fixtures() => [
      _Fixture(
        'one_offs_and_monthly',
        _m('1500.00'),
        _d(2026, 1, 10),
        _m('200'),
        [
          _ev('rent', 'debit', '1200', _d(2026, 1, 15)),
          _ev('salary', 'credit', '2500.50', _d(2026, 1, 28)),
          _ev('bonus', 'credit', '800', _d(2026, 3, 3),
              mode: RecurrenceMode.once),
          _ev('car', 'debit', '4999.99', _d(2026, 6, 30),
              mode: RecurrenceMode.once),
        ],
        const ['salary', 'rent'],
        const {},
        [(_d(2026, 1, 10), _d(2027, 1, 10))],
      ),
      _Fixture(
        'weekly_every_n_days_rules',
        _m('-50'),
        _d(2026, 2, 1),
        _m('0'),
        [
          _ev('coffee', 'debit', '4.50', _d(2026, 2, 2),
              unit: RecurrenceUnit.weeks, days: const [1, 3, 5]),
          _ev('fortnight', 'credit', '1830.25', _d(2026, 2, 5),
              interval: 2, unit: RecurrenceUnit.weeks),
          _ev('daily', 'debit', '1.10', _d(2026, 2, 1),
              interval: 3,
              unit: RecurrenceUnit.days,
              end: EndMode.count,
              count: 40),
          _ev('quarterly', 'debit', '310', _d(2026, 1, 31),
              interval: 3,
              unit: RecurrenceUnit.months,
              end: EndMode.untilDate,
              endDate: _d(2027, 12, 31)),
          _ev('monthdays', 'debit', '60', _d(2026, 2, 1),
              days: const [1, 15, 31]),
          _ev('yearly', 'debit', '900', _d(2026, 2, 29 - 1),
              interval: 1, unit: RecurrenceUnit.years),
        ],
        const [],
        const {},
        [(_d(2026, 2, 1), _d(2028, 3, 1))],
      ),
      _Fixture(
        'overrides_skips_hidden_disabled',
        _m('300'),
        _d(2026, 3, 1),
        _m('-100'),
        [
          _ev('phone', 'debit', '79', _d(2026, 3, 5), overrides: {
            _d(2026, 5, 5):
                AmountOverride(direction: Direction.debit, amount: _m('120')),
            _d(2026, 7, 5):
                AmountOverride(direction: Direction.credit, amount: _m('15')),
          }),
          _ev('gym', 'debit', '25', _d(2026, 3, 2), unit: RecurrenceUnit.weeks),
          _ev('hiddenCat', 'debit', '500', _d(2026, 3, 10), hidden: true),
          _ev('off', 'debit', '9999', _d(2026, 3, 11), enabled: false),
          _ev('pay', 'credit', '400', _d(2026, 3, 14),
              interval: 2, unit: RecurrenceUnit.weeks),
        ],
        const ['pay'],
        {
          'gym': {_d(2026, 3, 9), _d(2026, 4, 6)},
          'phone': {_d(2026, 6, 5)},
        },
        [(_d(2026, 3, 1), _d(2026, 12, 31))],
      ),
      _Fixture(
        'transfers_and_window_after_seed',
        _m('0'),
        _d(2025, 7, 1),
        _m('1000'),
        [
          _ev('toSavings', 'debit', '250', _d(2025, 7, 3),
              unit: RecurrenceUnit.weeks,
              transfer:
                  TransferLink(id: 't1', peerId: 'p1', peerStreamId: 'other')),
          _ev('fromSavings', 'credit', '1000', _d(2026, 1, 3),
              mode: RecurrenceMode.once,
              transfer:
                  TransferLink(id: 't2', peerId: 'p2', peerStreamId: 'other')),
          _ev('wage', 'credit', '1100', _d(2025, 7, 2),
              unit: RecurrenceUnit.weeks, createdMinute: 5),
          _ev('later', 'debit', '42.42', _d(2025, 7, 2),
              unit: RecurrenceUnit.weeks, createdMinute: 2),
        ],
        const [],
        const {},
        [
          (_d(2026, 2, 1), _d(2026, 8, 1)),
          (_d(2025, 1, 1), _d(2025, 7, 20)),
          (_d(2030, 1, 1), _d(2030, 1, 31)),
        ],
      ),
      _Fixture(
        'twenty_years_seven_events',
        _m('12000'),
        _d(2026, 1, 1),
        _m('500'),
        [
          _ev('mortgage', 'debit', '2600', _d(2026, 1, 15)),
          _ev('salary', 'credit', '3100', _d(2026, 1, 8),
              interval: 2, unit: RecurrenceUnit.weeks),
          _ev('groceries', 'debit', '180', _d(2026, 1, 3),
              unit: RecurrenceUnit.weeks),
          _ev('insurance', 'debit', '1450', _d(2026, 4, 1),
              interval: 1, unit: RecurrenceUnit.years),
          _ev('power', 'debit', '390.40', _d(2026, 2, 20),
              interval: 3, unit: RecurrenceUnit.months),
          _ev('netflix', 'debit', '22.99', _d(2026, 1, 31)),
          _ev('tax', 'credit', '1800', _d(2026, 8, 20),
              interval: 12, unit: RecurrenceUnit.months),
        ],
        const ['salary'],
        const {},
        [(_d(2026, 1, 1), _d(2045, 12, 31))],
      ),
      _Fixture(
        'empty_stream',
        _m('77.70'),
        _d(2026, 5, 5),
        _m('100'),
        const [],
        const [],
        const {},
        [(_d(2026, 5, 1), _d(2026, 5, 20))],
      ),
    ];

/// The `/balance` body for one window and the `/insights` body (default
/// days 365 / horizon 1825 from the first window's start), as the routes
/// encode them.
String _snapshot(_Fixture f) {
  final out = <String, Object?>{};
  for (final (from, to) in f.windows) {
    final s = BalanceEngine.compute(
      seedBalance: f.seedBalance,
      seedDate: f.seedDate,
      events: f.events,
      eventOrder: f.eventOrder,
      from: from,
      to: to,
      skipped: f.skipped,
    );
    out['balance ${formatDate(from)}..${formatDate(to)}'] = {
      'points': s.points.map((p) => p.toJson()).toList(),
      'occurrences': s.occurrences.map((o) => o.toJson()).toList(),
    };
  }
  final start = f.windows.first.$1;
  final end = start.add(const Duration(days: 1825));
  final series = BalanceEngine.compute(
    seedBalance: f.seedBalance,
    seedDate: f.seedDate,
    events: f.events,
    eventOrder: f.eventOrder,
    from: start,
    to: end,
    skipped: f.skipped,
  );
  final insights = BalanceInsights.of(
    series.points,
    threshold: f.threshold.toDouble(),
    lowestThrough: start.add(const Duration(days: 364)),
  );
  out['insights'] = {
    'from': formatDate(start),
    'days': 365,
    'horizonDays': 1825,
    'threshold': f.threshold.toString(),
    ...insights.toJson(),
  };
  // One JSON value per line keeps diffs readable.
  return const JsonEncoder.withIndent(' ').convert(out);
}

void main() {
  final update = Platform.environment['UPDATE_GOLDENS'] == '1';
  for (final f in _fixtures()) {
    test('non-loan stream "${f.name}": balance + insights JSON unchanged', () {
      final file = File('test/goldens/balance_regression/${f.name}.json');
      final got = _snapshot(f);
      if (update) {
        file.writeAsStringSync('$got\n');
        return;
      }
      expect(file.existsSync(), isTrue,
          reason: 'golden missing: run with UPDATE_GOLDENS=1');
      expect(got, file.readAsStringSync().trimRight());
    });
  }
}
