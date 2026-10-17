import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../domain/enums.dart';
import '../domain/models.dart';
import '../domain/transaction_import.dart';

const _enrichedCols = '''
  t.id, t.account_id, t.name, t.direction, t.amount, t.start_date,
  t.recurrence_mode, t.interval, t.unit, t.end_mode, t.end_date,
  t.occurrence_count, t.enabled, t.created_at, t.transfer_id,
  p.id, pa.id, pa.name, pp.id, pp.name''';
const _peerJoin = '''
  LEFT JOIN transactions p
    ON t.transfer_id IS NOT NULL AND p.transfer_id = t.transfer_id AND p.id <> t.id
  LEFT JOIN accounts pa ON pa.id = p.account_id
  LEFT JOIN projects pp ON pp.id = pa.project_id''';

class TransactionRepo {
  TransactionRepo(this._conn);

  final Session _conn;
  final _uuid = const Uuid();

  Future<List<Transaction>> listByAccount(String accountId) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT $_enrichedCols
        FROM transactions t $_peerJoin
        WHERE t.account_id = @accountId
        ORDER BY t.created_at ASC
      '''),
      parameters: {'accountId': accountId},
    );
    return rows.map(_fromRow).toList();
  }

  Future<Transaction?> get(String id) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT $_enrichedCols
        FROM transactions t $_peerJoin
        WHERE t.id = @id
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
    String? transferId,
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
    await _conn.execute(
      Sql.named('''
        INSERT INTO transactions (
          id, account_id, name, direction, amount, start_date,
          recurrence_mode, interval, unit, end_mode, end_date,
          occurrence_count, enabled, transfer_id
        ) VALUES (
          @id, @accountId, @name, @direction, @amount, @startDate,
          @recurrenceMode, @interval, @unit, @endMode, @endDate,
          @occurrenceCount, @enabled, @transferId::uuid
        )
        RETURNING id, account_id, name, direction, amount, start_date,
                  recurrence_mode, interval, unit, end_mode, end_date,
                  occurrence_count, enabled, created_at, transfer_id
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
        'transferId': transferId,
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

    return (await get(id))!;
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

    await _conn.execute(
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
                  occurrence_count, enabled, created_at, transfer_id
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
    return (await get(id))!;
  }

  /// Deletes [id]; for a transfer, also its peer row (call inside a DB
  /// transaction so both go or neither).
  Future<bool> delete(String id) async {
    final existing = await get(id);
    if (existing == null) return false;
    final peerId = existing.transfer?.peerId;
    if (peerId != null) await _deleteOne(peerId);
    return _deleteOne(id);
  }

