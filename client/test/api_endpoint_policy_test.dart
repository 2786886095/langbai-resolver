import 'package:flutter_test/flutter_test.dart';
import 'package:media_harbor/services/api_endpoint_policy.dart';

void main() {
  test('allows HTTPS and local HTTP service endpoints', () {
    expect(
      normalizeTrustedApiUrl('https://resolver.example.com/'),
      'https://resolver.example.com',
    );
    expect(
      normalizeTrustedApiUrl('http://127.0.0.1:8787/'),
      'http://127.0.0.1:8787',
    );
    expect(
      normalizeTrustedApiUrl('HTTPS://Resolver.Example.COM:443/api/'),
      'https://resolver.example.com/api',
    );
    expect(normalizeTrustedApiUrl('http://LOCALHOST:80/'), 'http://localhost');
  });

  test('rejects remote cleartext, credentials, query and fragment', () {
    expect(normalizeTrustedApiUrl('http://192.168.1.2:8787'), isNull);
    expect(normalizeTrustedApiUrl('https://user:password@example.com'), isNull);
    expect(normalizeTrustedApiUrl('https://example.com?token=value'), isNull);
    expect(normalizeTrustedApiUrl('https://example.com/#settings'), isNull);
    expect(normalizeTrustedApiUrl('file:///tmp/backend'), isNull);
  });

  test('runtime instance token is scoped to loopback APIs', () {
    const runtimeToken = 'local-process-secret';
    expect(
      selectInstanceTokenForApi(
        'http://127.0.0.1:8787',
        runtimeToken: runtimeToken,
      ),
      runtimeToken,
    );
    expect(
      selectInstanceTokenForApi(
        'https://resolver.example.com',
        runtimeToken: runtimeToken,
      ),
      isEmpty,
    );
    expect(
      selectInstanceTokenForApi(
        'https://resolver.example.com',
        explicitToken: 'remote-service-secret',
        runtimeToken: runtimeToken,
      ),
      'remote-service-secret',
    );
  });
}
