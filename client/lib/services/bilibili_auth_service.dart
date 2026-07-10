import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

const _bilibiliCookieKey = 'bilibili_login_cookie_v1';
const _bilibiliAccountKey = 'bilibili_login_account_v1';
const _bilibiliHeaders = {
  'accept': 'application/json',
  'referer': 'https://www.bilibili.com/',
  'user-agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36',
};
const _loginCookieNames = {
  'SESSDATA',
  'bili_jct',
  'DedeUserID',
  'DedeUserID__ckMd5',
  'sid',
  'bili_ticket',
  'bili_ticket_expires',
};

class BilibiliQrSession {
  const BilibiliQrSession({required this.url, required this.key});

  final String url;
  final String key;
}

enum BilibiliQrState { waiting, scanned, confirmed, expired }

class BilibiliPollResult {
  const BilibiliPollResult(this.state, {this.message});

  final BilibiliQrState state;
  final String? message;
}

class BilibiliAccount {
  const BilibiliAccount({
    required this.name,
    this.avatarUrl,
    this.userId,
    this.vipLabel,
  });

  final String name;
  final String? avatarUrl;
  final String? userId;
  final String? vipLabel;

  Map<String, dynamic> toJson() => {
        'name': name,
        'avatar_url': avatarUrl,
        'user_id': userId,
        'vip_label': vipLabel,
      };

  factory BilibiliAccount.fromJson(Map<String, dynamic> json) =>
      BilibiliAccount(
        name: json['name']?.toString() ?? 'B站用户',
        avatarUrl: json['avatar_url']?.toString(),
        userId: json['user_id']?.toString(),
        vipLabel: json['vip_label']?.toString(),
      );
}

class BilibiliAuthService {
  BilibiliAuthService._();

  static final instance = BilibiliAuthService._();
  static const _storage = FlutterSecureStorage();

  BilibiliAccount? _account;
  String? _cookieHeader;

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  BilibiliAccount? get account => _account;
  bool get isLoggedIn => _cookieHeader?.contains('SESSDATA=') ?? false;
  String? get cookieHeader => _cookieHeader;

  Future<BilibiliAccount?> restore() async {
    if (!isSupported) return null;
    _cookieHeader ??= await _storage.read(key: _bilibiliCookieKey);
    final cached = await _storage.read(key: _bilibiliAccountKey);
    if (cached != null && _account == null) {
      try {
        _account = BilibiliAccount.fromJson(
          Map<String, dynamic>.from(jsonDecode(cached) as Map),
        );
      } on Object {
        await _storage.delete(key: _bilibiliAccountKey);
      }
    }
    if (!isLoggedIn) return null;
    try {
      return await refreshAccount();
    } on Object {
      return _account;
    }
  }

  Future<BilibiliQrSession> createQrSession() async {
    final response = await http
        .get(
          Uri.https(
            'passport.bilibili.com',
            '/x/passport-login/web/qrcode/generate',
          ),
          headers: _bilibiliHeaders,
        )
        .timeout(const Duration(seconds: 20));
    final payload = _decodeResponse(response);
    final data = Map<String, dynamic>.from(payload['data'] as Map? ?? const {});
    final url = data['url']?.toString();
    final key = data['qrcode_key']?.toString();
    if (payload['code'] != 0 || url == null || key == null) {
      throw BilibiliAuthException(
          payload['message']?.toString() ?? '无法生成B站登录二维码');
    }
    return BilibiliQrSession(url: url, key: key);
  }

