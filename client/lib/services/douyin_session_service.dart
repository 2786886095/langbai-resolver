import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

const _douyinCookieKey = 'douyin_login_cookie_v1';
const _douyinCookieUrl = 'https://www.douyin.com/';
const _maxCookieHeaderLength = 8192;

const _authenticationCookieNames = <String>{
  'sessionid',
  'sessionid_ss',
  'sid_guard',
  'sid_tt',
  'uid_tt',
  'uid_tt_ss',
  'sid_ucp_v1',
  'ssid_ucp_v1',
};

final _safeCookieName = RegExp(r'^[A-Za-z0-9_.-]{1,128}$');

String sanitizeDouyinCookieHeader(Iterable<MapEntry<String, String>> values) {
  final unique = <String, String>{};
  for (final entry in values) {
    final name = entry.key.trim();
    final value = entry.value.trim();
    if (!_safeCookieName.hasMatch(name) ||
        value.isEmpty ||
        value.length > 4096 ||
        value.contains(';') ||
        value.contains('\r') ||
        value.contains('\n')) {
      continue;
    }
    unique[name] = value;
  }
  final ordered = unique.entries.toList(growable: false)
    ..sort((a, b) {
      final aAuth = _authenticationCookieNames.contains(a.key);
      final bAuth = _authenticationCookieNames.contains(b.key);
      if (aAuth != bAuth) return aAuth ? -1 : 1;
      return a.key.compareTo(b.key);
    });
  final parts = <String>[];
  var length = 0;
  for (final entry in ordered) {
    final part = '${entry.key}=${entry.value}';
    final nextLength = length + (parts.isEmpty ? 0 : 2) + part.length;
    if (nextLength > _maxCookieHeaderLength) continue;
    parts.add(part);
    length = nextLength;
  }
  return parts.join('; ');
}

bool hasAuthenticatedDouyinSession(String? cookieHeader) {
  if (cookieHeader == null || cookieHeader.trim().isEmpty) return false;
  final names = cookieHeader.split(';').map((item) {
    final separator = item.indexOf('=');
    return (separator < 0 ? '' : item.substring(0, separator)).trim();
  });
  return names.any(_authenticationCookieNames.contains);
}

bool isDouyinSessionRequiredError(String message) {
  final lower = message.toLowerCase();
  return lower.contains('fresh cookies') ||
      lower.contains('cookies are needed') ||
      lower.contains('cookies are required') ||
      lower.contains('匿名公开解析入口') ||
      lower.contains('要求登录验证') ||
      lower.contains('需要抖音登录') ||
      lower.contains('douyin_session_required');
}

class DouyinSessionService {
  DouyinSessionService._();

  static final instance = DouyinSessionService._();
  static const _storage = FlutterSecureStorage();

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  String? _cookieHeader;
  WebViewEnvironment? _webViewEnvironment;

  String? get cookieHeader => _cookieHeader;
  bool get isLoggedIn => hasAuthenticatedDouyinSession(_cookieHeader);
  WebViewEnvironment? get webViewEnvironment => _webViewEnvironment;

  Future<bool> restore() async {
    if (!isSupported) return false;
    final stored = await _storage.read(key: _douyinCookieKey);
    final pairs = (stored ?? '').split(';').map((item) {
      final separator = item.indexOf('=');
      final name = (separator < 0 ? '' : item.substring(0, separator)).trim();
      final value = (separator < 0 ? '' : item.substring(separator + 1)).trim();
      return MapEntry(name, value);
    });
    final cleaned = sanitizeDouyinCookieHeader(pairs);
    _cookieHeader = hasAuthenticatedDouyinSession(cleaned) ? cleaned : null;
    return isLoggedIn;
  }

  Future<WebViewEnvironment?> prepareWebView() async {
    if (!isSupported || defaultTargetPlatform != TargetPlatform.windows) {
      return null;
    }
    if (_webViewEnvironment != null) return _webViewEnvironment;
    final version = await WebViewEnvironment.getAvailableVersion();
    if (version == null) {
      throw StateError('Windows 缺少 Microsoft Edge WebView2 Runtime，无法打开应用内登录');
    }
    final support = await getApplicationSupportDirectory();
    _webViewEnvironment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: '${support.path}\\douyin-webview',
      ),
    );
    return _webViewEnvironment;
  }

  Future<bool> capture(InAppWebViewController controller) async {
    final manager = CookieManager.instance(
      webViewEnvironment: _webViewEnvironment,
    );
    final cookies = await manager.getCookies(
      url: WebUri(_douyinCookieUrl),
      webViewController: controller,
    );
    final header = sanitizeDouyinCookieHeader(
      cookies.map((cookie) => MapEntry(cookie.name, '${cookie.value}')),
    );
    if (!hasAuthenticatedDouyinSession(header)) return false;
    await _storage.write(key: _douyinCookieKey, value: header);
    _cookieHeader = header;
    return true;
  }

  Future<void> logout({bool clearWebCookies = true}) async {
    _cookieHeader = null;
    await _storage.delete(key: _douyinCookieKey);
    if (!clearWebCookies || !isSupported) return;
    final manager = CookieManager.instance(
      webViewEnvironment: _webViewEnvironment,
    );
    for (final url in const [
      'https://www.douyin.com/',
      'https://v.douyin.com/',
      'https://www.iesdouyin.com/',
    ]) {
      try {
        await manager.deleteCookies(url: WebUri(url));
      } on Object {
        // Secure storage is already cleared; a WebView runtime may be absent.
      }
    }
  }
}
