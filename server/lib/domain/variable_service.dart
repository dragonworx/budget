// Variables (spec 010): re-resolution of formula fields, the variable
// write path (validation, topological re-evaluation, fan-out, rename,
// delete), usages, attention and the dry-run preview.
import 'dart:convert';

import 'package:budget_formula/budget_formula.dart';
import 'package:budget_loan/budget_loan.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';

import '../repo/event_repo.dart';
import '../repo/variable_ref_repo.dart';
import '../repo/variable_repo.dart';
import 'formulas.dart';

/// A variable request that can't be honoured: [status] with `{error,
/// details}`.
class VariableException implements Exception {
  VariableException(this.status, this.message, [this.details]);
  final int status;
  final String message;
  final Map<String, Object?>? details;
  @override
  String toString() => 'VariableException($status, $message)';
}

/// One field a variable change touched (preview, usages).
class FieldChange {
  FieldChange({
    required this.entity,
    required this.entityId,
    required this.field,
    this.streamId,
    this.date,
    this.expr,
    this.oldValue,
    this.newValue,
    this.error,
  });

  /// event, override, stream or variable.
  final String entity;
  final String entityId;
  final String field;
  final String? streamId;
  final String? date;
  final String? expr;
  final String? oldValue;
  final String? newValue;
  final Map<String, Object?>? error;

  Map<String, Object?> toJson() => {
        'entity': entity,
        'entityId': entityId,
        if (streamId != null) 'streamId': streamId,
        if (date != null) 'date': date,
        'field': field,
        'expr': expr,
        'oldValue': oldValue,
        'newValue': newValue,
        if (error != null) 'error': error,
      };
}

/// Which streams a re-resolution changed, and how many fields.
class RefreshResult {
  final streams = <String>{};
  var fields = 0;
  void add(RefreshResult o) {
    streams.addAll(o.streams);
    fields += o.fields;
  }
}

Map<String, dynamic>? _jsonOrNull(Object? v) => v == null
    ? null
    : Map<String, dynamic>.from((v is String ? jsonDecode(v) : v) as Map);

String _date(Object? d) =>
    d is DateTime ? d.toIso8601String().substring(0, 10) : '$d';

/// Request key of a stored field (strict re-resolution errors).
String requestKeyOf(String field) => switch (field) {
      FormulaField.amount => 'amountExpr',
      FormulaField.interval => 'frequency.intervalExpr',
      FormulaField.count => 'occurrenceCountExpr',
      FormulaField.loanTerm => 'loan.termYearsExpr',
      FormulaField.loanChargeDay => 'loan.chargeDayExpr',
      FormulaField.seedBalance => 'seedBalanceExpr',
      FormulaField.lossThreshold => 'lossThresholdExpr',
      _ when field.startsWith('loan.ratePeriods.') =>
        'loan.ratePeriods[${field.split('.')[2]}].ratePctExpr',
      _ => field,
    };

class VariableService {
  VariableService(this._db);
  final Session _db;
  final _lookups = <String, VariableLookup>{};

  /// Replaces the cached lookup (after a variable re-evaluation).
  void setLookup(String ownerId, VariableLookup lookup) =>
      _lookups[ownerId] = lookup;

  /// [ownerId]'s variables (cached for this service's transaction).
  Future<VariableLookup> lookupFor(String ownerId) async =>
      _lookups[ownerId] ??= await VariableRepo(_db).lookup(ownerId);

  Future<String?> streamOwner(String streamId) async {
    final r = await _db.execute(
      Sql.named('SELECT owner_id::text FROM streams WHERE id = @a::uuid'),
      parameters: {'a': streamId},
    );
    return r.isEmpty ? null : r.first[0] as String;
  }

  /// The owner whose variables an event resolves against (D10): its own
  /// stream's owner, or for a transfer credit row the debit side's.
  Future<String?> resolvingOwnerOf(String eventId) async {
    final r = await _db.execute(
      Sql.named('''
        SELECT s.owner_id::text FROM events e
        JOIN streams s ON s.id = e.stream_id
        WHERE (e.id = @id::uuid AND (e.transfer_id IS NULL
                                     OR e.direction = 'debit'))
           OR (e.transfer_id = (SELECT transfer_id FROM events
                                WHERE id = @id::uuid)
               AND e.direction = 'debit')
        LIMIT 1
      '''),
      parameters: {'id': eventId},
    );
    return r.isEmpty ? null : r.first[0] as String;
  }

