import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

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
}) async {
  if (headers.isEmpty) {
    web.HTMLAnchorElement()
      ..href = uri.toString()
      ..download = filename
      ..target = '_blank'
      ..click();
    onProgress(1);
    onTransferProgress?.call(const TransferProgress(progress: 1));
    return const SaveResult(message: '浏览器下载已开始');
  }

  const maxBufferedBytes = 512 * 1024 * 1024;
  final client = http.Client();
  try {
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers.addAll(headers);
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('文件下载失败（${response.statusCode}）');
    }
    if (response.contentLength != null &&
        response.contentLength! > maxBufferedBytes) {
      throw StateError('Web 端带身份验证的下载最大支持 512 MB，请使用桌面客户端');
    }
    final bytes = BytesBuilder(copy: false);
    var received = 0;
    final stopwatch = Stopwatch()..start();
    var lastReceived = 0;
    var lastElapsed = Duration.zero;
    double? smoothedSpeed;
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 60),
    )) {
      if (isCancelled?.call() == true) throw StateError('下载已取消');
      received += chunk.length;
      if (received > maxBufferedBytes) {
        throw StateError('Web 端带身份验证的下载最大支持 512 MB，请使用桌面客户端');
      }
      bytes.add(chunk);
      final total = response.contentLength;
      final elapsed = stopwatch.elapsed;
      if (total != null && total > 0) {
        final value = (received / total).clamp(0, 1).toDouble();
        onProgress(value);
      }
      final shouldEmit =
          elapsed - lastElapsed >= const Duration(milliseconds: 250) ||
          (total != null && received >= total);
      if (shouldEmit) {
        final intervalSeconds =
            (elapsed - lastElapsed).inMicroseconds /
            Duration.microsecondsPerSecond;
        final instant = intervalSeconds > 0
            ? (received - lastReceived) / intervalSeconds
            : null;
        if (instant != null) {
          smoothedSpeed = smoothedSpeed == null
              ? instant
              : smoothedSpeed * 0.65 + instant * 0.35;
        }
        onTransferProgress?.call(
          TransferProgress(
            progress: total != null && total > 0
                ? (received / total).clamp(0, 1).toDouble()
                : 0,
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
    final blob = web.Blob(
      <Uint8List>[
        bytes.takeBytes(),
      ].map((value) => value.toJS).toList(growable: false).toJS,
    );
    final objectUrl = web.URL.createObjectURL(blob);
    try {
      web.HTMLAnchorElement()
        ..href = objectUrl
        ..download = filename
        ..click();
    } finally {
      web.URL.revokeObjectURL(objectUrl);
    }
    onProgress(1);
    onTransferProgress?.call(
      TransferProgress(
        progress: 1,
        downloadedBytes: received,
        totalBytes: response.contentLength ?? received,
      ),
    );
    return const SaveResult(message: '浏览器下载已开始');
  } finally {
    client.close();
  }
}
