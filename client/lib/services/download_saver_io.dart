import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'download_types.dart';

Future<SaveResult> saveDownload(
  Uri uri,
  String filename,
  DownloadProgress onProgress, {
  SaveDestination destination = SaveDestination.files,
  String mediaType = 'file',
  Map<String, String> headers = const {},
  bool Function()? isCancelled,
  String? customDestinationUri,
  TransferProgressCallback? onTransferProgress,
  bool followRedirects = false,
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
    final requestedCustomPath = destination == SaveDestination.custom
        ? _localPath(customDestinationUri)
        : null;
    if (destination == SaveDestination.custom && requestedCustomPath == null) {
      throw const FileSystemException('自选保存目录不可用，请在设置中重新选择');
    }
    final preferredPath = requestedCustomPath;
    final preferredDirectory = preferredPath == null || preferredPath.isEmpty
        ? null
        : Directory(preferredPath);
    if (destination == SaveDestination.custom &&
        (preferredDirectory == null || !await preferredDirectory.exists())) {
      throw const FileSystemException('自选保存目录已失效，请在设置中重新选择');
    }
    if (preferredDirectory != null && await preferredDirectory.exists()) {
      target = _availableFile(preferredDirectory, filename);
    } else {
      final location = await getSaveLocation(
        suggestedName: _safeFilename(filename),
      );
      if (location == null) {
        return const SaveResult(message: '已取消保存', cancelled: true);
      }
      target = File(location.path);
    }
  }

  const maxDownloadBytes = 8 * 1024 * 1024 * 1024;
  final client = http.Client();
  IOSink? sink;
  try {
    final request = http.Request('GET', uri)
      ..followRedirects = followRedirects
      ..maxRedirects = followRedirects ? 5 : 0
      ..headers.addAll(headers);
    final response =
        await client.send(request).timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('文件下载失败（${response.statusCode}）', uri: uri);
    }
    final total = response.contentLength;
    if (total != null && total > maxDownloadBytes) {
      throw const FileSystemException('文件超过 8 GB 安全上限');
    }
    var received = 0;
    final stopwatch = Stopwatch()..start();
    var lastReceived = 0;
    var lastElapsed = Duration.zero;
    double? smoothedSpeed;
    sink = target.openWrite();
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 60),
    )) {
      if (isCancelled?.call() == true) {
        throw const FileSystemException('下载已取消');
      }
      received += chunk.length;
      if (received > maxDownloadBytes) {
        throw const FileSystemException('文件超过 8 GB 安全上限');
      }
      sink.add(chunk);
      final elapsed = stopwatch.elapsed;
      final progress = total != null && total > 0
          ? (received / total).clamp(0, 1).toDouble()
          : 0.0;
      if (total != null && total > 0) {
        onProgress(progress >= 1 ? 0.99 : progress);
      }
      final shouldEmit =
          elapsed - lastElapsed >= const Duration(milliseconds: 250) ||
              (total != null && received >= total);
      if (shouldEmit) {
        final intervalSeconds = (elapsed - lastElapsed).inMicroseconds /
            Duration.microsecondsPerSecond;
        final instant = intervalSeconds <= 0
            ? null
            : (received - lastReceived) / intervalSeconds;
        if (instant != null) {
          smoothedSpeed = smoothedSpeed == null
              ? instant
              : smoothedSpeed * 0.65 + instant * 0.35;
        }
        onTransferProgress?.call(
          TransferProgress(
            // A full network transfer is not a completed save until the file
            // is flushed and, on mobile, published to the selected location.
            progress: progress >= 1 ? 0.99 : progress,
            downloadedBytes: received,
            totalBytes: total,
            speedBytesPerSecond: smoothedSpeed,
            averageSpeedBytesPerSecond: elapsed.inMicroseconds <= 0
                ? null
                : received /
                    (elapsed.inMicroseconds / Duration.microsecondsPerSecond),
          ),
        );
        lastReceived = received;
        lastElapsed = elapsed;
      }
    }
    await sink.flush();
    await sink.close();
    sink = null;
  } on Object {
    await sink?.close();
    if (await target.exists()) await target.delete();
    rethrow;
  } finally {
    client.close();
  }
  onProgress(0.99);
  final completedSize = await target.length();
  void reportPublished() {
    onProgress(1);
    onTransferProgress?.call(
      TransferProgress(
        progress: 1,
        downloadedBytes: completedSize,
        totalBytes: completedSize,
      ),
    );
  }

  if (isMobile) {
    if (Platform.isIOS && destination == SaveDestination.files) {
      reportPublished();
      return SaveResult(message: '已保存到“文件”App/langbai解析', path: target.path);
    }
    try {
      final raw = await const MethodChannel('com.langbai.resolver/local_media')
          .invokeMapMethod<String, dynamic>('saveMobileFile', {
        'path': target.path,
        'filename': filename,
        'save_destination': destination.name,
        'custom_destination_uri': customDestinationUri,
        'media_type': mediaType,
      });
      if (raw == null) {
        throw PlatformException(
          code: 'SAVE_RESULT_MISSING',
          message: '系统没有确认文件已保存',
        );
      }
      reportPublished();
      return SaveResult(
        message: raw['message']?.toString() ??
            (destination == SaveDestination.gallery
                ? '已保存到系统相册'
                : '已保存到 Download/langbai解析'),
        path: raw['path']?.toString(),
      );
    } finally {
      try {
        if (await target.exists()) await target.delete();
      } on FileSystemException {
        // The published file is authoritative; stale temp cleanup is best-effort.
      }
    }
  }
  reportPublished();
  return SaveResult(message: '文件已保存至 ${target.path}', path: target.path);
}

String _safeFilename(String value) {
  final leaf = value.split(RegExp(r'[\\/]')).last.trim();
  final cleaned = leaf.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
  return cleaned.isEmpty ? 'langbai-download.bin' : cleaned;
}

String? _localPath(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.scheme == 'file') return uri.toFilePath();
  return trimmed;
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
