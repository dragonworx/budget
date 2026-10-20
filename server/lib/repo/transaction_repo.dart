import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../domain/enums.dart';
import '../domain/models.dart';
import '../domain/transaction_import.dart';
import '../engine/occurrence_gen.dart';

const _enrichedCols = '''
  t.id, t.pool_id, t.name, t.direction, t.amount, t.start_date,
  t.recurrence_mode, t.interval, t.unit, t.end_mode, t.end_date,
  t.occurrence_count, t.enabled, t.created_at, t.transfer_id,
  p.id, pa.id, pa.name, t.version AS t_version''';
const _peerJoin = '''
  LEFT JOIN transactions p
    ON t.transfer_id IS NOT NULL AND p.transfer_id = t.transfer_id AND p.id <> t.id
  LEFT JOIN pools pa ON pa.id = p.pool_id''';

class TransactionRepo {
  TransactionRepo(this._conn);

  final Session _conn;
  final _uuid = const Uuid();

  Future<List<Transaction>> listByPool(String poolId) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT $_enrichedCols
        FROM transactions t $_peerJoin
        WHERE t.pool_id = @poolId
        ORDER BY t.created_at ASC
      '''),
      parameters: {'poolId': poolId},
    );
    return _attachOverrides(rows.map(_fromRow).toList());
  }

  /// Loads every row's once-off overrides onto it.
  Future<List<Transaction>> _attachOverrides(List<Transaction> list) async {
    if (list.isEmpty) return list;
    final rows = await _conn.execute(
      Sql.named('''
        SELECT transaction_id::text, date, amount::text, direction
        FROM occurrence_overrides WHERE transaction_id = ANY (@ids::uuid[])
      '''),
      parameters: {
        'ids': [for (final t in list) t.id]
      },
    );
    if (rows.isEmpty) return list;
    final byId = <String, Map<DateTime, AmountOverride>>{};
    for (final r in rows) {
      final d = r[1] as DateTime;
      byId.putIfAbsent(
              r[0] as String, () => {})[DateTime.utc(d.year, d.month, d.day)] =
          AmountOverride(
        amount: Decimal.parse(r[2] as String),
        direction: Direction.parse(r[3] as String),
      );
    }
    return [
      for (final t in list)
        byId[t.id] == null ? t : t.withOverrides(byId[t.id]!),
    ];
  }

  /// Sets (or replaces) the once-off override of [transactionId]'s
  /// occurrence on [date]. Throws [FormatException] when [date] is not an
  /// occurrence of the series. Mirrors onto a transfer peer (opposite
  /// direction) and bumps the version(s). Call inside a DB transaction.
  Future<Transaction> setOverride(String transactionId, DateTime date,
      {required Direction direction, required Decimal amount}) async {
    final t = await get(transactionId);
    if (t == null) throw StateError('transaction not found');
    if (amount < Decimal.zero) throw FormatException('amount must be >= 0');
    final d = _date(date);
    if (!_isOccurrence(t, d)) {
      throw FormatException('${_fmt(d)} is not an occurrence of this series');
    }
    Future<void> put(String id, Direction dir) => _conn.execute(
          Sql.named('''
            INSERT INTO occurrence_overrides (transaction_id, date, amount, direction)
            VALUES (@t::uuid, @d, @amount::numeric, @dir)
            ON CONFLICT (transaction_id, date)
            DO UPDATE SET amount = EXCLUDED.amount, direction = EXCLUDED.direction
          '''),
          parameters: {
            't': id,
            'd': d,
            'amount': amount.toString(),
            'dir': dir.name,
          },
        );
    await put(t.id, direction);
    final peer = t.transfer?.peerId;
    if (peer != null) {
      await put(peer,
          direction == Direction.credit ? Direction.debit : Direction.credit);
    }
    await _bump([t.id, if (peer != null) peer]);
    return (await get(t.id))!;
  }

  /// Removes the override on [date] ([date] null: every override of the
  /// series), restoring the natural series value. Mirrors onto a transfer
  /// peer; bumps the version when anything was removed. Returns how many
  /// overrides were removed (on this row).
  Future<int> clearOverrides(String transactionId, {DateTime? date}) async {
    final t = await get(transactionId);
    if (t == null) throw StateError('transaction not found');
    final peer = t.transfer?.peerId;
    final rows = await _conn.execute(
      Sql.named('''
        DELETE FROM occurrence_overrides
        WHERE transaction_id = ANY (@ids::uuid[])
          ${date == null ? '' : 'AND date = @d'}
        RETURNING transaction_id::text
      '''),
      parameters: {
        'ids': [t.id, if (peer != null) peer],
        if (date != null) 'd': _date(date),
      },
    );
    final mine = rows.where((r) => r[0] == t.id).length;
    if (rows.isNotEmpty) await _bump([t.id, if (peer != null) peer]);
    return mine;
  }

  /// Drops overrides of [id] that no longer fall on an occurrence (after a
  /// schedule change). Returns how many were removed.
  Future<int> pruneOverrides(String id) async {
    final t = await get(id);
    if (t == null || t.overrides.isEmpty) return 0;
    final stale = [
      for (final d in t.overrides.keys)
        if (!_isOccurrence(t, d)) d,
    ];
    for (final d in stale) {
      await _conn.execute(
        Sql.named('DELETE FROM occurrence_overrides '
            'WHERE transaction_id = @t::uuid AND date = @d'),
        parameters: {'t': id, 'd': d},
      );
    }
    return stale.length;
  }

  /// Version bump for changes stored beside the row (overrides), so stale
  /// editors of the series get a 409 like any other change.
  Future<void> _bump(List<String> ids) => _conn.execute(
        Sql.named('UPDATE transactions SET version = version + 1 '
            'WHERE id = ANY (@ids::uuid[])'),
        parameters: {'ids': ids},
      );

  bool _isOccurrence(Transaction t, DateTime d) =>
      OccurrenceGenerator.datesForTransaction(t, d, d)
          .any((x) => x.year == d.year && x.month == d.month && x.day == d.day);

  static String _fmt(DateTime d) => formatDate(d);

  /// "From now on": ends [id] the day before its occurrence on [date] and
  /// creates a new series from [date] with the edited values in [next]
  /// (name, direction, amount, interval/unit, enabled; its start is [date]).
  /// The new series keeps the original end condition: never stays never,
  /// an end date stays, and "after N" keeps the remaining count. Skips and
  /// overrides after [date] move to the new series; an override on [date]
  /// itself is dropped (the edited values apply). A transfer gets a new
  /// peer for the new series. On the series' first occurrence it is a plain
  /// update instead. Call inside one DB transaction (all or nothing).
  Future<({Transaction original, Transaction? created})> splitAt(
    String id,
    DateTime date, {
    required String name,
    required Direction direction,
    required Decimal amount,
    int? interval,
    RecurrenceUnit? unit,
    bool? enabled,
  }) async {
    final t = await get(id);
    if (t == null) throw StateError('transaction not found');
    if (t.recurrenceMode != RecurrenceMode.every) {
      throw FormatException('only a repeating series can be split');
    }
    final d = _date(date);
    if (!_isOccurrence(t, d)) {
      throw FormatException('${_fmt(d)} is not an occurrence of this series');
    }
    final start = _date(t.startDate);
    final first = OccurrenceGenerator.datesForTransaction(t, start, d);
    final before = first.where((x) => x.isBefore(d)).length;
    if (before == 0) {
      // First occurrence: "from now on" is the whole series.
      final updated = (await update(id,
          name: name,
          direction: direction,
          amount: amount,
          interval: interval,
          unit: unit,
          enabled: enabled))!;
      await clearOverrides(id, date: d);
      await syncPeer(updated);
      return (original: (await get(id))!, created: null);
    }
    int? remaining;
    if (t.endMode == EndMode.count) {
      remaining = t.occurrenceCount! - before;
      if (remaining < 1) {
        throw FormatException('no occurrences left from ${_fmt(d)}');
      }
    }
    final created = await create(
      poolId: t.poolId,
      name: name,
      direction: direction,
      amount: amount,
      startDate: d,
      recurrenceMode: RecurrenceMode.every,
      interval: interval ?? t.interval,
      unit: unit ?? t.unit,
      endMode: t.endMode,
      endDate: t.endMode == EndMode.untilDate ? t.endDate : null,
      occurrenceCount: remaining,
      enabled: enabled ?? t.enabled,
    );
    // Skips from the split date on and later overrides belong to the new
    // series now (an override on the date itself gives way to the edit).
    for (final (table, op) in [
      ('skipped_occurrences', '>='),
      ('occurrence_overrides', '>'),
    ]) {
      await _conn.execute(
        Sql.named('''
          UPDATE $table SET transaction_id = @n::uuid
          WHERE transaction_id = @o::uuid AND date $op @d
        '''),
        parameters: {'n': created.id, 'o': t.id, 'd': d},
      );
    }
    await _conn.execute(
      Sql.named('''
        DELETE FROM occurrence_overrides
        WHERE transaction_id = @o::uuid AND date >= @d
      '''),
      parameters: {'o': t.id, 'd': d},
    );
    final ended = (await update(id,
        endMode: EndMode.untilDate,
        endDate: d.subtract(const Duration(days: 1)),
        clearOccurrenceCount: true))!;
    // Keep the new series right after the original in the pool order.
    await _conn.execute(
      Sql.named('''
        UPDATE pools SET transaction_order = (
          SELECT array_agg(x ORDER BY ord) FROM (
            SELECT x, i::numeric AS ord
            FROM unnest(array_remove(transaction_order, @n::uuid))
              WITH ORDINALITY AS u(x, i)
            UNION ALL
            SELECT @n::uuid, array_position(transaction_order, @o::uuid) + 0.5
          ) q
        )
        WHERE id = @a::uuid AND @o::uuid = ANY (transaction_order)
      '''),
      parameters: {'a': t.poolId, 'n': created.id, 'o': t.id},
    );
    if (t.transfer?.peerPoolId != null) {
      await syncPeer(ended);
      await linkNewPeer(created, t.transfer!.peerPoolId!);
      final linked = (await get(created.id))!;
      await syncPeer(linked);
    }
    return (original: (await get(id))!, created: (await get(created.id))!);
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
    return (await _attachOverrides([_fromRow(rows.first)])).single;
  }

  Future<Transaction> create({
    required String poolId,
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
          id, pool_id, name, direction, amount, start_date,
          recurrence_mode, interval, unit, end_mode, end_date,
          occurrence_count, enabled, transfer_id
        ) VALUES (
          @id, @poolId, @name, @direction, @amount, @startDate,
          @recurrenceMode, @interval, @unit, @endMode, @endDate,
          @occurrenceCount, @enabled, @transferId::uuid
        )
        RETURNING id, pool_id, name, direction, amount, start_date,
                  recurrence_mode, interval, unit, end_mode, end_date,
                  occurrence_count, enabled, created_at, transfer_id,
                  NULL::uuid, NULL::uuid, NULL::text, NULL::uuid, NULL::text,
                  version AS t_version
      '''),
      parameters: {
        'id': id,
        'poolId': poolId,
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

    // Append to pool transaction_order.
    await _conn.execute(
      Sql.named('''
        UPDATE pools
        SET transaction_order = array_append(transaction_order, @transactionId::uuid)
        WHERE id = @poolId
          AND NOT (@transactionId::uuid = ANY (transaction_order))
      '''),
      parameters: {'poolId': poolId, 'transactionId': id},
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
        RETURNING id, pool_id, name, direction, amount, start_date,
                  recurrence_mode, interval, unit, end_mode, end_date,
                  occurrence_count, enabled, created_at, transfer_id,
                  NULL::uuid, NULL::uuid, NULL::text, NULL::uuid, NULL::text,
                  version AS t_version
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
        UPDATE pools
        SET transaction_order = array_remove(transaction_order, @transactionId::uuid)
        WHERE id = @poolId
      '''),
      parameters: {
        'poolId': existing.poolId,
        'transactionId': id,
      },
    );
    final rows = await _conn.execute(
      Sql.named('DELETE FROM transactions WHERE id = @id RETURNING id'),
      parameters: {'id': id},
    );
    return rows.isNotEmpty;
  }

  /// Inserts validated import [items] into [poolId]. Call inside a DB
  /// transaction (all-or-nothing). Items whose `id` already exists in this
  /// pool are skipped unchanged (idempotent re-import); an `id` owned by
  /// another pool is an error. New rows are appended to the pool's
  /// transaction_order in array order; skippedDates go to skipped_occurrences.
  Future<({List<String> created, List<String> skipped})> importItems(
    String poolId,
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
            'SELECT id::text, pool_id::text FROM transactions WHERE id = ANY (@ids::uuid[])'),
        parameters: {'ids': ids},
      );
      for (final r in rows) {
        owners[r[0] as String] = r[1] as String;
      }
    }
    final conflicts = [
      for (final i in items)
        if (i.id != null && owners[i.id] != null && owners[i.id] != poolId)
          ImportIssue(i.index, 'id',
              'already used by a transaction in another pool'),
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
            id, pool_id, name, direction, amount, start_date,
            recurrence_mode, interval, unit, end_mode, end_date,
            occurrence_count, enabled
          ) VALUES (
            @id, @poolId, @name, @direction, @amount, @startDate,
            @recurrenceMode, @interval, @unit, @endMode, @endDate,
            @occurrenceCount, @enabled
          )
        '''),
        parameters: {
          'id': id,
          'poolId': poolId,
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
          UPDATE pools
          SET transaction_order = transaction_order || @ids::uuid[]
          WHERE id = @poolId
        '''),
        parameters: {'poolId': poolId, 'ids': created},
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

  Future<Map<String, Set<DateTime>>> skipsForPool(String poolId) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT s.transaction_id, s.date
        FROM skipped_occurrences s
        JOIN transactions st ON st.id = s.transaction_id
        WHERE st.pool_id = @poolId
      '''),
      parameters: {'poolId': poolId},
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
    final version = row.toColumnMap()['t_version'];
    return Transaction(
      version: version is int ? version : 1,
      id: row[0].toString(),
      poolId: row[1].toString(),
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
              peerPoolId: row.length > 16 ? row[16]?.toString() : null,
              peerPoolName: row.length > 17 ? row[17] as String? : null,
            )
          : null,
    );
  }
  // ---- Transfers --------------------------------------------------------

  /// Creates the peer row of a new transfer in [peerPoolId], mirroring
  /// [source] with the opposite direction, and links both by a new
  /// transfer_id. Call inside a DB transaction.
  Future<Transaction> linkNewPeer(
      Transaction source, String peerPoolId) async {
    await _checkPeerPool(source, peerPoolId);
    final transferId = _uuid.v4();
    await _conn.execute(
      Sql.named(
          'UPDATE transactions SET transfer_id = @t::uuid WHERE id = @id'),
      parameters: {'t': transferId, 'id': source.id},
    );
    final peer = await create(
      poolId: peerPoolId,
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

  Future<void> _checkPeerPool(Transaction source, String poolId) async {
    if (poolId == source.poolId) {
      throw FormatException('transfer destination must be another pool');
    }
    final exists = await _conn.execute(
      Sql.named('SELECT 1 FROM pools WHERE id = @id::uuid'),
      parameters: {'id': poolId},
    );
    if (exists.isEmpty) throw FormatException('transfer pool not found');
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
    await _copyOverrides(source.id, peerId);
  }

  /// Moves the peer row of a transfer into [poolId] (changing where the
  /// transfer goes), fixing both pools' transaction_order.
  Future<void> movePeer(Transaction source, String poolId) async {
    final peerId = source.transfer?.peerId;
    if (peerId == null || source.transfer!.peerPoolId == poolId) return;
    await _checkPeerPool(source, poolId);
    await _conn.execute(
      Sql.named('''
        UPDATE pools SET transaction_order =
          array_remove(transaction_order, @p::uuid)
        WHERE id = @old::uuid
      '''),
      parameters: {'p': peerId, 'old': source.transfer!.peerPoolId},
    );
    await _conn.execute(
      Sql.named('UPDATE transactions SET pool_id = @a::uuid WHERE id = @p'),
      parameters: {'a': poolId, 'p': peerId},
    );
    await _conn.execute(
      Sql.named('''
        UPDATE pools SET transaction_order =
          array_append(transaction_order, @p::uuid)
        WHERE id = @a::uuid
      '''),
      parameters: {'a': poolId, 'p': peerId},
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

  /// Before deleting [poolId] (cascade), turn the surviving side of each
  /// of its transfers into a plain transaction.
  Future<void> orphanPeersOfPool(String poolId) async {
    await _conn.execute(
      Sql.named('''
        UPDATE transactions SET transfer_id = NULL
        WHERE pool_id <> @a::uuid AND transfer_id IN (
          SELECT transfer_id FROM transactions
          WHERE pool_id = @a::uuid AND transfer_id IS NOT NULL)
      '''),
      parameters: {'a': poolId},
    );
  }

  /// Mirrors [fromId]'s overrides onto its transfer peer [toId] (opposite
  /// direction).
  Future<void> _copyOverrides(String fromId, String toId) async {
    await _conn.execute(
      Sql.named('DELETE FROM occurrence_overrides WHERE transaction_id = @t'),
      parameters: {'t': toId},
    );
    await _conn.execute(
      Sql.named('''
        INSERT INTO occurrence_overrides (transaction_id, date, amount, direction)
        SELECT @t::uuid, date, amount,
               CASE direction WHEN 'credit' THEN 'debit' ELSE 'credit' END
        FROM occurrence_overrides WHERE transaction_id = @f
      '''),
      parameters: {'t': toId, 'f': fromId},
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
