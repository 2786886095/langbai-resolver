import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:media_harbor/models/media_models.dart';
import 'package:media_harbor/services/api_client.dart';

void main() {
  test('sends the local instance token on health and file downloads', () async {
    final client = ApiClient(
      'http://127.0.0.1:8787/',
      instanceToken: 'test-instance-token',
      client: MockClient((request) async {
        expect(request.followRedirects, isFalse);
        expect(request.maxRedirects, 0);
        expect(
          request.headers['x-langbai-instance-token'],
          'test-instance-token',
        );
        return http.Response('{"status":"ok"}', 200);
      }),
    );

    expect(await client.isHealthy(), isTrue);
    expect(
      client.downloadHeaders['X-Langbai-Instance-Token'],
      'test-instance-token',
    );
    client.close();
  });

  test('parses a cancelled job returned by the cancel endpoint', () async {
    final client = ApiClient(
      'https://resolver.example.com',
      client: MockClient((request) async {
        expect(request.method, 'DELETE');
        return http.Response(
          '{"id":"job-12345678","state":"cancelled","progress":0.4}',
          200,
          headers: const {'content-type': 'application/json'},
        );
      }),
    );

    final job = await client.cancelJob('job-12345678');

    expect(job.state, JobState.cancelled);
    expect(job.progress, 0.4);
    client.close();
  });

  test('does not follow API redirects with an instance token', () async {
    const token = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final client = ApiClient(
      'https://resolver.example.com',
      instanceToken: token,
      client: MockClient((request) async {
        expect(request.followRedirects, isFalse);
        expect(request.headers['x-langbai-instance-token'], token);
        return http.Response(
          '<html>redirect</html>',
          302,
          headers: const {'location': 'https://attacker.example/collect'},
        );
      }),
    );

    await expectLater(
      client.resolve('https://example.com/video'),
      throwsA(
        isA<ApiException>().having(
          (error) => error.message,
          'message',
          contains('不会跟随跳转'),
        ),
      ),
    );
    client.close();
  });
}
