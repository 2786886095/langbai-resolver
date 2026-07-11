import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/media_models.dart';
import 'download_types.dart';

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

class LocalMediaCapabilities {
  const LocalMediaCapabilities({
    required this.platform,
    required this.localResolver,
    required this.engineUpdate,
    required this.downloadProgress,
    required this.downloadCancellation,
    required this.backgroundDownload,
    required this.saveToFiles,
    required this.saveToGallery,
    required this.tools,
  });

  final String platform;
  final bool localResolver;
  final bool engineUpdate;
  final bool downloadProgress;
  final bool downloadCancellation;
  final bool backgroundDownload;
  final bool saveToFiles;
  final bool saveToGallery;
  final Map<String, bool> tools;

  factory LocalMediaCapabilities.fromJson(Map<String, dynamic> json) {
    final rawTools = json['tools'];
    return LocalMediaCapabilities(
      platform: json['platform']?.toString() ?? 'unknown',
      localResolver: json['local_resolver'] == true,
      engineUpdate: json['engine_update'] == true,
      downloadProgress: json['download_progress'] == true,
      downloadCancellation: json['download_cancellation'] == true,
      backgroundDownload: json['background_download'] == true,
      saveToFiles: json['save_to_files'] == true,
      saveToGallery: json['save_to_gallery'] == true,
      tools: rawTools is Map
          ? <String, bool>{
              for (final entry in rawTools.entries)
                entry.key.toString(): entry.value == true,
            }
          : const <String, bool>{},
    );
  }
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

  String createProcessId() =>
      'local-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  Future<LocalMediaCapabilities> capabilities() async {
    if (!isSupported) {
      return const LocalMediaCapabilities(
        platform: 'unsupported',
        localResolver: false,
        engineUpdate: false,
        downloadProgress: false,
        downloadCancellation: false,
        backgroundDownload: false,
        saveToFiles: false,
        saveToGallery: false,
        tools: <String, bool>{},
      );
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('getCapabilities');
      final json = _normalize(raw);
      if (json is! Map<String, dynamic>) {
        throw const LocalMediaException('本地能力信息格式不正确');
      }
      return LocalMediaCapabilities.fromJson(json);
    } on PlatformException catch (error) {
      throw LocalMediaException(
        _cleanLocalError(error.message ?? '无法读取本地能力信息'),
      );
    } on MissingPluginException {
      throw const LocalMediaException('当前安装包没有包含手机本地解析器');
    }
  }

  Future<MediaInfo> resolve(String url, {String? bilibiliCookie}) async {
    if (!isSupported) {
      throw const LocalMediaException('当前平台未启用本地解析器');
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('resolve', {
        'url': url,
        'bilibili_cookie': ?bilibiliCookie,
      });
      final json = _normalize(raw);
      if (json is! Map<String, dynamic>) {
        throw const LocalMediaException('本地解析器返回的数据格式不正确');
      }
      return MediaInfo.fromJson(json);
    } on PlatformException catch (error) {
      throw LocalMediaException(_cleanLocalError(error.message ?? '手机本地解析失败'));
    } on MissingPluginException {
      throw const LocalMediaException('当前安装包没有包含手机本地解析器');
    }
  }

  Future<LocalDownloadResult> download({
    required String mediaId,
    required String optionId,
    required AssetKind kind,
    required SaveDestination destination,
    ValueChanged<double>? onProgress,
    String? processId,
  }) async {
    final taskId = processId ?? createProcessId();
    if (onProgress != null) _progressListeners[taskId] = onProgress;
    try {
      final raw = await _channel.invokeMethod<Object?>('download', {
        'media_id': mediaId,
        'option_id': optionId,
        'process_id': taskId,
        'media_type': kind.name,
        'save_destination': destination.name,
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
      throw LocalMediaException(_cleanLocalError(error.message ?? '手机本地下载失败'));
    } finally {
      _progressListeners.remove(taskId);
    }
  }

  Future<bool> cancelDownload(String processId) async {
    if (!isSupported || processId.trim().isEmpty) return false;
    try {
      final raw = await _channel.invokeMethod<Object?>('cancelDownload', {
        'process_id': processId,
      });
      final json = _normalize(raw);
      return json is Map<String, dynamic> && json['cancelled'] == true;
    } on PlatformException catch (error) {
      throw LocalMediaException(_cleanLocalError(error.message ?? '取消下载失败'));
    }
  }

  Future<void> clearNativeSession() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<Object?>('clearSession');
    } on PlatformException catch (error) {
      throw LocalMediaException(
        _cleanLocalError(error.message ?? '清除本地登录缓存失败'),
      );
    } on MissingPluginException {
      // Older packages do not have native cache state to clear through this API.
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
      throw LocalMediaException(_cleanLocalError(error.message ?? '本地解析器更新失败'));
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

String _cleanLocalError(String value) {
  final withoutAnsi = value.replaceAll(
    RegExp(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])'),
    '',
  );
  return withoutAnsi
      .replaceFirst(RegExp(r'^(?:\s*ERROR:\s*)+', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