  Future<BilibiliPollResult> poll(BilibiliQrSession session) async {
    final response = await http
        .get(
          Uri.https(
            'passport.bilibili.com',
            '/x/passport-login/web/qrcode/poll',
            {'qrcode_key': session.key},
          ),
          headers: _bilibiliHeaders,
        )
        .timeout(const Duration(seconds: 20));
    final payload = _decodeResponse(response);
    final data = Map<String, dynamic>.from(payload['data'] as Map? ?? const {});
    final code = (data['code'] as num?)?.toInt();
    if (payload['code'] != 0) {
      throw BilibiliAuthException(
          payload['message']?.toString() ?? 'B站登录状态查询失败');
    }
    if (code == 86101) {
      return const BilibiliPollResult(BilibiliQrState.waiting);
    }
    if (code == 86090) {
      return const BilibiliPollResult(
        BilibiliQrState.scanned,
        message: '已扫码，请在哔哩哔哩中确认登录',
      );
    }
    if (code == 86038) {
      return const BilibiliPollResult(
        BilibiliQrState.expired,
        message: '二维码已失效，请刷新',
      );
    }
    if (code != 0) {
      throw BilibiliAuthException(
        data['message']?.toString() ?? 'B站扫码登录失败（$code）',
      );
    }

    final cookie = extractLoginCookie(
      data['url']?.toString() ?? '',
      setCookieHeader: response.headers['set-cookie'],
    );
    if (cookie == null) {
      throw const BilibiliAuthException('登录已确认，但未收到B站会话信息');
    }
    _cookieHeader = cookie;
    await _storage.write(key: _bilibiliCookieKey, value: cookie);
    await refreshAccount();
    return const BilibiliPollResult(BilibiliQrState.confirmed);
  }

  Future<BilibiliAccount> refreshAccount() async {
    final cookie =
        _cookieHeader ?? await _storage.read(key: _bilibiliCookieKey);
    if (cookie == null || !cookie.contains('SESSDATA=')) {
      throw const BilibiliAuthException('尚未登录B站');
    }
    final response = await http.get(
      Uri.https('api.bilibili.com', '/x/web-interface/nav'),
      headers: {..._bilibiliHeaders, 'cookie': cookie},
    ).timeout(const Duration(seconds: 20));
    final payload = _decodeResponse(response);
    final data = Map<String, dynamic>.from(payload['data'] as Map? ?? const {});
    if (payload['code'] != 0 || data['isLogin'] != true) {
      await logout();
      throw const BilibiliAuthException('B站登录已失效，请重新扫码');
    }
    final vip = Map<String, dynamic>.from(
      (data['vip_label'] ?? data['vipLabel']) as Map? ?? const {},
    );
    _cookieHeader = cookie;
    _account = BilibiliAccount(
      name: data['uname']?.toString() ?? 'B站用户',
      avatarUrl: data['face']?.toString(),
      userId: data['mid']?.toString(),
      vipLabel: vip['text']?.toString(),
    );
    await _storage.write(
      key: _bilibiliAccountKey,
      value: jsonEncode(_account!.toJson()),
    );
    return _account!;
  }

  Future<void> logout() async {
    _account = null;
    _cookieHeader = null;
    await _storage.delete(key: _bilibiliCookieKey);
    await _storage.delete(key: _bilibiliAccountKey);
  }

  static String? extractLoginCookie(
    String callbackUrl, {
    String? setCookieHeader,
  }) {
    final values = <String, String>{};
    final uri = Uri.tryParse(callbackUrl);
    for (final item in uri?.query.split('&') ?? const <String>[]) {
      final separator = item.indexOf('=');
      if (separator <= 0) continue;
      final name = Uri.decodeQueryComponent(item.substring(0, separator));
      if (_loginCookieNames.contains(name)) {
        values[name] = item.substring(separator + 1);
      }
    }
    if (setCookieHeader != null) {
      final pattern = RegExp(
        r'(SESSDATA|bili_jct|DedeUserID|DedeUserID__ckMd5|sid|bili_ticket|bili_ticket_expires)=([^;,\s]+)',
      );
      for (final match in pattern.allMatches(setCookieHeader)) {
        values.putIfAbsent(match.group(1)!, () => match.group(2)!);
      }
    }
    if (!(values['SESSDATA']?.isNotEmpty ?? false)) return null;
    return values.entries.map((item) => '${item.key}=${item.value}').join('; ');
  }

  static Map<String, dynamic> _decodeResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BilibiliAuthException('B站服务返回 ${response.statusCode}');
    }
    try {
      return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    } on Object {
      throw const BilibiliAuthException('B站服务返回了无效数据');
    }
  }
}

class BilibiliAuthException implements Exception {
  const BilibiliAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}