  /// After an event write (create, patch, split, override, link change):
  /// re-resolves the pair against its resolving owner and rebuilds its
  /// refs. When the owner changed from [ownerBefore] (direction flip, new
  /// peer) a field that no longer resolves fails the request (400).
  Future<void> afterEventWrite(Iterable<String> ids,
      {String? ownerBefore}) async {
    await refreshEvents(ids, strictUnlessOwner: ownerBefore);
    await VariableRefIndex(_db).reindexEvents(ids);
  }

  /// After creating events (and their transfer peers) whose formulas were
  /// just resolved against their resolving owner in this transaction
  /// (prepareEventFormulas, D10 prediction): only the refs are written.
  Future<void> afterEventCreate(Iterable<String> ids) =>
      VariableRefIndex(_db).reindexEvents(ids, fresh: true);

  Future<void> afterStreamWrite(String id) async {
    await refreshStreams([id]);
    await VariableRefIndex(_db).reindexStreams([id]);
  }

  /// Re-resolves the formula fields of events [ids] (the debit row of a
  /// transfer pair; the peer is mirrored) against current variables.
  /// Errors keep the last value and set expr_errors (D8), unless
  /// [strictUnlessOwner] is given and differs from the row's resolving
  /// owner, when they throw [FormulaFieldException].
  Future<RefreshResult> refreshEvents(Iterable<String> ids,
      {String? strictUnlessOwner, List<FieldChange>? collect}) async {
    final out = RefreshResult();
    final idList = ids.toSet().toList();
    if (idList.isEmpty) return out;
    final rows = await _db.execute(
      Sql.named('''
        SELECT e.id::text, e.stream_id::text, s.owner_id::text,
               e.transfer_id IS NOT NULL, e.kind, e.amount::text,
               e.freq_interval, e.occurrence_count, e.loan, e.amount_expr,
               e.interval_expr, e.count_expr, e.expr_errors, e.start_date,
               e.end_mode,
               (SELECT p.stream_id::text FROM events p
                WHERE p.transfer_id = e.transfer_id AND p.id <> e.id)
        FROM events e JOIN streams s ON s.id = e.stream_id
        WHERE (e.id = ANY(@ids::text[]::uuid[])
               OR e.transfer_id IN (SELECT transfer_id FROM events
                                    WHERE id = ANY(@ids::text[]::uuid[])
                                      AND transfer_id IS NOT NULL))
          AND (e.transfer_id IS NULL OR e.direction = 'debit')
      '''),
      parameters: {'ids': idList},
    );
    if (rows.isEmpty) return out;
    final overrides = await _db.execute(
      Sql.named('''
        SELECT event_id::text, date, amount::text, amount_expr, expr_error
        FROM occurrence_overrides
        WHERE event_id = ANY(@ids::text[]::uuid[])
          AND (amount_expr IS NOT NULL OR expr_error IS NOT NULL)
      '''),
      parameters: {
        'ids': [for (final r in rows) r[0] as String]
      },
    );
    final ovByEvent = <String, List<ResultRow>>{};
    for (final o in overrides) {
      (ovByEvent[o[0] as String] ??= []).add(o);
    }

    final batchIds = <String>[], batchAmounts = <String>[];
    final batchErrs = <String>[];
    final ovIds = <String>[], ovDates = <String>[], ovAmounts = <String>[];
    final ovErrs = <String>[];
    final bumped = <String>{};
    final transfers = <String>{};
    final repo = EventRepo(_db);

    for (final r in rows) {
      final id = r[0] as String, stream = r[1] as String;
      final owner = r[2] as String, isTransfer = r[3] as bool;
      final isLoan = r[4] == 'loan';
      final amountExpr = r[9] as String?, intervalExpr = r[10] as String?;
      final countExpr = r[11] as String?;
      final loan = _jsonOrNull(r[8]);
      final oldErrors = _jsonOrNull(r[12]) ?? const {};
      final ovs = ovByEvent[id] ?? const <ResultRow>[];
      final hasLoanTexts = loan != null && jsonEncode(loan).contains('Expr"');
      if (amountExpr == null &&
          intervalExpr == null &&
          countExpr == null &&
          !hasLoanTexts &&
          ovs.isEmpty &&
          oldErrors.isEmpty) {
        continue;
      }
      final strict = strictUnlessOwner != null && strictUnlessOwner != owner;
      final vars = await lookupFor(owner);
      final errors = <String, Object?>{};
      var changedFields = 0;

      void fail(String field, FormulaError e, String? text) {
        if (strict) throw FormulaFieldException(requestKeyOf(field), e);
        errors[field] = errorJson(e);
        collect?.add(FieldChange(
            entity: 'event',
            entityId: id,
            streamId: stream,
            field: field,
            expr: text,
            error: errorJson(e)));
      }

      void note(String field, String? text, Object? oldV, Object? newV) {
        changedFields++;
        collect?.add(FieldChange(
            entity: 'event',
            entityId: id,
            streamId: stream,
            field: field,
            expr: text,
            oldValue: '$oldV',
            newValue: '$newV'));
      }

      // amount
      String? newAmount;
      if (amountExpr != null) {
        final res = resolveStoredText(amountExpr,
            fieldSpecs[isLoan ? 'loan.principal' : 'event.amount']!, vars);
        if (res.error != null) {
          fail(FormulaField.amount, res.error!, amountExpr);
        } else if (res.value != Decimal.parse(r[5] as String)) {
          newAmount = res.value.toString();
          note(FormulaField.amount, amountExpr, r[5], newAmount);
        }
      }

      // interval, count, loan: through the repo (frequency rules, loan
      // validation), one row at a time; rare.
      int? newInterval, newCount;
      if (intervalExpr != null) {
        final res = resolveStoredText(intervalExpr, intervalSpec(1), vars);
        if (res.error != null) {
          fail(FormulaField.interval, res.error!, intervalExpr);
        } else if (res.value!.toBigInt().toInt() != r[6]) {
          newInterval = res.value!.toBigInt().toInt();
        }
      }
      if (countExpr != null && r[14] == 'count') {
        final res =
            resolveStoredText(countExpr, fieldSpecs['event.count']!, vars);
        if (res.error != null) {
          fail(FormulaField.count, res.error!, countExpr);
        } else if (res.value!.toBigInt().toInt() != r[7]) {
          newCount = res.value!.toBigInt().toInt();
        }
      }
      LoanTerms? newLoan;
      String? loanField;
      if (hasLoanTexts) {
        final (next, field) =
            _resolveLoan(loan, vars, (f, e, t) => fail(f, e, t));
        if (next != null) {
          loanField = field;
          try {
            final terms = LoanTerms.fromJson(next);
            terms.validate(r[13] as DateTime);
            newLoan = terms;
          } on FormatException catch (e) {
            fail(
                field ?? FormulaField.loanTerm,
                FormulaError(FormulaErrorCode.outOfRange, e.message, 0, 0),
                null);
          }
        }
      }
      if (newInterval != null || newCount != null || newLoan != null) {
        try {
          await repo.update(id,
              interval: newInterval, occurrenceCount: newCount, loan: newLoan);
          if (newInterval != null) {
            note(FormulaField.interval, intervalExpr, r[6], newInterval);
          }
          if (newCount != null) {
            note(FormulaField.count, countExpr, r[7], newCount);
          }
          if (newLoan != null) note(loanField ?? 'loan', null, null, null);
        } on FormatException catch (e) {
          final f = newInterval != null
              ? FormulaField.interval
              : newCount != null
                  ? FormulaField.count
                  : (loanField ?? FormulaField.loanTerm);
          fail(f, FormulaError(FormulaErrorCode.outOfRange, e.message, 0, 0),
              null);
        }
      }

      // overrides
      for (final o in ovs) {
        final text = o[3] as String?;
        final d = _date(o[1]);
        if (text == null) {
          // A stale error on a now-plain override.
          ovIds.add(id);
          ovDates.add(d);
          ovAmounts.add('');
          ovErrs.add('');
          continue;
        }
        final res = resolveStoredText(text, fieldSpecs['event.amount']!, vars);
        final oldErr = o[4];
        if (res.error != null) {
          if (strict) {
            throw FormulaFieldException('amountExpr', res.error!);
          }
          final ej = jsonEncode(errorJson(res.error!));
          collect?.add(FieldChange(
              entity: 'override',
              entityId: id,
              streamId: stream,
              date: d,
              field: FormulaField.amount,
              expr: text,
              error: errorJson(res.error!)));
          if (oldErr == null || jsonEncode(_jsonOrNull(oldErr)) != ej) {
            ovIds.add(id);
            ovDates.add(d);
            ovAmounts.add('');
            ovErrs.add(ej);
          }
        } else if (res.value != Decimal.parse(o[2] as String) ||
            oldErr != null) {
          ovIds.add(id);
          ovDates.add(d);
          ovAmounts.add(res.value.toString());
          ovErrs.add('');
          if (res.value != Decimal.parse(o[2] as String)) {
            changedFields++;
            collect?.add(FieldChange(
                entity: 'override',
                entityId: id,
                streamId: stream,
                date: d,
                field: FormulaField.amount,
                expr: text,
                oldValue: o[2] as String,
                newValue: res.value.toString()));
          }
        }
      }
      if (ovIds.isNotEmpty && ovIds.last == id) bumped.add(id);

      final errorsChanged = jsonEncode(errors) != jsonEncode(oldErrors);
      if (newAmount != null || errorsChanged) {
        batchIds.add(id);
        batchAmounts.add(newAmount ?? '');
        batchErrs.add(errors.isEmpty ? '' : jsonEncode(errors));
      }
      final touched = changedFields > 0 || errorsChanged || bumped.contains(id);
      if (touched) {
        out.streams.add(stream);
        final peer = r[15] as String?;
        if (peer != null) out.streams.add(peer);
        if (isTransfer) transfers.add(id);
      }
      out.fields += changedFields;
    }

    if (batchIds.isNotEmpty) {
      await _db.execute(
        Sql.named('''
          UPDATE events e SET
            amount = COALESCE(NULLIF(v.amount, '')::numeric, e.amount),
            expr_errors = NULLIF(v.errs, '')::jsonb
          FROM unnest(@ids::text[], @amounts::text[], @errs::text[])
               AS v(id, amount, errs)
          WHERE e.id = v.id::uuid
        '''),
        parameters: {
          'ids': batchIds,
          'amounts': batchAmounts,
          'errs': batchErrs
        },
      );
    }
    if (ovIds.isNotEmpty) {
      await _db.execute(
        Sql.named('''
          UPDATE occurrence_overrides o SET
            amount = COALESCE(NULLIF(v.amount, '')::numeric, o.amount),
            expr_error = NULLIF(v.err, '')::jsonb
          FROM unnest(@ids::text[], @dates::text[], @amounts::text[],
                      @errs::text[]) AS v(id, d, amount, err)
          WHERE o.event_id = v.id::uuid AND o.date = v.d::date
        '''),
        parameters: {
          'ids': ovIds,
          'dates': ovDates,
          'amounts': ovAmounts,
          'errs': ovErrs,
        },
      );
      final onlyOv = bumped.difference(batchIds.toSet()).toList();
      if (onlyOv.isNotEmpty) {
        await _db.execute(
          Sql.named('UPDATE events SET version = version + 1 '
              'WHERE id = ANY(@ids::text[]::uuid[])'),
          parameters: {'ids': onlyOv},
        );
      }
    }
    for (final id in transfers) {
      final e = await repo.get(id);
      if (e != null) await repo.syncPeer(e);
    }
    return out;
  }

