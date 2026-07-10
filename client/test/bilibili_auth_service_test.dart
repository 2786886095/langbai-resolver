import 'package:flutter_test/flutter_test.dart';
import 'package:media_harbor/services/bilibili_auth_service.dart';

void main() {
  test('extracts only the Bilibili login cookies from QR callback', () {
    final cookie = BilibiliAuthService.extractLoginCookie(
      'https://passport.bilibili.com/login?DedeUserID=123&SESSDATA=abc%2Cdef&bili_jct=csrf&gourl=https%3A%2F%2Fwww.bilibili.com',
    );

    expect(cookie, contains('DedeUserID=123'));
    expect(cookie, contains('SESSDATA=abc%2Cdef'));
    expect(cookie, contains('bili_jct=csrf'));
    expect(cookie, isNot(contains('gourl=')));
  });

  test('rejects QR callbacks without SESSDATA', () {
    expect(
      BilibiliAuthService.extractLoginCookie(
        'https://passport.bilibili.com/login?DedeUserID=123&bili_jct=csrf',
      ),
      isNull,
    );
  });
}
