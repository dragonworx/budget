import 'package:budget_server/domain/enums.dart';
import 'package:budget_server/domain/models.dart';
import 'package:budget_server/engine/balance_projection.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

BudgetStream _stream() => BudgetStream(
      id: 'a',
      ownerId: 'p',
      name: 'A',
      seedBalance: Decimal.parse('1000'),
      seedDate: DateTime.utc(2026, 1, 1),
      lossThreshold: Decimal.zero,
      displayOrder: 0,
      eventOrder: const [],
    );

BudgetEvent _weekly(String amount, Direction d) => BudgetEvent(
      id: 't$amount',
      streamId: 'a',
      name: 'w',
      direction: d,
      amount: Decimal.parse(amount),
      startDate: DateTime.utc(2026, 1, 5),
      recurrenceMode: RecurrenceMode.every,
      interval: 1,
      unit: RecurrenceUnit.weeks,
      endMode: EndMode.never,
      enabled: true,
      createdAt: DateTime.utc(2026),
    );

void main() {
  test('closeOn includes existing events up to the date', () {
    final close = BalanceProjection.closeOn(
      stream: _stream(),
      events: [_weekly('100', Direction.credit)],
      date: DateTime.utc(2026, 1, 26), // 4 Mondays: 5, 12, 19, 26
    );
    expect(close, Decimal.parse('1400'));
  });

  test('before the seed date the seed balance is used', () {
    final close = BalanceProjection.closeOn(
      stream: _stream(),
      events: [_weekly('100', Direction.debit)],
      date: DateTime.utc(2025, 6, 1),
    );
    expect(close, Decimal.parse('1000'));
  });

  test('gap is target minus projected', () {
    expect(
      BalanceProjection.gap(
          target: Decimal.parse('5000'), projected: Decimal.parse('1400')),
      Decimal.parse('3600'),
    );
  });
}