  /// The loan JSON with its expr keys re-resolved, or null when nothing
  /// changed; and the first changed field.
  (Map<String, dynamic>?, String?) _resolveLoan(
      Map<String, dynamic> loan,
      VariableLookup vars,
      void Function(String field, FormulaError e, String? text) fail) {
    final next = Map<String, dynamic>.from(loan);
    String? first;
    final y = loan['termYearsExpr'] as String?;
    final m = loan['termMonthsExpr'] as String?;
    if (y != null || m != null) {
      final ry = y == null
          ? null
          : resolveStoredText(y, fieldSpecs['loan.termYears']!, vars);
      final rm = m == null
          ? null
          : resolveStoredText(m, fieldSpecs['loan.termMonths']!, vars);
      final err = ry?.error ?? rm?.error;
      if (err != null) {
        fail(FormulaField.loanTerm, err, y ?? m);
      } else {
        final total = (ry?.value?.toBigInt().toInt() ?? 0) * 12 +
            (rm?.value?.toBigInt().toInt() ?? 0);
        if (total < 1 || total > 600) {
          fail(
              FormulaField.loanTerm,
              FormulaError(FormulaErrorCode.outOfRange,
                  'A loan term is 1 month to 50 years', 0, 0),
              y ?? m);
        } else if (total != loan['termMonths']) {
          next['termMonths'] = total;
          first ??= FormulaField.loanTerm;
        }
      }
    }
    final c = loan['chargeDayExpr'] as String?;
    if (c != null) {
      final r = resolveStoredText(c, fieldSpecs['loan.chargeDay']!, vars);
      if (r.error != null) {
        fail(FormulaField.loanChargeDay, r.error!, c);
      } else if (r.value!.toBigInt().toInt() != loan['chargeDay']) {
        next['chargeDay'] = r.value!.toBigInt().toInt();
        first ??= FormulaField.loanChargeDay;
      }
    }
    final periods = loan['ratePeriods'];
    if (periods is List) {
      final list = <Object?>[];
      for (var i = 0; i < periods.length; i++) {
        final p = periods[i];
        final t = p is Map ? p['ratePctExpr'] : null;
        if (t is! String) {
          list.add(p);
          continue;
        }
        final r = resolveStoredText(t, fieldSpecs['loan.ratePct']!, vars);
        if (r.error != null) {
          fail(FormulaField.loanRate(i), r.error!, t);
          list.add(p);
        } else if (r.value != Decimal.tryParse('${(p as Map)['ratePct']}')) {
          list.add({...p, 'ratePct': loanRateText(r.value!)});
          first ??= FormulaField.loanRate(i);
        } else {
          list.add(p);
        }
      }
      next['ratePeriods'] = list;
    }
    return (first == null ? null : next, first);
  }

