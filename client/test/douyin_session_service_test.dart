import 'package:flutter_test/flutter_test.dart';
import 'package:media_harbor/services/douyin_session_service.dart';

void main() {
  test('keeps authenticated Douyin cookies and rejects header injection', () {
    final header = sanitizeDouyinCookieHeader(const [
      MapEntry('ttwid', 'anonymous-token'),
      MapEntry('sessionid_ss', 'signed-session'),
      MapEntry('bad\r\nInjected', 'value'),
      MapEntry('unsafe', 'one; two'),
    ]);

    expect(header, contains('sessionid_ss=signed-session'));
    expect(header, contains('ttwid=anonymous-token'));
    expect(header, isNot(contains('Injected')));
    expect(header, isNot(contains('unsafe')));
    expect(hasAuthenticatedDouyinSession(header), isTrue);
  });

  test('anonymous cookies are not treated as a logged-in session', () {
    final header = sanitizeDouyinCookieHeader(const [
      MapEntry('ttwid', 'anonymous-token'),
      MapEntry('passport_csrf_token', 'csrf'),
    ]);

    expect(hasAuthenticatedDouyinSession(header), isFalse);
  });

  test('recognizes native and backend login-required messages', () {
    expect(
      isDouyinSessionRequiredError(
        '[Douyin] Fresh cookies (not necessarily logged in) are needed',
      ),
      isTrue,
    );
    expect(
      isDouyinSessionRequiredError('该作品需要抖音登录，请在 langbai解析内登录后重试'),
      isTrue,
    );
    expect(isDouyinSessionRequiredError('无法连接视频平台'), isFalse);
  });
}
