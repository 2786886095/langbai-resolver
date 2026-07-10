import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'update_models.dart';

Future<void> installUpdate(
  UpdatePlatformRelease release, {
  required String version,
  void Function(double progress)? onProgress,
}) async {
  final uri = Uri.tryParse(release.url);
  if (uri == null || !uri.hasScheme) {
    throw StateError('更新下载地址无效');
  }
  if (!Platform.isWindows) {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw StateError('无法打开更新下载页');
    }
    onProgress?.call(1);
    return;
  }

  final client = http.Client();
  final directory = await getTemporaryDirectory();
  final installer = File(
    '${directory.path}${Platform.pathSeparator}langbai-resolver-Setup-$version.exe',
  );
  try {
    final request = http.Request('GET', uri);
    final response = await client.send(request).timeout(
          const Duration(seconds: 30),
        );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('下载更新失败（${response.statusCode}）', uri: uri);
    }
    final total = response.contentLength ?? 0;
    var downloaded = 0;
    final sink = installer.openWrite();
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        downloaded += chunk.length;
        if (total > 0) onProgress?.call(downloaded / total);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (release.sha256.isNotEmpty) {
      final digest = await sha256.bind(installer.openRead()).first;
      if (digest.toString().toLowerCase() != release.sha256.toLowerCase()) {
        await installer.delete();
        throw const FormatException('安装包 SHA-256 校验失败');
      }
    }
    onProgress?.call(1);
    await Process.start(
      installer.path,
      const [
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/CLOSEAPPLICATIONS',
      ],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  } finally {
    client.close();
  }
}
