import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_endpoint_policy.dart';

class ServiceCredentialStore {
  ServiceCredentialStore._();

  static const _storage = FlutterSecureStorage();
  static const _credentialKey = 'langbai_service_credential_v1';

  static Future<String> readTokenFor(String baseUrl) async {
    if (kIsWeb) return '';
    final endpoint = normalizeTrustedApiUrl(baseUrl);
    if (endpoint == null) return '';
    try {
      final raw = await _storage.read(key: _credentialKey);
      final credential = jsonDecode(raw ?? '') as Map<String, dynamic>;
      final storedEndpoint = credential['endpoint']?.toString();
      final token = credential['token']?.toString().trim() ?? '';
      if (storedEndpoint != endpoint || !_isValidToken(token)) return '';
      return token;
    } on Object {
      return '';
    }
  }

  static Future<void> writeTokenFor(String baseUrl, String token) async {
    if (kIsWeb) return;
    final endpoint = normalizeTrustedApiUrl(baseUrl);
    final value = token.trim();
    if (endpoint == null) throw ArgumentError.value(baseUrl, 'baseUrl');
    if (value.isEmpty) {
      await clear();
      return;
    }
    if (!_isValidToken(value)) {
      throw const FormatException('服务访问令牌必须至少包含 32 字节，且不能包含换行');
    }
    await _storage.write(
      key: _credentialKey,
      value: jsonEncode({'endpoint': endpoint, 'token': value}),
    );
  }

  static Future<void> clear() async {
    if (kIsWeb) return;
    await _storage.delete(key: _credentialKey);
  }

  static bool _isValidToken(String value) =>
      value.length <= 1024 &&
      utf8.encode(value).length >= 32 &&
      !value.contains('\r') &&
      !value.contains('\n');
}
