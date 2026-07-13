import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'update_models.dart';
import 'local_media_service.dart';

const _trustedWindowsSignerSha256 = String.fromEnvironment(
  'WINDOWS_UPDATE_CERT_SHA256',
);
const _maxInstallerBytes = 512 * 1024 * 1024;
const _downloadTimeout = Duration(minutes: 15);
const _inactivityTimeout = Duration(seconds: 45);

Future<String> installUpdate(
  UpdatePlatformRelease release, {
  required String version,
  void Function(double progress)? onProgress,
}) async {
  final uri = Uri.tryParse(release.url);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.userInfo.isNotEmpty) {
    throw StateError('更新下载地址无效');
  }
  if (Platform.isAndroid) {
    return LocalMediaService.instance.installAppUpdate(
      url: uri.toString(),
      sha256: release.sha256,
      sizeBytes: release.sizeBytes,
      onProgress: (progress) => onProgress?.call(progress.progress),
    );
  }
  if (Platform.isIOS) {
    throw UnsupportedError(
      'iOS 不允许应用直接安装下载的 IPA，请通过 App Store、TestFlight 或原签名渠道更新。',
    );
  }
  if (!Platform.isWindows) {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw StateError('无法打开更新下载页');
    }
    onProgress?.call(1);
    return '已打开更新页面';
  }

  final directory = await getTemporaryDirectory();
  await _cleanOldInstallers(directory);
  final safeVersion = version.replaceAll(RegExp(r'[^0-9A-Za-z.+-]'), '_');
  final installer = File(
    '${directory.path}${Platform.pathSeparator}langbai-resolver-Setup-$safeVersion.exe',
  );
  final partial = File('${installer.path}.part');
  final expectedHash = release.sha256.trim().toLowerCase();
  final manifestSigner = release.signingCertificateSha256.trim().toLowerCase();
  final trustedSigner = _trustedWindowsSignerSha256.trim().toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedHash)) {
    throw const FormatException('Windows 更新缺少有效的 SHA-256，已拒绝执行');
  }
  if (!release.unsigned) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(trustedSigner)) {
      throw const FormatException('当前安装未配置官方更新签名，请从 GitHub Release 手动更新');
    }
    if (manifestSigner != trustedSigner) {
      throw const FormatException('更新签名证书与当前应用信任的证书不一致');
    }
  }

  final client = http.Client();
  try {
    await partial.delete().catchError((_) => partial);
    final response = await _sendFollowingSecureRedirects(client, uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('下载更新失败（${response.statusCode}）', uri: uri);
    }
    final total = response.contentLength ?? 0;
    final declaredSize = release.sizeBytes;
    if (total > _maxInstallerBytes ||
        (declaredSize != null && declaredSize > _maxInstallerBytes)) {
      throw const FileSystemException('更新安装包体积超出安全限制');
    }
    if (total > 0 && declaredSize != null && total != declaredSize) {
      throw const FormatException('更新安装包大小与清单不一致');
    }
    var downloaded = 0;
    final stopwatch = Stopwatch()..start();
    final sink = partial.openWrite();
    try {
      await for (final chunk in response.stream.timeout(_inactivityTimeout)) {
        if (stopwatch.elapsed > _downloadTimeout) {
          throw TimeoutException('更新下载超时', _downloadTimeout);
        }
        sink.add(chunk);
        downloaded += chunk.length;
        if (downloaded > _maxInstallerBytes) {
          throw const FileSystemException('更新安装包体积超出安全限制');
        }
        if (total > 0) onProgress?.call(downloaded / total);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (declaredSize != null && downloaded != declaredSize) {
      throw const FormatException('更新安装包未完整下载');
    }
    final digest = await sha256.bind(partial.openRead()).first;
    if (digest.toString().toLowerCase() != expectedHash) {
      throw const FormatException('安装包 SHA-256 校验失败');
    }
    if (!release.unsigned) {
      await _verifyWindowsSignature(partial, trustedSigner);
    }
    if (await installer.exists()) await installer.delete();
    await partial.rename(installer.path);
    onProgress?.call(1);
    final logDirectory = Directory(
      '${Platform.environment['LOCALAPPDATA'] ?? directory.path}'
      '${Platform.pathSeparator}langbai-resolver${Platform.pathSeparator}logs',
    );
    await logDirectory.create(recursive: true);
    final logPath = '${logDirectory.path}${Platform.pathSeparator}'
        'update-$safeVersion-${DateTime.now().millisecondsSinceEpoch}.log';
    final setupProcess = await Process.start(
        installer.path,
        [
          '/SP-',
          '/CLOSEAPPLICATIONS',
          '/RESTARTAPPLICATIONS',
          '/LOG=$logPath',
        ],
        mode: ProcessStartMode.detached);
    await _scheduleInstallerCleanup(installer, setupProcess.pid);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  } on Object {
    if (await partial.exists()) await partial.delete();
    rethrow;
  } finally {
    client.close();
  }
}

Future<http.StreamedResponse> _sendFollowingSecureRedirects(
  http.Client client,
  Uri initial,
) async {
  var current = initial;
  for (var redirects = 0; redirects <= 5; redirects++) {
    final request = http.Request('GET', current)
      ..followRedirects = false
      ..headers['User-Agent'] = 'langbai-resolver-updater';
    final response =
        await client.send(request).timeout(const Duration(seconds: 30));
    if (!response.isRedirect) return response;
    final location = response.headers['location'];
    if (location == null || redirects == 5) {
      throw const HttpException('更新下载重定向无效');
    }
    final next = current.resolve(location);
    if (next.scheme.toLowerCase() != 'https' || next.userInfo.isNotEmpty) {
      throw const HttpException('更新下载禁止跳转到非 HTTPS 地址');
    }
    await response.stream.drain<void>();
    current = next;
  }
  throw const HttpException('更新下载重定向次数过多');
}

Future<void> _verifyWindowsSignature(
  File installer,
  String expectedSigner,
) async {
  final powershell = _windowsPowerShellPath();
  if (!await File(powershell).exists()) {
    throw const FileSystemException('无法找到 Windows 签名验证组件');
  }
  const script = r'''
$signature = Get-AuthenticodeSignature -LiteralPath $env:LANGBAI_UPDATE_FILE
$fingerprint = ''
if ($null -ne $signature.SignerCertificate) {
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $fingerprint = ([System.BitConverter]::ToString(
      $sha256.ComputeHash($signature.SignerCertificate.RawData)) -replace '-', '')
  } finally {
    $sha256.Dispose()
  }
}
Write-Output ($signature.Status.ToString() + '|' + $fingerprint)
''';
  final process = await Process.start(
    powershell,
    const [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ],
    environment: {
      ...Platform.environment,
      'LANGBAI_UPDATE_FILE': installer.path,
    },
  );
  final stdoutFuture = process.stdout.transform(systemEncoding.decoder).join();
  final stderrFuture = process.stderr.transform(systemEncoding.decoder).join();
  final exitCode = await process.exitCode.timeout(
    const Duration(seconds: 30),
    onTimeout: () {
      process.kill();
      return -1;
    },
  );
  final output = (await stdoutFuture).trim();
  final error = (await stderrFuture).trim();
  final pieces = output.split('|');
  if (exitCode != 0 ||
      pieces.length != 2 ||
      pieces[0] != 'Valid' ||
      pieces[1].trim().toLowerCase() != expectedSigner) {
    throw FormatException(
      error.isEmpty ? '安装包 Authenticode 签名验证失败' : '签名验证失败：$error',
    );
  }
}

String _windowsPowerShellPath() {
  final windowsDirectory = Platform.environment['WINDIR'] ?? r'C:\Windows';
  return '$windowsDirectory${Platform.pathSeparator}System32'
      '${Platform.pathSeparator}WindowsPowerShell${Platform.pathSeparator}v1.0'
      '${Platform.pathSeparator}powershell.exe';
}

Future<void> _scheduleInstallerCleanup(File installer, int processId) async {
  final powershell = _windowsPowerShellPath();
  if (!await File(powershell).exists()) return;
  const script = r'''
Wait-Process -Id ([int]$env:LANGBAI_SETUP_PID) -ErrorAction SilentlyContinue
for ($attempt = 0; $attempt -lt 30; $attempt++) {
  Remove-Item -LiteralPath $env:LANGBAI_SETUP_FILE -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path -LiteralPath $env:LANGBAI_SETUP_FILE)) { break }
  Start-Sleep -Seconds 2
}
''';
  await Process.start(
    powershell,
    const [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ],
    environment: {
      ...Platform.environment,
      'LANGBAI_SETUP_FILE': installer.path,
      'LANGBAI_SETUP_PID': processId.toString(),
    },
    mode: ProcessStartMode.detached,
  );
}

Future<void> _cleanOldInstallers(Directory directory) async {
  final cutoff = DateTime.now().subtract(const Duration(days: 2));
  try {
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last.toLowerCase();
      if (!name.startsWith('langbai-resolver-setup-') ||
          !(name.endsWith('.exe') || name.endsWith('.exe.part'))) {
        continue;
      }
      final modified = await entity.lastModified();
      if (name.endsWith('.part') || modified.isBefore(cutoff)) {
        await entity.delete().catchError((_) => entity);
      }
    }
  } on FileSystemException {
    // Cleanup is best-effort and must not prevent a verified update.
  }
}
