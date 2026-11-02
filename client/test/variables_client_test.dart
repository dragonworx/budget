import 'dart:convert';

import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/auth_repository.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/realtime_service.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/state/realtime_providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_auth.dart';

Map<String, dynamic> _event({bool exprs = true}) => {
  'id': 'e1',
  'streamId': 'a1',
  'name': 'Rent',
  'direction': 'debit',
  'amount': '300.00',
  'startDate': '2026-01-01',
  'frequency': {'rule': 'weekly', 'interval': 2},
  'endMode': 'never',
  'enabled': true,
  'version': 3,
  if (exprs) 'amountExpr': r'$rent / 4',
  if (exprs) 'intervalExpr': r'$weeks',
  if (exprs)
    'exprErrors': {
      'interval': {'code': 'unknown_variable', 'message': 'x'},
    },
  'overrides': [
    {
      'date': '2026-02-01',
      'direction': 'debit',
      'amount': '310.00',
      if (exprs) 'amountExpr': r'$rent / 4 + 10',
    },
  ],
};

class _Vars extends VariableRepository {
  _Vars() : super(ApiClient(baseUrl: 'http://x'));
  final lists = <String>[];
  int mine = 0;
  @override
  Future<List<Variable>> list(String streamId) async {
    lists.add(streamId);
    return const [];
  }

  @override
  Future<List<Variable>> listMine() async {
    mine++;
    return const [];
  }
}