  Future<bool> _deleteOne(String id) async {
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
      transfer: row.length > 14 && row[14] != null
          ? TransferLink(
              id: row[14].toString(),
              peerId: row.length > 15 ? row[15]?.toString() : null,
              peerAccountId: row.length > 16 ? row[16]?.toString() : null,
              peerAccountName: row.length > 17 ? row[17] as String? : null,
              peerProjectId: row.length > 18 ? row[18]?.toString() : null,
              peerProjectName: row.length > 19 ? row[19] as String? : null,
            )
          : null,
    );
  }
  // ---- Transfers --------------------------------------------------------

  /// Creates the peer row of a new transfer in [peerAccountId], mirroring
  /// [source] with the opposite direction, and links both by a new
  /// transfer_id. Call inside a DB transaction.
  Future<Transaction> linkNewPeer(
      Transaction source, String peerAccountId) async {
    await _checkPeerAccount(source, peerAccountId);
    final transferId = _uuid.v4();
    await _conn.execute(
      Sql.named(
          'UPDATE transactions SET transfer_id = @t::uuid WHERE id = @id'),
      parameters: {'t': transferId, 'id': source.id},
    );
    final peer = await create(
      accountId: peerAccountId,
      name: source.name,
      direction: source.direction == Direction.credit
          ? Direction.debit
          : Direction.credit,
      amount: source.amount,
      startDate: source.startDate,
      recurrenceMode: source.recurrenceMode,
      interval: source.interval,
      unit: source.unit,
      endMode: source.endMode,
      endDate: source.endDate,
      occurrenceCount: source.occurrenceCount,
      enabled: source.enabled,
      transferId: transferId,
    );
    await _copySkips(source.id, peer.id);
    return (await get(source.id))!;
  }

  Future<void> _checkPeerAccount(Transaction source, String accountId) async {
    if (accountId == source.accountId) {
      throw FormatException('transfer destination must be another account');
    }
    final exists = await _conn.execute(
      Sql.named('SELECT 1 FROM accounts WHERE id = @id::uuid'),
      parameters: {'id': accountId},
    );
    if (exists.isEmpty) throw FormatException('transfer account not found');
  }

  /// Rewrites the peer of [source] (a transfer row) to mirror it exactly:
  /// name, amount, opposite direction, schedule, enabled and skipped dates.
  Future<void> syncPeer(Transaction source) async {
    final peerId = source.transfer?.peerId;
    if (peerId == null) return;
    await _conn.execute(
      Sql.named('''
        UPDATE transactions p SET
          name = s.name,
          direction = CASE s.direction WHEN 'credit' THEN 'debit' ELSE 'credit' END,
          amount = s.amount, start_date = s.start_date,
          recurrence_mode = s.recurrence_mode, interval = s.interval,
          unit = s.unit, end_mode = s.end_mode, end_date = s.end_date,
          occurrence_count = s.occurrence_count, enabled = s.enabled
        FROM transactions s
        WHERE s.id = @s AND p.id = @p
      '''),
      parameters: {'s': source.id, 'p': peerId},
    );
    await _copySkips(source.id, peerId);
  }

  /// Moves the peer row of a transfer into [accountId] (changing where the
  /// transfer goes), fixing both accounts' transaction_order.
  Future<void> movePeer(Transaction source, String accountId) async {
    final peerId = source.transfer?.peerId;
    if (peerId == null || source.transfer!.peerAccountId == accountId) return;
    await _checkPeerAccount(source, accountId);
    await _conn.execute(
      Sql.named('''
        UPDATE accounts SET transaction_order =
          array_remove(transaction_order, @p::uuid)
        WHERE id = @old::uuid
      '''),
      parameters: {'p': peerId, 'old': source.transfer!.peerAccountId},
    );
    await _conn.execute(
      Sql.named('UPDATE transactions SET account_id = @a::uuid WHERE id = @p'),
      parameters: {'a': accountId, 'p': peerId},
    );
    await _conn.execute(
      Sql.named('''
        UPDATE accounts SET transaction_order =
          array_append(transaction_order, @p::uuid)
        WHERE id = @a::uuid
      '''),
      parameters: {'a': accountId, 'p': peerId},
    );
  }

  /// Turns a transfer row back into a plain transaction (drops the peer).
  Future<void> unlink(Transaction source) async {
    final peerId = source.transfer?.peerId;
    if (peerId != null) await _deleteOne(peerId);
    await _conn.execute(
      Sql.named('UPDATE transactions SET transfer_id = NULL WHERE id = @id'),
      parameters: {'id': source.id},
    );
  }

  /// Before deleting [accountId] (cascade), turn the surviving side of each
  /// of its transfers into a plain transaction.
  Future<void> orphanPeersOfAccount(String accountId) async {
    await _conn.execute(
      Sql.named('''
        UPDATE transactions SET transfer_id = NULL
        WHERE account_id <> @a::uuid AND transfer_id IN (
          SELECT transfer_id FROM transactions
          WHERE account_id = @a::uuid AND transfer_id IS NOT NULL)
      '''),
      parameters: {'a': accountId},
    );
  }

  Future<void> _copySkips(String fromId, String toId) async {
    await _conn.execute(
      Sql.named('DELETE FROM skipped_occurrences WHERE transaction_id = @t'),
      parameters: {'t': toId},
    );
    await _conn.execute(
      Sql.named('''
        INSERT INTO skipped_occurrences (transaction_id, date)
        SELECT @t::uuid, date FROM skipped_occurrences WHERE transaction_id = @f
      '''),
      parameters: {'t': toId, 'f': fromId},
    );
  }
}
