import 'dart:convert';

import 'package:budget_loan/budget_loan.dart';
import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../domain/enums.dart';
import '../domain/models.dart';
import '../domain/event_import.dart';
import '../engine/occurrence_gen.dart';

const _enrichedCols = '''
  t.id, t.stream_id, t.name, t.direction, t.amount, t.start_date,
  t.recurrence_mode, t.interval, t.unit, t.end_mode, t.end_date,
  t.occurrence_count, t.enabled, t.created_at, t.transfer_id,
  p.id, pa.id, pa.name, t.version AS t_version, c.color AS t_color,
  t.freq_rule AS t_freq_rule, t.freq_interval AS t_freq_interval,
  t.freq_days AS t_freq_days, t.category_id::text AS t_category_id,
  COALESCE(c.hidden, false) AS t_category_hidden,
  t.kind AS t_kind, t.loan AS t_loan,
  t.offset_stream_ids::text[] AS t_offsets''';
const _peerJoin = '''
  LEFT JOIN categories c ON c.id = t.category_id
  LEFT JOIN events p
    ON t.transfer_id IS NOT NULL AND p.transfer_id = t.transfer_id AND p.id <> t.id
  LEFT JOIN streams pa ON pa.id = p.stream_id''';

class EventRepo {
  EventRepo(this._conn);

  final Session _conn;
  final _uuid = const Uuid();

  Future<List<BudgetEvent>> listByStream(String streamId) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT $_enrichedCols
        FROM events t $_peerJoin
        WHERE t.stream_id = @streamId
        ORDER BY t.created_at ASC
      '''),
      parameters: {'streamId': streamId},
    );
    return _attachOverrides(rows.map(_fromRow).toList());
  }

  /// Loads every row's once-off overrides onto it.
  Future<List<BudgetEvent>> _attachOverrides(List<BudgetEvent> list) async {
    if (list.isEmpty) return list;
    final rows = await _conn.execute(
      Sql.named('''
        SELECT event_id::text, date, amount::text, direction
        FROM occurrence_overrides WHERE event_id = ANY (@ids::uuid[])
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