void main() {
  tearDown(() => ServerFeatures.variables = false);

  group('models', () {
    test('event, override and stream formula fields parse', () {
      final e = BudgetEvent.fromJson(_event());
      expect(e.amountExpr, r'$rent / 4');
      expect(e.intervalExpr, r'$weeks');
      expect(e.occurrenceCountExpr, isNull);
      expect(e.exprErrors!['interval']['code'], 'unknown_variable');
      final o = e.overrides.values.single;
      expect(o.amountExpr, r'$rent / 4 + 10');
      // Equality is by amount and direction only.
      expect(
        o,
        OccurrenceOverride(
          direction: EventDirection.debit,
          amount: Decimal.parse('310'),
        ),
      );
      final s = BudgetStream.fromJson({
        'id': 'a1',
        'name': 'S',
        'seedBalance': '100.00',
        'seedDate': '2026-01-01',
        'seedBalanceExpr': r'$seed',
        'exprErrors': {
          'seedBalance': {'code': 'cycle', 'message': 'x'},
        },
      });
      expect(s.seedBalanceExpr, r'$seed');
      expect(s.lossThresholdExpr, isNull);
      expect(s.exprErrors!.keys, ['seedBalance']);
    });

    test('requests are unchanged: loaded formulas are not sent back', () {
      final plain = BudgetEvent.fromJson(_event(exprs: false));
      final withExpr = BudgetEvent.fromJson(_event());
      for (final on in [false, true]) {
        ServerFeatures.variables = on;
        expect(
          jsonEncode(
            withExpr.copyWith(amount: Decimal.parse('5')).toCreateJson(),
          ),
          jsonEncode(plain.copyWith(amount: Decimal.parse('5')).toCreateJson()),
        );
      }
      // Off: even an explicit formula stays out.
      ServerFeatures.variables = false;
      expect(withExpr.toCreateJson().containsKey('amountExpr'), isFalse);
      expect(
        (withExpr.toCreateJson()['frequency'] as Map).containsKey(
          'intervalExpr',
        ),
        isFalse,
      );
      final s = BudgetStream.fromJson({
        'id': 'a1',
        'name': 'S',
        'seedBalance': '100.00',
        'seedDate': '2026-01-01',
        'seedBalanceExpr': r'$seed',
      });
      expect(s.toPatchJson().containsKey('seedBalanceExpr'), isFalse);
      expect(
        s.copyWith(name: 'T').toPatchJson().containsKey('seedBalanceExpr'),
        isFalse,
      );
    });

    test('an explicit formula is sent when the server supports it', () {
      ServerFeatures.variables = true;
      final e = BudgetEvent.fromJson(_event(exprs: false)).copyWith(
        amountExpr: r'$rent / 4',
        intervalExpr: r'$weeks',
        occurrenceCountExpr: '12',
      );
      final j = e.toCreateJson();
      expect(j['amountExpr'], r'$rent / 4');
      expect(j['occurrenceCountExpr'], '12');
      expect((j['frequency'] as Map)['intervalExpr'], r'$weeks');
      final s = BudgetStream.fromJson({
        'id': 'a1',
        'name': 'S',
        'seedBalance': '100.00',
        'seedDate': '2026-01-01',
      }).copyWith(lossThresholdExpr: r'$floor');
      expect(s.toCreateJson()['lossThresholdExpr'], r'$floor');
      expect(s.toPatchJson()['lossThresholdExpr'], r'$floor');
    });

    test('Variable and config features parse', () {
      final v = Variable.fromJson({
        'id': 'v1',
        'name': 'rent',
        'unit': 'money',
        'expr': '1200',
        'value': '1200',
        'description': null,
        'displayDecimals': null,
        'problem': null,
        'version': 1,
        'usageCount': 2,
      });
      expect(v.name, 'rent');
      expect(v.value, Decimal.parse('1200'));
      expect(v.usageCount, 2);
      expect(
        AuthConfig.fromJson({
          'features': {'variables': true},
        }).variables,
        isTrue,
      );
      expect(AuthConfig.fromJson({}).variables, isFalse);
    });
  });

  test('VariableRepository paths and bodies', () async {
    final seen = <String>[];
    final api = ApiClient(
      baseUrl: 'http://x',
      httpClient: MockClient((r) async {
        seen.add('${r.method} ${r.url.path} ${r.body}');
        final body = r.url.path.endsWith('variables')
            ? (r.method == 'GET'
                  ? {'variables': []}
                  : {'id': 'v1', 'name': 'rent', 'expr': '1', 'value': '1'})
            : r.method == 'PATCH'
            ? {'id': 'v1', 'name': 'rent', 'expr': '2', 'value': '2'}
            : <String, dynamic>{};
        return http.Response(jsonEncode(body), 200);
      }),
    );
    final repo = VariableRepository(api);
    await repo.list('a1');
    await repo.listMine();
    await repo.create(name: 'rent', expr: '1', unit: 'money');
    await repo.update('v1', streamId: 'a1', expr: '2', version: 1);
    await repo.usages('v1');
    await repo.preview('v1', '3');
    await repo.attention();
    await repo.delete('v1');
    expect(seen, [
      'GET /api/streams/a1/variables ',
      'GET /api/variables ',
      'POST /api/variables {"name":"rent","value":"1","unit":"money"}',
      'PATCH /api/streams/a1/variables/v1 {"value":"2","version":1}',
      'GET /api/variables/v1/usages ',
      'POST /api/variables/v1/preview {"value":"3"}',
      'GET /api/variables/attention ',
      'DELETE /api/variables/v1 ',
    ]);
  });

  test('realtime: variable rows invalidate the lists', () async {
    final vars = _Vars();
    final c = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(
          FakeAuthRepository(user: adminUser),
        ),
        variableRepositoryProvider.overrideWithValue(vars),
      ],
    );
    addTearDown(c.dispose);
    await c.read(authProvider.future);
    final sub = c.listen(variablesProvider('a1'), (_, _) {});
    final mine = c.listen(myVariablesProvider, (_, _) {});
    addTearDown(sub.close);
    addTearDown(mine.close);
    await c.read(variablesProvider('a1').future);
    await c.read(myVariablesProvider.future);
    expect(vars.lists, ['a1']);
    expect(vars.mine, 1);
    final ctl = c.read(realtimeControllerProvider);
    ctl.handle(
      const ChangeEvent(
        id: 1,
        action: 'variable.updated',
        streamId: 'a1',
        subjectUserId: 'someone-else',
      ),
    );
    await c.read(variablesProvider('a1').future);
    await c.read(myVariablesProvider.future);
    expect(vars.lists, ['a1', 'a1']);
    // Owner-wide: any variable change refreshes every cached list (picker sync).
    expect(vars.mine, 2);
    ctl.handle(
      ChangeEvent(
        id: 2,
        action: 'variable.created',
        streamId: 'a1',
        subjectUserId: adminUser.id,
      ),
    );
    await c.read(variablesProvider('a1').future);
    await c.read(myVariablesProvider.future);
    expect(vars.lists, ['a1', 'a1', 'a1']);
    expect(vars.mine, 3);
  });
}
