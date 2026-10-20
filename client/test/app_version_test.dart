// Stale-client guard: a tab left open across a deploy reloads into the new
// build instead of calling removed API routes ("could not reach server").
import 'package:budget_client/boot/app_version.dart';
import 'package:budget_client/data/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('AppVersion', () {
    late String live;
    late int reloads;
    late int fetches;
    late DateTime clock;
    AppVersion make(String current) => AppVersion(
      current: current,
      url: Uri.parse('http://x/build.json'),
      client: MockClient((r) async {
        fetches++;
        expect(r.url.path, '/build.json');
        expect(r.url.queryParameters['t'], isNotNull); // cache-busted
        return http.Response('{"build":"$live"}', 200);
      }),
      reload: () => reloads++,
      now: () => clock,
    );
    setUp(() {
      live = 'b1';
      reloads = 0;
      fetches = 0;
      clock = DateTime(2026, 10, 20, 12);
    });

    test('same build: no reload', () async {
      final v = make('b1');
      expect(await v.check(), isFalse);
      expect(await v.reloadIfStale(), isFalse);
      expect(reloads, 0);
    });

    test('a newer build reloads once, then waits a minute', () async {
      live = 'b2';
      var offered = 0;
      final v = make('b1')..onUpdateAvailable = () => offered++;
      expect(await v.reloadIfStale(), isTrue);
      expect(reloads, 1);
      // Still stale right after (e.g. a cache): no reload loop, offer instead.
      clock = clock.add(const Duration(seconds: 10));
      expect(await v.reloadIfStale(), isFalse);
      expect(reloads, 1);
      expect(offered, 1);
      clock = clock.add(const Duration(minutes: 2));
      expect(await v.reloadIfStale(), isTrue);
      expect(reloads, 2);
    });

    test('dev / test builds (no BUILD_ID) never check', () async {
      final v = make('');
      expect(v.enabled, isFalse);
      expect(await v.check(), isFalse);
      expect(fetches, 0);
    });

    test('server down or odd body: no reload', () async {
      final v = AppVersion(
        current: 'b1',
        url: Uri.parse('http://x/build.json'),
        client: MockClient((_) async => http.Response('<html>', 502)),
        reload: () => reloads++,
      );
      expect(await v.reloadIfStale(), isFalse);
      expect(reloads, 0);
    });
  });

  group('ApiClient flags outdated-client responses', () {
    late int suspected;
    setUp(() {
      suspected = 0;
      ApiClient.onOutdatedSuspected = () => suspected++;
    });
    tearDown(() => ApiClient.onOutdatedSuspected = null);
    ApiClient api(http.Response Function(http.Request) f) => ApiClient(
      baseUrl: 'http://x',
      httpClient: MockClient((r) async => f(r)),
    );

    test('410 client_outdated shows "please reload" and triggers a check',
        () async {
      final a = api(
        (_) => http.Response(
          '{"error":"Budget was updated. Please reload the page.",'
          '"details":{"code":"client_outdated"}}',
          410,
        ),
      );
      await expectLater(
        a.get('/api/projects'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('reload'),
          ),
        ),
      );
      expect(suspected, 1);
    });

    test('HTML instead of JSON reads "please reload", not raw HTML', () async {
      final a = api((_) => http.Response('<!DOCTYPE html><html></html>', 200));
      await expectLater(
        a.get('/api/pools'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            ApiClient.outdatedMessage,
          ),
        ),
      );
      expect(suspected, 1);
    });

    test('ordinary errors do not trigger a check', () async {
      final a = api((_) => http.Response('{"error":"bad amount"}', 400));
      await expectLater(a.get('/api/x'), throwsA(isA<ApiException>()));
      expect(suspected, 0);
    });
  });
}