  /// [refreshEvents] for streams' seed balance and loss threshold.
  Future<RefreshResult> refreshStreams(Iterable<String> ids,
      {List<FieldChange>? collect}) async {
    final out = RefreshResult();
    final idList = ids.toSet().toList();
    if (idList.isEmpty) return out;
    final rows = await _db.execute(
      Sql.named('''
        SELECT id::text, owner_id::text, seed_balance::text,
               loss_threshold::text, seed_balance_expr, loss_threshold_expr,
               expr_errors
        FROM streams WHERE id = ANY(@ids::text[]::uuid[])
          AND (seed_balance_expr IS NOT NULL OR loss_threshold_expr IS NOT NULL
               OR expr_errors IS NOT NULL)
      '''),
      parameters: {'ids': idList},
    );
    final bIds = <String>[], bSeed = <String>[], bLoss = <String>[];
    final bErrs = <String>[];
    for (final r in rows) {
      final id = r[0] as String;
      final vars = await lookupFor(r[1] as String);
      final errors = <String, Object?>{};
      final oldErrors = _jsonOrNull(r[6]) ?? const {};
      final values = <String>['', ''];
      var changed = 0;
      for (final (i, field, spec) in [
        (0, FormulaField.seedBalance, 'stream.seed'),
        (1, FormulaField.lossThreshold, 'stream.threshold'),
      ]) {
        final text = r[4 + i] as String?;
        if (text == null) continue;
        final res = resolveStoredText(text, fieldSpecs[spec]!, vars);
        final old = r[2 + i] as String?;
        if (res.error != null) {
          errors[field] = errorJson(res.error!);
          collect?.add(FieldChange(
              entity: 'stream',
              entityId: id,
              streamId: id,
              field: field,
              expr: text,
              error: errorJson(res.error!)));
        } else if (old == null || res.value != Decimal.parse(old)) {
          values[i] = res.value.toString();
          changed++;
          collect?.add(FieldChange(
              entity: 'stream',
              entityId: id,
              streamId: id,
              field: field,
              expr: text,
              oldValue: old,
              newValue: res.value.toString()));
        }
      }
      final errorsChanged = jsonEncode(errors) != jsonEncode(oldErrors);
      if (changed > 0 || errorsChanged) {
        bIds.add(id);
        bSeed.add(values[0]);
        bLoss.add(values[1]);
        bErrs.add(errors.isEmpty ? '' : jsonEncode(errors));
        out.streams.add(id);
        out.fields += changed;
      }
    }
    if (bIds.isNotEmpty) {
      await _db.execute(
        Sql.named('''
          UPDATE streams s SET
            seed_balance = COALESCE(NULLIF(v.seed, '')::numeric, s.seed_balance),
            loss_threshold =
              COALESCE(NULLIF(v.loss, '')::numeric, s.loss_threshold),
            expr_errors = NULLIF(v.errs, '')::jsonb
          FROM unnest(@ids::text[], @seed::text[], @loss::text[],
                      @errs::text[]) AS v(id, seed, loss, errs)
          WHERE s.id = v.id::uuid
        '''),
        parameters: {'ids': bIds, 'seed': bSeed, 'loss': bLoss, 'errs': bErrs},
      );
    }
    return out;
  }
}
