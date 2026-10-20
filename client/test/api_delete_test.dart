import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('deletes go to the server immediately and fail loudly', () async {
    final seen = <String>[];
    var status = 204;
    final api = ApiClient(
      baseUrl: 'http://h',
      httpClient: MockClient((r) async {
        seen.add('${r.method} ${r.url.path} ${r.headers['Cache-Control']}');
        return http.Response('', status);
      }),
    );
    await AccountRepository(api).delete('a1');
    await TransactionRepository(api).delete('t1');
    expect(seen, [
      'DELETE /api/accounts/a1 no-cache',
      'DELETE /api/transactions/t1 no-cache',
    ]);
    status = 500;
    expect(
      () => AccountRepository(api).delete('a1'),
      throwsA(isA<ApiException>()),
    );
  });
}
