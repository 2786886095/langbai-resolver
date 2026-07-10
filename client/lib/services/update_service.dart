import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'update_models.dart';

const appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '1.0.6',
);

const _configuredManifestUrl = String.fromEnvironment('UPDATE_MANIFEST_URL');
const _defaultApiUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8787',
);

class UpdateService {
  const UpdateService();

  Future<UpdateCheckResult> check() async {
    final preferences = await SharedPreferences.getInstance();
    final apiBase = (preferences.getString('api_base_url') ?? _defaultApiUrl)
        .trim()
        .replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse(
      _configuredManifestUrl.trim().isNotEmpty
          ? _configuredManifestUrl.trim()
          : '$apiBase/api/v1/update',
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UpdateException('更新服务器返回 ${response.statusCode}');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is! Map<String, dynamic>) {
      throw const UpdateException('更新清单格式不正确');
    }
    final manifest = UpdateManifest.fromJson(data);
    if (manifest.version.isEmpty) {
      throw const UpdateException('更新清单缺少版本号');
    }
    final platform = currentUpdatePlatform;
    return UpdateCheckResult(
      manifest: manifest,
      platform: platform,
      release: manifest.releaseFor(platform),
      hasUpdate: compareVersions(manifest.version, appVersion) > 0,
    );
  }
}

String get currentUpdatePlatform {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows => 'windows',
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.linux => 'linux',
    TargetPlatform.fuchsia => 'web',
  };
}

int compareVersions(String left, String right) {
  List<int> numbers(String value) => value
      .split(RegExp(r'[-+]'))
      .first
      .split('.')
      .map((part) => int.tryParse(part) ?? 0)
      .toList(growable: false);

  final a = numbers(left);
  final b = numbers(right);
  final length = a.length > b.length ? a.length : b.length;
  for (var index = 0; index < length; index++) {
    final av = index < a.length ? a[index] : 0;
    final bv = index < b.length ? b[index] : 0;
    if (av != bv) return av.compareTo(bv);
  }
  return 0;
}

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}