  /// Sets (or replaces) the once-off override of [eventId]'s
  /// occurrence on [date]. Throws [FormatException] when [date] is not an
  /// occurrence of the series. Mirrors onto a transfer peer (opposite
  /// direction) and bumps the version(s). Call inside a DB transaction.
  Future<BudgetEvent> setOverride(String eventId, DateTime date,
      {required Direction direction, required Decimal amount}) async {
    final t = await get(eventId);
    if (t == null) throw StateError('event not found');
    if (amount < Decimal.zero) throw FormatException('amount must be >= 0');
    final d = _date(date);
    if (!_isOccurrence(t, d)) {
      throw FormatException('${_fmt(d)} is not an occurrence of this series');
    }
    Future<void> put(String id, Direction dir) => _conn.execute(
          Sql.named('''
            INSERT INTO occurrence_overrides (event_id, date, amount, direction)
            VALUES (@t::uuid, @d, @amount::numeric, @dir)
            ON CONFLICT (event_id, date)
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
  Future<int> clearOverrides(String eventId, {DateTime? date}) async {
    final t = await get(eventId);
    if (t == null) throw StateError('event not found');
    final peer = t.transfer?.peerId;
    final rows = await _conn.execute(
      Sql.named('''
        DELETE FROM occurrence_overrides
        WHERE event_id = ANY (@ids::uuid[])
          ${date == null ? '' : 'AND date = @d'}
        RETURNING event_id::text
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
            'WHERE event_id = @t::uuid AND date = @d'),
        parameters: {'t': id, 'd': d},
      );
    }
    return stale.length;
  }

  /// Version bump for changes stored beside the row (overrides), so stale
  /// editors of the series get a 409 like any other change.
  Future<void> _bump(List<String> ids) => _conn.execute(
        Sql.named('UPDATE events SET version = version + 1 '
            'WHERE id = ANY (@ids::uuid[])'),
        parameters: {'ids': ids},
      );

  bool _isOccurrence(BudgetEvent t, DateTime d) =>
      OccurrenceGenerator.datesForEvent(t, d, d)
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
  Future<({BudgetEvent original, BudgetEvent? created})> splitAt(
    String id,
    DateTime date, {
    required String name,
    required Direction direction,
    required Decimal amount,
    int? interval,
    RecurrenceUnit? unit,
    List<int>? days,
    bool? enabled,
    String? color,
    bool clearColor = false,
  }) async {
    final t = await get(id);
    if (t == null) throw StateError('event not found');
    if (t.recurrenceMode != RecurrenceMode.every) {
      throw FormatException('only a repeating series can be split');
    }
    final d = _date(date);
    if (!_isOccurrence(t, d)) {
      throw FormatException('${_fmt(d)} is not an occurrence of this series');
    }
    final start = _date(t.startDate);
    final first = OccurrenceGenerator.datesForEvent(t, start, d);
    final before = first.where((x) => x.isBefore(d)).length;
    if (before == 0) {
      // First occurrence: "from now on" is the whole series.
      final updated = (await update(id,
          name: name,
          direction: direction,
          amount: amount,
          interval: interval,
          unit: unit,
          days: days,
          enabled: enabled,
          color: color,
          clearColor: clearColor))!;
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
      streamId: t.streamId,
      name: name,
      direction: direction,
      amount: amount,
      startDate: d,
      recurrenceMode: RecurrenceMode.every,
      interval: interval ?? t.interval,
      unit: unit ?? t.unit,
      days: days ??
          _keptDays(
              t, RecurrenceMode.every, interval ?? t.interval, unit ?? t.unit),
      endMode: t.endMode,
      endDate: t.endMode == EndMode.untilDate ? t.endDate : null,
      occurrenceCount: remaining,
      enabled: enabled ?? t.enabled,
      color: clearColor ? null : (color ?? t.color),
    );
    // Skips from the split date on and later overrides belong to the new
    // series now (an override on the date itself gives way to the edit).
    for (final (table, op) in [
      ('skipped_occurrences', '>='),
      ('occurrence_overrides', '>'),
    ]) {
      await _conn.execute(
        Sql.named('''
          UPDATE $table SET event_id = @n::uuid
          WHERE event_id = @o::uuid AND date $op @d
        '''),
        parameters: {'n': created.id, 'o': t.id, 'd': d},
      );
    }
    await _conn.execute(
      Sql.named('''
        DELETE FROM occurrence_overrides
        WHERE event_id = @o::uuid AND date >= @d
      '''),
      parameters: {'o': t.id, 'd': d},
    );
    final ended = (await update(id,
        endMode: EndMode.untilDate,
        endDate: d.subtract(const Duration(days: 1)),
        clearOccurrenceCount: true))!;
    // Keep the new series right after the original in the stream order.
    await _conn.execute(
      Sql.named('''
        UPDATE streams SET event_order = (
          SELECT array_agg(x ORDER BY ord) FROM (
            SELECT x, i::numeric AS ord
            FROM unnest(array_remove(event_order, @n::uuid))
              WITH ORDINALITY AS u(x, i)
            UNION ALL
            SELECT @n::uuid, array_position(event_order, @o::uuid) + 0.5
          ) q
        )
        WHERE id = @a::uuid AND @o::uuid = ANY (event_order)
      '''),
      parameters: {'a': t.streamId, 'n': created.id, 'o': t.id},
    );
    if (t.transfer?.peerStreamId != null) {
      await syncPeer(ended);
      await linkNewPeer(created, t.transfer!.peerStreamId!);
      final linked = (await get(created.id))!;
      await syncPeer(linked);
    }
    return (original: (await get(id))!, created: (await get(created.id))!);
  }

  Future<BudgetEvent?> get(String id) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT $_enrichedCols
        FROM events t $_peerJoin
        WHERE t.id = @id
      '''),
      parameters: {'id': id},
    );
    if (rows.isEmpty) return null;
    return (await _attachOverrides([_fromRow(rows.first)])).single;
  }

  Future<BudgetEvent> create({
    required String streamId,
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
    String? color,
    List<int> days = const [],
    EventKind kind = EventKind.standard,
    LoanTerms? loan,
    List<String> offsetStreamIds = const [],
  }) async {
    final f = _validateShape(
      recurrenceMode: recurrenceMode,
      interval: interval,
      unit: unit,
      days: days,
      endMode: endMode,
      endDate: endDate,
      occurrenceCount: occurrenceCount,
      amount: amount,
    );

    final id = _uuid.v4();
    await _conn.execute(
      Sql.named('''
        INSERT INTO events (
          id, stream_id, name, direction, amount, start_date,
          recurrence_mode, interval, unit, end_mode, end_date,
          occurrence_count, enabled, transfer_id, color,
          freq_rule, freq_interval, freq_days, kind, loan, offset_stream_ids
        ) VALUES (
          @id, @streamId, @name, @direction, @amount, @startDate,
          @recurrenceMode, @interval, @unit, @endMode, @endDate,
          @occurrenceCount, @enabled, @transferId::uuid, @color,
          @freqRule, @freqInterval, @freqDays::int[]::smallint[],
          @kind, @loan::jsonb, @offsets::text[]::uuid[]
        )
        RETURNING id, stream_id, name, direction, amount, start_date,
                  recurrence_mode, interval, unit, end_mode, end_date,
                  occurrence_count, enabled, created_at, transfer_id,
                  NULL::uuid, NULL::uuid, NULL::text, NULL::uuid, NULL::text,
                  version AS t_version
      '''),
      parameters: {
        'id': id,
        'streamId': streamId,
        'name': name,
        'direction': direction.name,
        'amount': amount.toString(),
        'startDate': _date(startDate),
        ..._freqParams(f),
        'endMode': endMode.apiName,
        'endDate': endDate == null ? null : _date(endDate),
        'occurrenceCount': occurrenceCount,
        'enabled': enabled,
        'transferId': transferId,
        'color': color,
        'kind': kind.name,
        'loan': loan == null ? null : jsonEncode(loan.toJson()),
        'offsets': offsetStreamIds,
      },
    );

    // Append to stream event_order.
    await _conn.execute(
      Sql.named('''
        UPDATE streams
        SET event_order = array_append(event_order, @eventId::uuid)
        WHERE id = @streamId
          AND NOT (@eventId::uuid = ANY (event_order))
      '''),
      parameters: {'streamId': streamId, 'eventId': id},
    );

    return (await get(id))!;
  }

  Future<BudgetEvent?> update(
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
    String? color,
    bool clearColor = false,
    List<int>? days,
    LoanTerms? loan,
    List<String>? offsetStreamIds,
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

    final f = _validateShape(
      recurrenceMode: nextMode,
      interval: nextInterval,
      unit: nextUnit,
      days: days ?? _keptDays(existing, nextMode, nextInterval, nextUnit),
      endMode: nextEnd,
      endDate: nextEndDate,
      occurrenceCount: nextCount,
      amount: nextAmount,
    );

    await _conn.execute(
      Sql.named('''
        UPDATE events SET
          name = @name,
          direction = @direction,
          amount = @amount,
          start_date = @startDate,
          recurrence_mode = @recurrenceMode,
          interval = @interval,
          unit = @unit,
          freq_rule = @freqRule,
          freq_interval = @freqInterval,
          freq_days = @freqDays::int[]::smallint[],
          end_mode = @endMode,
          end_date = @endDate,
          occurrence_count = @occurrenceCount,
          enabled = @enabled,
          color = @color,
          loan = COALESCE(@loan::jsonb, loan),
          offset_stream_ids =
            COALESCE(@offsets::text[]::uuid[], offset_stream_ids)
        WHERE id = @id
        RETURNING id, stream_id, name, direction, amount, start_date,
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
        ..._freqParams(f),
        'endMode': nextEnd.apiName,
        'endDate': nextEndDate == null ? null : _date(nextEndDate),
        'occurrenceCount': nextCount,
        'enabled': enabled ?? existing.enabled,
        'color': clearColor ? null : (color ?? existing.color),
        'loan': loan == null ? null : jsonEncode(loan.toJson()),
        'offsets': offsetStreamIds,
      },
    );
    return (await get(id))!;
  }

  /// Deletes [id]; for a transfer, also its peer row (call inside a DB
  /// event so both go or neither).
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
        UPDATE streams
        SET event_order = array_remove(event_order, @eventId::uuid)
        WHERE id = @streamId
      '''),
      parameters: {
        'streamId': existing.streamId,
        'eventId': id,
      },
    );
    final rows = await _conn.execute(
      Sql.named('DELETE FROM events WHERE id = @id RETURNING id'),
      parameters: {'id': id},
    );
    return rows.isNotEmpty;
  }

  /// Undo of an import: deletes every row of [ids] that still exists in
  /// [streamId] (call inside a DB transaction: all of them or none). Ids that
  /// are gone already, or belong to another stream, are left alone and
  /// returned as `missing`. Imports never create transfers, but a transfer
  /// row is still deleted with its peer, as a normal delete would.
  Future<({List<String> deleted, List<String> missing})> deleteImported(
      String streamId, List<String> ids) async {
    if (ids.isEmpty) return (deleted: <String>[], missing: <String>[]);
    final rows = await _conn.execute(
      Sql.named('SELECT id::text FROM events '
          'WHERE stream_id = @p::uuid AND id = ANY(@ids::uuid[])'),
      parameters: {'p': streamId, 'ids': ids},
    );
    final present = {for (final r in rows) (r[0] as String).toLowerCase()};
    final deleted = <String>[];
    for (final id in ids) {
      if (present.contains(id) && await delete(id)) deleted.add(id);
    }
    return (
      deleted: deleted,
      missing: [
        for (final id in ids)
          if (!present.contains(id)) id
      ],
    );
  }

  /// Inserts validated import [items] into [streamId]. Call inside a DB
  /// event (all-or-nothing). Items whose `id` already exists in this
  /// stream are skipped unchanged (idempotent re-import); an `id` owned by
  /// another stream is an error. New rows are appended to the stream's
  /// event_order in array order; skippedDates go to skipped_occurrences.
  Future<({List<String> created, List<String> skipped})> importItems(
    String streamId,
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
            'SELECT id::text, stream_id::text FROM events WHERE id = ANY (@ids::uuid[])'),
        parameters: {'ids': ids},
      );
      for (final r in rows) {
        owners[r[0] as String] = r[1] as String;
      }
    }
    final conflicts = [
      for (final i in items)
        if (i.id != null && owners[i.id] != null && owners[i.id] != streamId)
          ImportIssue(
              i.index, 'id', 'already used by an event in another stream'),
    ];
    if (conflicts.isNotEmpty) throw ImportValidationException(conflicts);

    final created = <String>[], skipped = <String>[];
    for (final item in items) {
      if (item.id != null && owners.containsKey(item.id)) {
        skipped.add(item.id!);
        continue;
      }
      final f = _validateShape(
        recurrenceMode: item.recurrenceMode,
        interval: item.interval,
        unit: item.unit,
        days: item.days,
        endMode: item.endMode,
        endDate: item.endDate,
        occurrenceCount: item.occurrenceCount,
        amount: item.amount,
      );
      final id = item.id ?? _uuid.v4();
      await _conn.execute(
        Sql.named('''
          INSERT INTO events (
            id, stream_id, name, direction, amount, start_date,
            recurrence_mode, interval, unit, end_mode, end_date,
            occurrence_count, enabled, color,
            freq_rule, freq_interval, freq_days
          ) VALUES (
            @id, @streamId, @name, @direction, @amount, @startDate,
            @recurrenceMode, @interval, @unit, @endMode, @endDate,
            @occurrenceCount, @enabled, @color,
            @freqRule, @freqInterval, @freqDays::int[]::smallint[]
          )
        '''),
        parameters: {
          'id': id,
          'streamId': streamId,
          'name': item.name,
          'direction': item.direction.name,
          'amount': item.amount.toString(),
          'startDate': _date(item.startDate),
          ..._freqParams(f),
          'endMode': item.endMode.apiName,
          'endDate': item.endDate == null ? null : _date(item.endDate!),
          'occurrenceCount': item.occurrenceCount,
          'enabled': item.enabled,
          'color': item.color,
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
          UPDATE streams
          SET event_order = event_order || @ids::uuid[]
          WHERE id = @streamId
        '''),
        parameters: {'streamId': streamId, 'ids': created},
      );
    }
    return (created: created, skipped: skipped);
  }

  Future<void> setSkip(String eventId, DateTime date, bool skipped) async {
    final d = _date(date);
    if (skipped) {
      await _conn.execute(
        Sql.named('''
          INSERT INTO skipped_occurrences (event_id, date)
          VALUES (@eventId, @date)
          ON CONFLICT DO NOTHING
        '''),
        parameters: {'eventId': eventId, 'date': d},
      );
    } else {
      await _conn.execute(
        Sql.named('''
          DELETE FROM skipped_occurrences
          WHERE event_id = @eventId AND date = @date
        '''),
        parameters: {'eventId': eventId, 'date': d},
      );
    }
  }

  Future<Map<String, Set<DateTime>>> skipsForStream(String streamId) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT s.event_id, s.date
        FROM skipped_occurrences s
        JOIN events st ON st.id = s.event_id
        WHERE st.stream_id = @streamId
      '''),
      parameters: {'streamId': streamId},
    );
    final map = <String, Set<DateTime>>{};
    for (final row in rows) {
      final eventId = row[0].toString();
      final date = row[1] as DateTime;
      map
          .putIfAbsent(eventId, () => <DateTime>{})
          .add(DateTime.utc(date.year, date.month, date.day));
    }
    return map;
  }

  /// The days an update keeps when it sends none: the saved days while the
  /// rule stays in the same family (week or month), else none.
  List<int> _keptDays(BudgetEvent existing, RecurrenceMode mode, int? interval,
      RecurrenceUnit? unit) {
    if (existing.days.isEmpty || mode == RecurrenceMode.once) return const [];
    final was = existing.frequency.rule;
    final unitNow = unit?.name;
    final week = unitNow == 'weeks', month = unitNow == 'months';
    if ((week && was.weekFamily) || (month && was.monthFamily)) {
      return existing.days;
    }
    return const [];
  }

  /// Legacy columns (never 'years' any more: N years are written as 12·N
  /// months, the same dates) and the structured freq_* columns.
  static Map<String, Object?> _freqParams(Frequency f) => {
        'recurrenceMode': f.repeats ? 'every' : 'once',
        'interval': f.repeats ? f.legacyInterval : null,
        'unit': f.repeats ? f.legacyUnit : null,
        'freqRule': f.rule.apiName,
        'freqInterval': f.interval,
        'freqDays': f.days,
      };

  /// Validates the event's shape and returns its structured rule.
  Frequency _validateShape({
    required RecurrenceMode recurrenceMode,
    required int? interval,
    required RecurrenceUnit? unit,
    List<int> days = const [],
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
        throw FormatException('once events must not set interval/unit');
      }
    } else {
      if (interval == null || interval < 1) {
        throw FormatException('interval must be >= 1');
      }
      if (unit == null) {
        throw FormatException('unit is required for every events');
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
    return Frequency.fromLegacy(
      once: recurrenceMode == RecurrenceMode.once,
      interval: interval,
      unit: unit?.name,
      days: days,
    );
  }

  DateTime _date(DateTime d) => DateTime.utc(d.year, d.month, d.day);

  BudgetEvent _fromRow(ResultRow row) {
    final start = row[5] as DateTime;
    final endRaw = row[10];
    DateTime? endDate;
    if (endRaw != null) {
      final e = endRaw as DateTime;
      endDate = DateTime.utc(e.year, e.month, e.day);
    }
    var unitRaw = row[8] as String?;
    final cols = row.toColumnMap();
    final version = cols['t_version'];
    // The structured rule is the source of truth; the cadence fields are
    // its legacy view.
    var mode = RecurrenceMode.parse(row[6] as String);
    var interval = row[7] as int?;
    var days = const <int>[];
    final ruleRaw = cols['t_freq_rule'] as String?;
    if (ruleRaw != null) {
      final f = Frequency(
        FreqRule.parse(ruleRaw),
        interval: cols['t_freq_interval'] as int? ?? 1,
        days: [
          for (final d in (cols['t_freq_days'] as List? ?? const [])) d as int
        ],
      );
      mode = f.repeats ? RecurrenceMode.every : RecurrenceMode.once;
      interval = f.repeats ? f.legacyInterval : null;
      unitRaw = f.repeats ? f.legacyUnit : null;
      days = f.days;
    }
    final kind = EventKind.parse(cols['t_kind'] as String? ?? 'standard');
    final loanRaw = cols['t_loan'];
    final offsetsRaw = cols['t_offsets'];
    return BudgetEvent(
      offsetStreamIds: offsetsRaw is List
          ? [for (final o in offsetsRaw) o.toString()]
          : const [],
      kind: kind,
      loan: loanRaw == null
          ? null
          : LoanTerms.fromJson(
              loanRaw is String ? jsonDecode(loanRaw) : loanRaw),
      days: days,
      color: cols['t_color'] as String?,
      categoryId: cols['t_category_id'] as String?,
      categoryHidden: cols['t_category_hidden'] as bool? ?? false,
      version: version is int ? version : 1,
      id: row[0].toString(),
      streamId: row[1].toString(),
      name: row[2] as String,
      direction: Direction.parse(row[3] as String),
      amount: Decimal.parse(row[4].toString()),
      startDate: DateTime.utc(start.year, start.month, start.day),
      recurrenceMode: mode,
      interval: interval,
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
              peerStreamId: row.length > 16 ? row[16]?.toString() : null,
              peerStreamName: row.length > 17 ? row[17] as String? : null,
            )
          : null,
    );
  }
  // ---- Transfers --------------------------------------------------------

  /// Creates the peer row of a new transfer in [peerStreamId], mirroring
  /// [source] with the opposite direction, and links both by a new
  /// transfer_id. Call inside a DB transaction.
  Future<BudgetEvent> linkNewPeer(
      BudgetEvent source, String peerStreamId) async {
    await _checkPeerStream(source, peerStreamId);
    final transferId = _uuid.v4();
    await _conn.execute(
      Sql.named('UPDATE events SET transfer_id = @t::uuid WHERE id = @id'),
      parameters: {'t': transferId, 'id': source.id},
    );
    final peer = await create(
      streamId: peerStreamId,
      name: source.name,
      direction: source.direction == Direction.credit
          ? Direction.debit
          : Direction.credit,
      amount: source.amount,
      startDate: source.startDate,
      recurrenceMode: source.recurrenceMode,
      interval: source.interval,
      unit: source.unit,
      days: source.days,
      endMode: source.endMode,
      endDate: source.endDate,
      occurrenceCount: source.occurrenceCount,
      enabled: source.enabled,
      transferId: transferId,
      color: source.color,
    );
    await _copySkips(source.id, peer.id);
    return (await get(source.id))!;
  }

  Future<void> _checkPeerStream(BudgetEvent source, String streamId) async {
    if (streamId == source.streamId) {
      throw FormatException('transfer destination must be another stream');
    }
    final exists = await _conn.execute(
      Sql.named('SELECT 1 FROM streams WHERE id = @id::uuid'),
      parameters: {'id': streamId},
    );
    if (exists.isEmpty) throw FormatException('transfer stream not found');
  }

  /// Rewrites the peer of [source] (a transfer row) to mirror it exactly:
  /// name, amount, opposite direction, schedule, enabled, colour and
  /// skipped dates.
  Future<void> syncPeer(BudgetEvent source) async {
    final peerId = source.transfer?.peerId;
    if (peerId == null) return;
    await _conn.execute(
      Sql.named('''
        UPDATE events p SET
          name = s.name,
          direction = CASE s.direction WHEN 'credit' THEN 'debit' ELSE 'credit' END,
          amount = s.amount, start_date = s.start_date,
          recurrence_mode = s.recurrence_mode, interval = s.interval,
          unit = s.unit, end_mode = s.end_mode, end_date = s.end_date,
          freq_rule = s.freq_rule, freq_interval = s.freq_interval,
          freq_days = s.freq_days,
          occurrence_count = s.occurrence_count, enabled = s.enabled,
          color = (SELECT color FROM categories WHERE id = s.category_id)
        FROM events s
        WHERE s.id = @s AND p.id = @p
      '''),
      parameters: {'s': source.id, 'p': peerId},
    );
    await _copySkips(source.id, peerId);
    await _copyOverrides(source.id, peerId);
  }

  /// Moves the peer row of a transfer into [streamId] (changing where the
  /// transfer goes), fixing both streams' event_order.
  Future<void> movePeer(BudgetEvent source, String streamId) async {
    final peerId = source.transfer?.peerId;
    if (peerId == null || source.transfer!.peerStreamId == streamId) return;
    await _checkPeerStream(source, streamId);
    await _conn.execute(
      Sql.named('''
        UPDATE streams SET event_order =
          array_remove(event_order, @p::uuid)
        WHERE id = @old::uuid
      '''),
      parameters: {'p': peerId, 'old': source.transfer!.peerStreamId},
    );
    await _conn.execute(
      Sql.named('UPDATE events SET stream_id = @a::uuid WHERE id = @p'),
      parameters: {'a': streamId, 'p': peerId},
    );
    await _conn.execute(
      Sql.named('''
        UPDATE streams SET event_order =
          array_append(event_order, @p::uuid)
        WHERE id = @a::uuid
      '''),
      parameters: {'a': streamId, 'p': peerId},
    );
  }

  /// Turns a transfer row back into a plain event (drops the peer).
  Future<void> unlink(BudgetEvent source) async {
    final peerId = source.transfer?.peerId;
    if (peerId != null) await _deleteOne(peerId);
    await _conn.execute(
      Sql.named('UPDATE events SET transfer_id = NULL WHERE id = @id'),
      parameters: {'id': source.id},
    );
  }

  /// Before deleting [streamId] (cascade), turn the surviving side of each
  /// of its transfers into a plain event.
  Future<void> orphanPeersOfStream(String streamId) async {
    await _conn.execute(
      Sql.named('''
        UPDATE events SET transfer_id = NULL
        WHERE stream_id <> @a::uuid AND transfer_id IN (
          SELECT transfer_id FROM events
          WHERE stream_id = @a::uuid AND transfer_id IS NOT NULL)
      '''),
      parameters: {'a': streamId},
    );
  }

  /// Mirrors [fromId]'s overrides onto its transfer peer [toId] (opposite
  /// direction).
  Future<void> _copyOverrides(String fromId, String toId) async {
    await _conn.execute(
      Sql.named('DELETE FROM occurrence_overrides WHERE event_id = @t'),
      parameters: {'t': toId},
    );
    await _conn.execute(
      Sql.named('''
        INSERT INTO occurrence_overrides (event_id, date, amount, direction)
        SELECT @t::uuid, date, amount,
               CASE direction WHEN 'credit' THEN 'debit' ELSE 'credit' END
        FROM occurrence_overrides WHERE event_id = @f
      '''),
      parameters: {'t': toId, 'f': fromId},
    );
  }

  Future<void> _copySkips(String fromId, String toId) async {
    await _conn.execute(
      Sql.named('DELETE FROM skipped_occurrences WHERE event_id = @t'),
      parameters: {'t': toId},
    );
    await _conn.execute(
      Sql.named('''
        INSERT INTO skipped_occurrences (event_id, date)
        SELECT @t::uuid, date FROM skipped_occurrences WHERE event_id = @f
      '''),
      parameters: {'t': toId, 'f': fromId},
    );
  }
}
