import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'download_types.dart';

Future<SaveResult> saveDownload(
  Uri uri,
  String filename,
  DownloadProgress onProgress, {
  SaveDestination destination = SaveDestination.files,
  String mediaType = 'file',
}) async {
  late final File target;
  final isMobile = Platform.isAndroid || Platform.isIOS;
  if (isMobile) {
    final directory =
        destination == SaveDestination.gallery || Platform.isAndroid
            ? await getTemporaryDirectory()
            : Directory(
                '${(await getApplicationDocumentsDirectory()).path}'
                '${Platform.pathSeparator}langbai解析',
              );
    await directory.create(recursive: true);
    target = _availableFile(directory, filename);
  } else {
    final preferences = await SharedPreferences.getInstance();
    final preferredPath = preferences.getString('download_directory')?.trim();
    final preferredDirectory = preferredPath == null || preferredPath.isEmpty
        ? null
        : Directory(preferredPath);
    if (preferredDirectory != null && await preferredDirectory.exists()) {
      target = _availableFile(preferredDirectory, filename);
    } else {
      final location =
          await getSaveLocation(suggestedName: _safeFilename(filename));
      if (location == null) {
        return const SaveResult(message: '已取消保存', cancelled: true);
      }
      target = File(location.path);
    }
  }

  final request = http.Request('GET', uri);
  final response = await http.Client().send(request);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw HttpException('文件下载失败（${response.statusCode}）', uri: uri);
  }
  final total = response.contentLength;
  var received = 0;
  final sink = target.openWrite();
  try {
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total != null && total > 0) {
        onProgress((received / total).clamp(0, 1));
      }
    }
  } finally {
    await sink.close();
  }
  onProgress(1);

  if (isMobile) {
    if (Platform.isIOS && destination == SaveDestination.files) {
      return SaveResult(message: '已保存到“文件”App/langbai解析', path: target.path);
    }
    try {
      final raw = await const MethodChannel('com.langbai.resolver/local_media')
          .invokeMapMethod<String, dynamic>('saveMobileFile', {
        'path': target.path,
        'filename': filename,
        'save_destination': destination.name,
        'media_type': mediaType,
      });
      return SaveResult(
        message: raw?['message']?.toString() ??
            (destination == SaveDestination.gallery
                ? '已保存到系统相册'
                : '已保存到 Download/langbai解析'),
        path: raw?['path']?.toString(),
      );
    } finally {
      if (await target.exists()) await target.delete();
    }
  }
  return SaveResult(message: '文件已保存至 ${target.path}', path: target.path);
}

String _safeFilename(String value) {
  final leaf = value.split(RegExp(r'[\\/]')).last.trim();
  final cleaned = leaf.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
  return cleaned.isEmpty ? 'langbai-download.bin' : cleaned;
}

File _availableFile(Directory directory, String filename) {
  final safe = _safeFilename(filename);
  var candidate = File('${directory.path}${Platform.pathSeparator}$safe');
  if (!candidate.existsSync()) return candidate;
  final dot = safe.lastIndexOf('.');
  final stem = dot > 0 ? safe.substring(0, dot) : safe;
  final extension = dot > 0 ? safe.substring(dot) : '';
  for (var index = 1; index < 10000; index++) {
    candidate = File(
      '${directory.path}${Platform.pathSeparator}$stem ($index)$extension',
    );
    if (!candidate.existsSync()) return candidate;
  }
  return File(
    '${directory.path}${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}-$safe',
  );
}
