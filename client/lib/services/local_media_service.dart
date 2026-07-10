import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/media_models.dart';

class LocalDownloadResult {
  const LocalDownloadResult({
    required this.filename,
    required this.message,
    this.path,
  });

  final String filename;
  final String message;
  final String? path;
}

class LocalMediaService {
  LocalMediaService._() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static final LocalMediaService instance = LocalMediaService._();
  static const _channel = MethodChannel('com.langbai.resolver/local_media');

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  final Map<String, ValueChanged<double>> _progressListeners = {};

  Future<MediaInfo> resolve(String url) async {
    if (!isSupported) {
      throw const LocalMediaException('当前平台未启用本地解析器');
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('resolve', {'url': url});
      final json = _normalize(raw);
      if (json is! Map<String, dynamic>) {
        throw const LocalMediaException('本地解析器返回的数据格式不正确');
      }
      return MediaInfo.fromJson(json);
    } on PlatformException catch (error) {
      throw LocalMediaException(error.message ?? '手机本地解析失败');
    } on MissingPluginException {
      throw const LocalMediaException('当前安装包没有包含手机本地解析器');
    }
  }

  Future<LocalDownloadResult> download({
    required String mediaId,
    required String optionId,
    ValueChanged<double>? onProgress,
  }) async {
    final processId =
        'local-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    if (onProgress != null) _progressListeners[processId] = onProgress;
    try {
      final raw = await _channel.invokeMethod<Object?>('download', {
        'media_id': mediaId,
        'option_id': optionId,
        'process_id': processId,
      });
      final json = _normalize(raw);
      if (json is! Map<String, dynamic>) {
        throw const LocalMediaException('本地下载器返回的数据格式不正确');
      }
      return LocalDownloadResult(
        filename: json['filename']?.toString() ?? 'langbai-media',
        message: json['message']?.toString() ?? '下载完成',
        path: json['path']?.toString(),
      );
    } on PlatformException catch (error) {
      throw LocalMediaException(error.message ?? '手机本地下载失败');
    } finally {
      _progressListeners.remove(processId);
    }
  }

  Future<String> updateEngine() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('updateEngine');
      final json = _normalize(raw);
      if (json is Map<String, dynamic>) {
        return json['version']?.toString() ?? '最新版本';
      }
      return '最新版本';
    } on PlatformException catch (error) {
      throw LocalMediaException(error.message ?? '本地解析器更新失败');
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'downloadProgress') return;
    final json = _normalize(call.arguments);
    if (json is! Map<String, dynamic>) return;
    final processId = json['process_id']?.toString();
    final progress = (json['progress'] as num?)?.toDouble();
    if (processId == null || progress == null) return;
    _progressListeners[processId]?.call(progress.clamp(0, 100) / 100);
  }
}

class LocalMediaException implements Exception {
  const LocalMediaException(this.message);

  final String message;

  @override
  String toString() => message;
}

Object? _normalize(Object? value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): _normalize(entry.value),
    };
  }
  if (value is List) return value.map(_normalize).toList(growable: false);
  return value;
}
