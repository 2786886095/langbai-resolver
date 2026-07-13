import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_endpoint_policy.dart';
import 'local_media_service.dart';
import 'runtime_environment.dart';
import 'service_credential_store.dart';
import 'update_models.dart';

const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '1.1.2');

const _configuredManifestUrl = String.fromEnvironment('UPDATE_MANIFEST_URL');
const _defaultApiUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8787',
);

class UpdateService {
  const UpdateService();

  static const _maxManifestBytes = 1024 * 1024;
  static const _highestSeenVersionKey = 'highest_seen_update_version';

  Future<UpdateCheckResult> check() async {
    final preferences = await SharedPreferences.getInstance();
    final apiBase = (preferences.getString('api_base_url') ?? _defaultApiUrl)
        .trim()
        .replaceAll(RegExp(r'/+$'), '');
    final usesConfiguredManifest = _configuredManifestUrl.trim().isNotEmpty;
    final uri = Uri.parse(
      usesConfiguredManifest
          ? _configuredManifestUrl.trim()
          : '$apiBase/api/v1/update',
    );
    if (!_isAllowedManifestUri(uri)) {
      throw const UpdateException('更新清单必须使用 HTTPS 地址');
    }
    final client = http.Client();
    final storedToken = usesConfiguredManifest
        ? ''
        : await ServiceCredentialStore.readTokenFor(apiBase);
    final requestToken = usesConfiguredManifest
        ? ''
        : selectInstanceTokenForApi(
            apiBase,
            explicitToken: storedToken.isEmpty ? null : storedToken,
            runtimeToken: langbaiInstanceToken,
          );
    late final http.StreamedResponse response;
    final bytes = BytesBuilder(copy: false);
    var received = 0;
    try {
      response = await _sendManifestRequest(
        client,
        uri,
        instanceToken: requestToken,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw UpdateException('更新服务器返回 ${response.statusCode}');
      }
      final declaredLength = response.contentLength;
      if (declaredLength != null && declaredLength > _maxManifestBytes) {
        throw const UpdateException('更新清单体积异常');
      }
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 20),
      )) {
        received += chunk.length;
        if (received > _maxManifestBytes) {
          throw const UpdateException('更新清单体积异常');
        }
        bytes.add(chunk);
      }
    } finally {
      client.close();
    }
    final data = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (data is! Map<String, dynamic>) {
      throw const UpdateException('更新清单格式不正确');
    }
    final manifest = UpdateManifest.fromJson(data);
    if (manifest.version.isEmpty) {
      throw const UpdateException('更新清单缺少版本号');
    }
    final platform = currentUpdatePlatform;
    String? androidAbi;
    if (platform == 'android' && LocalMediaService.isSupported) {
      try {
        androidAbi =
            (await LocalMediaService.instance.capabilities()).currentAbi;
      } on Object {
        // Older Android packages do not report ABI; universal remains the fallback.
      }
    }
    final release = selectUpdateRelease(
      manifest,
      platform,
      androidAbi: androidAbi,
    );
    if (platform == 'windows' && release != null && release.url.isNotEmpty) {
      if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(release.sha256)) {
        throw const UpdateException('Windows 更新清单缺少有效的 SHA-256');
      }
      if (release.sizeBytes == null || release.sizeBytes! <= 0) {
        throw const UpdateException('Windows 更新清单缺少有效的安装包大小');
      }
      if (!release.unsigned &&
          !RegExp(
            r'^[0-9a-fA-F]{64}$',
          ).hasMatch(release.signingCertificateSha256)) {
        throw const UpdateException('Windows 更新清单缺少签名证书指纹');
      }
    }
    if (platform == 'android' && release != null && release.url.isNotEmpty) {
      if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(release.sha256)) {
        throw const UpdateException('Android 更新清单缺少有效的 SHA-256');
      }
      if (release.sizeBytes == null || release.sizeBytes! <= 0) {
        throw const UpdateException('Android 更新清单缺少有效的安装包大小');
      }
    }

    final highestSeen = preferences.getString(_highestSeenVersionKey);
    if (highestSeen != null &&
        highestSeen.isNotEmpty &&
        compareVersions(manifest.version, highestSeen) < 0) {
      throw const UpdateException('检测到更新清单版本回退，已停止更新');
    }
    if (highestSeen == null ||
        highestSeen.isEmpty ||
        compareVersions(manifest.version, highestSeen) > 0) {
      await preferences.setString(_highestSeenVersionKey, manifest.version);
    }
    return UpdateCheckResult(
      manifest: manifest,
      platform: platform,
      release: release,
      hasUpdate: compareVersions(manifest.version, appVersion) > 0,
    );
  }
}

UpdatePlatformRelease? selectUpdateRelease(
  UpdateManifest manifest,
  String platform, {
  String? androidAbi,
}) {
  if (platform.toLowerCase() != 'android') {
    return manifest.releaseFor(platform);
  }
  for (final key in androidReleaseKeysForAbi(androidAbi)) {
    final release = manifest.releaseFor(key);
    if (release != null && release.url.isNotEmpty) return release;
  }
  return manifest.releaseFor('android');
}

