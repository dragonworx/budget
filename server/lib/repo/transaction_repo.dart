import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../domain/enums.dart';
import '../domain/models.dart';
import '../domain/transaction_import.dart';

class TransactionRepo {
  TransactionRepo(this._conn);

  final Session _conn;
  final _uuid = const Uuid();

  Future<List<Transaction>> listByAccount(String accountId) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT id, account_id, name, direction, amount, start_date,
               recurrence_mode, interval, unit, end_mode, end_date,
               occurrence_count, enabled, created_at
        FROM transactions
        WHERE account_id = @accountId
        ORDER BY created_at ASC
      '''),
      parameters: {'accountId': accountId},
    );
    return rows.map(_fromRow).toList();
  }

  Future<Transaction?> get(String id) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT id, account_id, name, direction, amount, start_date,
               recurrence_mode, interval, unit, end_mode, end_date,
               occurrence_count, enabled, created_at
        FROM transactions WHERE id = @id
      '''),
      parameters: {'id': id},
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<Transaction> create({
    required String accountId,
    required String name,
    required Direction direction,
    required Decimal amount,
    required DateTime startDate,
    required RecurrenceMode recurrenceMode,
    int? interval,
    RecurrenceUnit? unit,
    required EndMode endMode,
    DateTime? endDate,
    int? occurrenceCount,
    bool enabled = true,
  }) async {
    _validateShape(
      recurrenceMode: recurrenceMode,
      interval: interval,
      unit: unit,
      endMode: endMode,
      endDate: endDate,
      occurrenceCount: occurrenceCount,
      amount: amount,
    );

    final id = _uuid.v4();
    final rows = await _conn.execute(
      Sql.named('''
        INSERT INTO transactions (
          id, account_id, name, direction, amount, start_date,
          recurrence_mode, interval, unit, end_mode, end_date,
          occurrence_count, enabled
        ) VALUES (
          @id, @accountId, @name, @direction, @amount, @startDate,
          @recurrenceMode, @interval, @unit, @endMode, @endDate,
          @occurrenceCount, @enabled
        )
        RETURNING id, account_id, name, direction, amount, start_date,
                  recurrence_mode, interval, unit, end_mode, end_date,
                  occurrence_count, enabled, created_at
      '''),
      parameters: {
        'id': id,
        'accountId': accountId,
        'name': name,
        'direction': direction.name,
        'amount': amount.toString(),
        'startDate': _date(startDate),
        'recurrenceMode': recurrenceMode.name,
        'interval': interval,
        'unit': unit?.name,
        'endMode': endMode.apiName,
        'endDate': endDate == null ? null : _date(endDate),
        'occurrenceCount': occurrenceCount,
        'enabled': enabled,
      },
    );

    // Append to account transaction_order.
    await _conn.execute(
      Sql.named('''
        UPDATE accounts
        SET transaction_order = array_append(transaction_order, @transactionId::uuid)
        WHERE id = @accountId
          AND NOT (@transactionId::uuid = ANY (transaction_order))
      '''),
      parameters: {'accountId': accountId, 'transactionId': id},
    );

    return _fromRow(rows.first);
  }

  Future<Transaction?> update(
    String id, {
    String? name,
    Direction? direction,
    Decimal? amount,
    DateTime? startDate,
    RecurrenceMode? recurrenceMode,
    int? interval,
    RecurrenceUnit? unit,
    EndMode? endMode,
    DateTime? endDate,
    int? occurrenceCount,
    bool? enabled,
    bool clearInterval = false,
    bool clearUnit = false,
    bool clearEndDate = false,
    bool clearOccurrenceCount = false,
  }) async {
    final existing = await get(id);
    if (existing == null) return null;

    final nextMode = recurrenceMode ?? existing.recurrenceMode;
    final nextEnd = endMode ?? existing.endMode;
    final nextInterval = clearInterval ? null : (interval ?? existing.interval);
    final nextUnit = clearUnit ? null : (unit ?? existing.unit);
    final nextEndDate = clearEndDate ? null : (endDate ?? existing.endDate);
    final nextCount = clearOccurrenceCount
        ? null
        : (occurrenceCount ?? existing.occurrenceCount);
    final nextAmount = amount ?? existing.amount;

    _validateShape(
      recurrenceMode: nextMode,
      interval: nextInterval,
      unit: nextUnit,
      endMode: nextEnd,
      endDate: nextEndDate,
      occurrenceCount: nextCount,
      amount: nextAmount,
    );

    final rows = await _conn.execute(
      Sql.named('''
        UPDATE transactions SET
          name = @name,
          direction = @direction,
          amount = @amount,
          start_date = @startDate,
          recurrence_mode = @recurrenceMode,
          interval = @interval,
          unit = @unit,
          end_mode = @endMode,
          end_date = @endDate,
          occurrence_count = @occurrenceCount,
          enabled = @enabled
        WHERE id = @id
        RETURNING id, account_id, name, direction, amount, start_date,
                  recurrence_mode, interval, unit, end_mode, end_date,
                  occurrence_count, enabled, created_at
      '''),
      parameters: {
        'id': id,
        'name': name ?? existing.name,
        'direction': (direction ?? existing.direction).name,
        'amount': nextAmount.toString(),
        'startDate': _date(startDate ?? existing.startDate),
        'recurrenceMode': nextMode.name,
        'interval': nextInterval,
        'unit': nextUnit?.name,
        'endMode': nextEnd.apiName,
        'endDate': nextEndDate == null ? null : _date(nextEndDate),
        'occurrenceCount': nextCount,
        'enabled': enabled ?? existing.enabled,
      },
    );
    return _fromRow(rows.first);
  }

  Future<bool> delete(String id) async {
    final existing = await get(id);
    if (existing == null) return false;
    await _conn.execute(
      Sql.named('''
        UPDATE accounts
        SET transaction_order = array_remove(transaction_order, @transactionId::uuid)
        WHERE id = @accountId
      '''),
      parameters: {
        'accountId': existing.accountId,
        'transactionId': id,
      },
    );
    final rows = await _conn.execute(
      Sql.named('DELETE FROM transactions WHERE id = @id RETURNING id'),
      parameters: {'id': id},
    );
    return rows.isNotEmpty;
  }

  /// Inserts validated import [items] into [accountId]. Call inside a DB
  /// transaction (all-or-nothing). Items whose `id` already exists in this
  /// account are skipped unchanged (idempotent re-import); an `id` owned by
  /// another account is an error. New rows are appended to the account's
  /// transaction_order in array order; skippedDates go to skipped_occurrences.
  Future<({List<String> created, List<String> skipped})> importItems(
    String accountId,
    List<ImportItem> items,
  ) async {
    final ids = [
      for (final i in items)
        if (i.id != null) i.id!
    ];
    final owners = <String, String>{};
    if (ids.isNotEmpty) {
      final rows = await _conn.execute(
        Sql.named(
            'SELECT id::text, account_id::text FROM transactions WHERE id = ANY (@ids::uuid[])'),
        parameters: {'ids': ids},
      );
      for (final r in rows) {
        owners[r[0] as String] = r[1] as String;
      }
    }
    final conflicts = [
      for (final i in items)
        if (i.id != null && owners[i.id] != null && owners[i.id] != accountId)
          ImportIssue(i.index, 'id',
              'already used by a transaction in another account'),
    ];
    if (conflicts.isNotEmpty) throw ImportValidationException(conflicts);

    final created = <String>[], skipped = <String>[];
    for (final item in items) {
      if (item.id != null && owners.containsKey(item.id)) {
        skipped.add(item.id!);
        continue;
      }
      _validateShape(
        recurrenceMode: item.recurrenceMode,
        interval: item.interval,
        unit: item.unit,
        endMode: item.endMode,
        endDate: item.endDate,
        occurrenceCount: item.occurrenceCount,
        amount: item.amount,
      );
      final id = item.id ?? _uuid.v4();
      await _conn.execute(
        Sql.named('''
          INSERT INTO transactions (
            id, account_id, name, direction, amount, start_date,
            recurrence_mode, interval, unit, end_mode, end_date,
            occurrence_count, enabled
          ) VALUES (
            @id, @accountId, @name, @direction, @amount, @startDate,
            @recurrenceMode, @interval, @unit, @endMode, @endDate,
            @occurrenceCount, @enabled
          )
        '''),
        parameters: {
          'id': id,
          'accountId': accountId,
          'name': item.name,
          'direction': item.direction.name,
          'amount': item.amount.toString(),
          'startDate': _date(item.startDate),
          'recurrenceMode': item.recurrenceMode.name,
          'interval': item.interval,
          'unit': item.unit?.name,
          'endMode': item.endMode.apiName,
          'endDate': item.endDate == null ? null : _date(item.endDate!),
          'occurrenceCount': item.occurrenceCount,
          'enabled': item.enabled,
        },
      );
      for (final d in item.skippedDates) {
        await setSkip(id, d, true);
      }
      created.add(id);
    }
    if (created.isNotEmpty) {
      await _conn.execute(
        Sql.named('''
          UPDATE accounts
          SET transaction_order = transaction_order || @ids::uuid[]
          WHERE id = @accountId
        '''),
        parameters: {'accountId': accountId, 'ids': created},
      );
    }
    return (created: created, skipped: skipped);
  }

  Future<void> setSkip(
      String transactionId, DateTime date, bool skipped) async {
    final d = _date(date);
    if (skipped) {
      await _conn.execute(
        Sql.named('''
          INSERT INTO skipped_occurrences (transaction_id, date)
          VALUES (@transactionId, @date)
          ON CONFLICT DO NOTHING
        '''),
        parameters: {'transactionId': transactionId, 'date': d},
      );
    } else {
      await _conn.execute(
        Sql.named('''
          DELETE FROM skipped_occurrences
          WHERE transaction_id = @transactionId AND date = @date
        '''),
        parameters: {'transactionId': transactionId, 'date': d},
      );
    }
  }

  Future<Map<String, Set<DateTime>>> skipsForAccount(String accountId) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT s.transaction_id, s.date
        FROM skipped_occurrences s
        JOIN transactions st ON st.id = s.transaction_id
        WHERE st.account_id = @accountId
      '''),
      parameters: {'accountId': accountId},
    );
    final map = <String, Set<DateTime>>{};
    for (final row in rows) {
      final transactionId = row[0].toString();
      final date = row[1] as DateTime;
      map
          .putIfAbsent(transactionId, () => <DateTime>{})
          .add(DateTime.utc(date.year, date.month, date.day));
    }
    return map;
  }

  void _validateShape({
    required RecurrenceMode recurrenceMode,
    required int? interval,
    required RecurrenceUnit? unit,
    required EndMode endMode,
    required DateTime? endDate,
    required int? occurrenceCount,
    required Decimal amount,
  }) {
    if (amount < Decimal.zero) {
      throw FormatException('amount must be >= 0');
    }
    if (recurrenceMode == RecurrenceMode.once) {
      if (interval != null || unit != null) {
        throw FormatException('once transactions must not set interval/unit');
      }
    } else {
      if (interval == null || interval < 1) {
        throw FormatException('interval must be >= 1');
      }
      if (unit == null) {
        throw FormatException('unit is required for every transactions');
      }
    }

    switch (endMode) {
      case EndMode.never:
        if (endDate != null || occurrenceCount != null) {
          throw FormatException('never end mode must not set endDate/count');
        }
      case EndMode.untilDate:
        if (endDate == null) {
          throw FormatException('until_date requires endDate');
        }
        if (occurrenceCount != null) {
          throw FormatException('until_date must not set occurrenceCount');
        }
      case EndMode.count:
        if (occurrenceCount == null || occurrenceCount < 1) {
          throw FormatException('count end mode requires occurrenceCount >= 1');
        }
        if (endDate != null) {
          throw FormatException('count must not set endDate');
        }
    }
  }

  DateTime _date(DateTime d) => DateTime.utc(d.year, d.month, d.day);

  Transaction _fromRow(ResultRow row) {
    final start = row[5] as DateTime;
    final endRaw = row[10];
    DateTime? endDate;
    if (endRaw != null) {
      final e = endRaw as DateTime;
      endDate = DateTime.utc(e.year, e.month, e.day);
    }
    final unitRaw = row[8] as String?;
    return Transaction(
      id: row[0].toString(),
      accountId: row[1].toString(),
      name: row[2] as String,
      direction: Direction.parse(row[3] as String),
      amount: Decimal.parse(row[4].toString()),
      startDate: DateTime.utc(start.year, start.month, start.day),
      recurrenceMode: RecurrenceMode.parse(row[6] as String),
      interval: row[7] as int?,
      unit: unitRaw == null ? null : RecurrenceUnit.parse(unitRaw),
      endMode: EndMode.parse(row[9] as String),
      endDate: endDate,
      occurrenceCount: row[11] as int?,
      enabled: row[12] as bool,
      createdAt: (row[13] as DateTime).toUtc(),
    );
  }
}
