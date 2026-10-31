import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../domain/enums.dart';
import '../domain/models.dart';
import '../engine/balance_projection.dart';
import '../engine/solver.dart';
import '../repo/stream_repo.dart';
import '../repo/event_repo.dart';
import 'balance.dart' show checkBalanceRange;
import 'loan_fields.dart' show planningNotSupported;
import 'json_helpers.dart';

/// Registers `POST /<streamId>/solve` on [router].
void attachSolveRoutes(Router router, Session conn) {
  final streams = StreamRepo(conn);
  final eventRepo = EventRepo(conn);

  router.post('/<streamId>/solve', (Request request, String streamId) async {
    try {
      final stream = await streams.get(streamId);
      if (stream == null) return jsonError(404, 'stream not found');
      if (stream.hasLoan) return jsonError(409, planningNotSupported);

      final body = await readJsonObject(request);
      final direction = Direction.parse(requireString(body, 'direction'));
      final unit = RecurrenceUnit.parse(requireString(body, 'unit'));
      final roundingRaw = optionalString(body, 'rounding');

      // Balance target mode: the total is whatever closes the gap between
      // the projected balance on the end date and the target balance.
      Map<String, Object?>? balanceTarget;
      var targetTotal = body.containsKey('targetTotal')
          ? parseDecimal(body['targetTotal'])
          : null;
      if (body['targetBalance'] != null) {
        final target = parseDecimal(body['targetBalance']);
        final endRaw = optionalString(body, 'endDate');
        if (endRaw == null) {
          throw SolverException(
              'Set an end date to plan towards a target balance');
        }
        final end = parseDate(endRaw);
        checkBalanceRange(end, end, seed: stream.seedDate);
        final projected = BalanceProjection.closeOn(
          stream: stream,
          events: await eventRepo.listByStream(streamId),
          skipped: await eventRepo.skipsForStream(streamId),
          date: end,
        );
        final gap = BalanceProjection.gap(target: target, projected: projected);
        final signed = direction == Direction.credit ? gap : -gap;
        balanceTarget = {
          'targetBalance': target.toString(),
          'projectedBalance': projected.toString(),
          'gap': gap.toString(),
        };
        if (signed <= Decimal.zero) {
          return jsonOk({
            'status': 'onTrack',
            'balanceTarget': balanceTarget,
            'message': direction == Direction.credit
                ? 'Already on track: the balance is projected to be '
                    '$projected on $endRaw without this plan.'
                : 'The projected balance ($projected) is already below the '
                    'target, so nothing can go out.',
          });
        }
        targetTotal = signed;
      }

      final req = SolveRequest(
        direction: direction,
        unit: unit,
        name: optionalString(body, 'name') ?? '',
        startDate: optionalString(body, 'startDate') == null
            ? null
            : parseDate(body['startDate'].toString()),
        endDate: optionalString(body, 'endDate') == null
            ? null
            : parseDate(body['endDate'].toString()),
        amount:
            body.containsKey('amount') ? parseDecimal(body['amount']) : null,
        interval: optionalInt(body, 'interval'),
        occurrenceCount: optionalInt(body, 'occurrenceCount'),
        targetTotal: targetTotal,
        rounding: roundingRaw == null
            ? RoundingMode.nearest
            : RoundingMode.parse(roundingRaw),
        enabled: optionalBool(body, 'enabled') ?? true,
      );

      final result = EventSolver.solve(req);
      final json = result.toJson();
      if (balanceTarget != null) json['balanceTarget'] = balanceTarget;
      final event = result.event;
      if (event != null) {
        json['event'] = event.copyWith(streamId: streamId).toJson();
      }
      return jsonOk(json);
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on SolverException catch (e) {
      return jsonError(400, e.message);
    } on ArgumentError catch (e) {
      return jsonError(400, e.message.toString());
    }
  });
}