List<String> androidReleaseKeysForAbi(String? abi) {
  final normalized = abi?.trim().toLowerCase().replaceAll('_', '-');
  final architecture = switch (normalized) {
    'arm64-v8a' || 'aarch64' || 'arm64' => 'arm64',
    'armeabi-v7a' || 'armeabi-v7' || 'armv7' || 'arm-v7a' => 'armv7',
    'x86-64' || 'x64' || 'amd64' => 'x86_64',
    _ => null,
  };
  return architecture == null
      ? const ['android']
      : ['android-$architecture', 'android'];
}

bool _isAllowedManifestUri(Uri uri) {
  if (!uri.hasScheme || uri.userInfo.isNotEmpty) return false;
  if (uri.scheme.toLowerCase() == 'https') return true;
  if (uri.scheme.toLowerCase() != 'http') return false;
  final host = uri.host.toLowerCase();
  return host == '127.0.0.1' || host == '::1' || host == 'localhost';
}

Future<http.StreamedResponse> _sendManifestRequest(
  http.Client client,
  Uri initial, {
  String instanceToken = '',
}) async {
  var current = initial;
  for (var redirects = 0; redirects <= 5; redirects++) {
    final request = http.Request('GET', current)
      ..followRedirects = false
      ..headers['User-Agent'] = 'langbai-resolver-updater';
    if (instanceToken.isNotEmpty && _sameOrigin(initial, current)) {
      request.headers['X-Langbai-Instance-Token'] = instanceToken;
    }
    final response =
        await client.send(request).timeout(const Duration(seconds: 20));
    if (!response.isRedirect) return response;
    final location = response.headers['location'];
    if (location == null || redirects == 5) {
      throw const UpdateException('更新清单重定向无效');
    }
    final next = current.resolve(location);
    if (!_isAllowedManifestUri(next) ||
        (current.scheme == 'https' && next.scheme != 'https')) {
      throw const UpdateException('更新清单禁止跳转到不安全地址');
    }
    await response.stream.drain<void>();
    current = next;
  }
  throw const UpdateException('更新清单重定向次数过多');
}

bool _sameOrigin(Uri left, Uri right) =>
    left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
    left.host.toLowerCase() == right.host.toLowerCase() &&
    left.port == right.port;

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
  return _SemanticVersion.parse(left).compareTo(_SemanticVersion.parse(right));
}

final class _SemanticVersion implements Comparable<_SemanticVersion> {
  const _SemanticVersion(this.core, this.prerelease);

  factory _SemanticVersion.parse(String input) {
    var value = input.trim();
    if (value.startsWith('v')) value = value.substring(1);
    if (!RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
      r'(?:-(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)'
      r'(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*)?'
      r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
    ).hasMatch(value)) {
      throw FormatException('无效的版本号：$input');
    }
    final withoutBuild = value.split('+').first;
    final dash = withoutBuild.indexOf('-');
    final coreText = dash < 0 ? withoutBuild : withoutBuild.substring(0, dash);
    final prereleaseText =
        dash < 0 ? '' : withoutBuild.substring(dash + 1).trim();
    final parts = coreText.split('.');
    if (parts.length != 3 ||
        parts.any((part) => !RegExp(r'^(0|[1-9]\d*)$').hasMatch(part))) {
      throw FormatException('无效的版本号：$input');
    }
    final prerelease =
        prereleaseText.isEmpty ? const <String>[] : prereleaseText.split('.');
    if (prerelease.any(
      (part) => part.isEmpty || !RegExp(r'^[0-9A-Za-z-]+$').hasMatch(part),
    )) {
      throw FormatException('无效的版本号：$input');
    }
    return _SemanticVersion(
      parts.map(BigInt.parse).toList(growable: false),
      prerelease,
    );
  }

  final List<BigInt> core;
  final List<String> prerelease;

  @override
  int compareTo(_SemanticVersion other) {
    for (var index = 0; index < core.length; index++) {
      final result = core[index].compareTo(other.core[index]);
      if (result != 0) return result;
    }
    if (prerelease.isEmpty && other.prerelease.isEmpty) return 0;
    if (prerelease.isEmpty) return 1;
    if (other.prerelease.isEmpty) return -1;
    final count = prerelease.length < other.prerelease.length
        ? prerelease.length
        : other.prerelease.length;
    for (var index = 0; index < count; index++) {
      final left = prerelease[index];
      final right = other.prerelease[index];
      final leftNumber = BigInt.tryParse(left);
      final rightNumber = BigInt.tryParse(right);
      if (leftNumber != null && rightNumber != null) {
        final result = leftNumber.compareTo(rightNumber);
        if (result != 0) return result;
      } else if (leftNumber != null) {
        return -1;
      } else if (rightNumber != null) {
        return 1;
      } else {
        final result = left.compareTo(right);
        if (result != 0) return result;
      }
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }
}

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}
