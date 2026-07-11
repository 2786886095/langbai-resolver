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

class LocalDirectorySelection {
  const LocalDirectorySelection({required this.uri, required this.name});

  final String uri;
  final String name;
}

class LocalConversionResult {
  const LocalConversionResult({
    required this.processId,
    required this.filename,
    required this.format,
    required this.message,
    this.path,
  });

  final String processId;
  final String filename;
  final String format;
  final String message;
  final String? path;
}

class LocalMediaProbeStream {
  const LocalMediaProbeStream({
    required this.index,
    required this.type,
    this.codec,
    this.width,
    this.height,
    this.sampleRate,
    this.channels,
    this.bitrateBps,
  });

  factory LocalMediaProbeStream.fromJson(Map<String, dynamic> json) =>
      LocalMediaProbeStream(
        index: _progressInt(json['index']) ?? 0,
        type: json['type']?.toString() ?? 'unknown',
        codec: json['codec']?.toString(),
        width: _progressInt(json['width']),
        height: _progressInt(json['height']),
        sampleRate: _progressInt(json['sample_rate']),
        channels: _progressInt(json['channels']),
        bitrateBps: _progressInt(json['bitrate_bps']),
      );

  final int index;
  final String type;
  final String? codec;
  final int? width;
  final int? height;
  final int? sampleRate;
  final int? channels;
  final int? bitrateBps;
}

class LocalMediaProbeResult {
  const LocalMediaProbeResult({
    required this.filename,
    required this.extension,
    required this.sizeBytes,
    required this.hasVideo,
    required this.hasAudio,
    required this.streams,
    this.mimeType,
    this.durationSeconds,
    this.width,
    this.height,
  });

  final String filename;
  final String extension;
  final String? mimeType;
  final int sizeBytes;
  final double? durationSeconds;
  final int? width;
  final int? height;
  final bool hasVideo;
  final bool hasAudio;
  final List<LocalMediaProbeStream> streams;
}

class LocalConversionCapabilities {
  const LocalConversionCapabilities({
    this.inputExtensions = const <String>[],
    this.outputFormats = const <String>[],
    this.qualityValues = const <String>[],
  });

  factory LocalConversionCapabilities.fromJson(Object? value) {
    if (value is! Map) return const LocalConversionCapabilities();
    List<String> values(String key) {
      final raw = value[key];
      if (raw is! List) return const <String>[];
      return raw
          .map((item) => item.toString().trim().toLowerCase())
          .where((item) => item.isNotEmpty)
          .toSet()
          .toList(growable: false);
    }

    return LocalConversionCapabilities(
      inputExtensions: values('input_extensions'),
      outputFormats: values('output_formats'),
      qualityValues: values('quality_values'),
    );
  }

  final List<String> inputExtensions;
  final List<String> outputFormats;
  final List<String> qualityValues;
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
    this.formatConversion = false,
    this.conversionProgress = false,
    this.conversionCancellation = false,
    this.appUpdateInstall = false,
    this.mediaProbe = false,
    this.customSaveDirectory = false,
    this.conversion = const LocalConversionCapabilities(),
    this.currentAbi,
    this.supportedAbis = const <String>[],
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
  final bool formatConversion;
  final bool conversionProgress;
  final bool conversionCancellation;
  final bool appUpdateInstall;
  final bool mediaProbe;
  final bool customSaveDirectory;
  final LocalConversionCapabilities conversion;
  final String? currentAbi;
  final List<String> supportedAbis;

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
      formatConversion: json['format_conversion'] == true,
      conversionProgress: json['conversion_progress'] == true,
      conversionCancellation: json['conversion_cancellation'] == true,
      appUpdateInstall: json['app_update_install'] == true,
      mediaProbe: json['media_probe'] == true,
      customSaveDirectory: json['custom_save_directory'] == true,
      conversion: LocalConversionCapabilities.fromJson(json['conversion']),
      currentAbi: json['current_abi']?.toString().trim(),
      supportedAbis: json['supported_abis'] is List
          ? (json['supported_abis'] as List)
                .map((item) => item.toString().trim())
                .where((item) => item.isNotEmpty)
                .toList(growable: false)
          : const <String>[],
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
  final Map<String, TransferProgressCallback> _progressDetailListeners = {};
  final Map<String, TransferProgressCallback> _conversionProgressListeners = {};
  final Map<String, TransferProgressCallback> _updateProgressListeners = {};

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
    TransferProgressCallback? onProgressDetails,
    String? processId,
    String? customDestinationUri,
  }) async {
    final taskId = processId ?? createProcessId();
    if (onProgress != null) _progressListeners[taskId] = onProgress;
    if (onProgressDetails != null) {
      _progressDetailListeners[taskId] = onProgressDetails;
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('download', {
        'media_id': mediaId,
        'option_id': optionId,
        'process_id': taskId,
        'media_type': kind.name,
        'save_destination': destination.name,
        'custom_destination_uri': customDestinationUri,
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
      _progressDetailListeners.remove(taskId);
    }
  }

  Future<LocalDirectorySelection> pickSaveDirectory() async {
    if (!isSupported) {
      throw const LocalMediaException('当前平台不支持选择手机保存目录');
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('pickSaveDirectory');
      final json = _normalize(raw);
      if (json is! Map<String, dynamic>) {
        throw const LocalMediaException('系统返回的保存目录格式不正确');
      }
      final uri = json['uri']?.toString().trim() ?? '';
      if (uri.isEmpty) throw const LocalMediaException('没有选择保存目录');
      return LocalDirectorySelection(
        uri: uri,
        name: json['name']?.toString().trim().isNotEmpty == true
            ? json['name'].toString().trim()
            : '自选目录',
      );
    } on PlatformException catch (error) {
      throw LocalMediaException(_cleanLocalError(error.message ?? '无法选择保存目录'));
    } on MissingPluginException {
      throw const LocalMediaException('当前安装包不支持自选保存目录');
    }
  }

  Future<LocalConversionResult> convertMedia({
    required String inputPath,
    required String outputFormat,
    required String quality,
    SaveDestination destination = SaveDestination.files,
    String? customDestinationUri,
    String? processId,
    TransferProgressCallback? onProgress,
  }) async {
    if (!isSupported) {
      throw const LocalMediaException('当前平台没有本地格式转换能力');
    }
    final taskId = processId ?? createProcessId();
    if (onProgress != null) _conversionProgressListeners[taskId] = onProgress;
    try {
      final raw = await _channel.invokeMethod<Object?>('convertMedia', {
        'process_id': taskId,
        'input_path': inputPath,
        'output_format': outputFormat.trim().toLowerCase(),
        'quality': quality.trim().toLowerCase(),
        'save_destination': destination.name,
        'custom_destination_uri': customDestinationUri,
      });
      final json = _normalize(raw);
      if (json is! Map<String, dynamic>) {
        throw const LocalMediaException('本地转换器返回的数据格式不正确');
      }
      return LocalConversionResult(
        processId: json['process_id']?.toString() ?? taskId,
        filename: json['filename']?.toString() ?? 'langbai-converted',
        path: json['path']?.toString(),
        format: json['format']?.toString() ?? outputFormat,
        message: json['message']?.toString() ?? '格式转换完成',
      );
    } on PlatformException catch (error) {
      throw LocalMediaException(_cleanLocalError(error.message ?? '本地格式转换失败'));
    } on MissingPluginException {
      throw const LocalMediaException('当前安装包没有包含本地格式转换器');
    } finally {
      _conversionProgressListeners.remove(taskId);
    }
  }

  Future<LocalMediaProbeResult> probeMedia({required String inputPath}) async {
    if (!isSupported) {
      throw const LocalMediaException('当前平台没有本地媒体信息检测能力');
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('probeMedia', {
        'input_path': inputPath,
      });
      final json = _normalize(raw);
      if (json is! Map<String, dynamic>) {
        throw const LocalMediaException('本地媒体检测器返回的数据格式不正确');
      }
      final rawStreams = json['streams'];
      return LocalMediaProbeResult(
        filename: json['filename']?.toString() ?? 'media',
        extension: json['extension']?.toString() ?? '',
        mimeType: json['mime_type']?.toString(),
        sizeBytes: _progressInt(json['size_bytes']) ?? 0,
        durationSeconds: (json['duration_seconds'] as num?)?.toDouble(),
        width: _progressInt(json['width']),
        height: _progressInt(json['height']),
        hasVideo: json['has_video'] == true,
        hasAudio: json['has_audio'] == true,
        streams: rawStreams is List
            ? rawStreams
                  .whereType<Map>()
                  .map(
                    (item) => LocalMediaProbeStream.fromJson(
                      item.cast<String, dynamic>(),
                    ),
                  )
                  .toList(growable: false)
            : const <LocalMediaProbeStream>[],
      );
    } on PlatformException catch (error) {
      throw LocalMediaException(_cleanLocalError(error.message ?? '读取媒体信息失败'));
    } on MissingPluginException {
      throw const LocalMediaException('当前安装包没有包含本地媒体检测器');
    }
  }

  Future<bool> cancelConversion(String processId) async {
    if (!isSupported || processId.trim().isEmpty) return false;
    try {
      final raw = await _channel.invokeMethod<Object?>('cancelConversion', {
        'process_id': processId,
      });
      final json = _normalize(raw);
      return json is Map<String, dynamic> && json['cancelled'] == true;
    } on PlatformException catch (error) {
      throw LocalMediaException(_cleanLocalError(error.message ?? '取消转换失败'));
    }
  }

  Future<String> installAppUpdate({
    required String url,
    required String sha256,
    required int? sizeBytes,
    String? processId,
    TransferProgressCallback? onProgress,
  }) async {
    if (!isSupported || defaultTargetPlatform != TargetPlatform.android) {
      throw const LocalMediaException('当前平台不允许应用内安装更新');
    }
    final taskId = processId ?? createProcessId();
    if (onProgress != null) _updateProgressListeners[taskId] = onProgress;
    try {
      final raw = await _channel.invokeMethod<Object?>('installAppUpdate', {
        'process_id': taskId,
        'url': url,
        'sha256': sha256,
        'size_bytes': sizeBytes,
      });
      final json = _normalize(raw);
      if (json is Map<String, dynamic>) {
        return json['message']?.toString() ?? '安装程序已打开';
      }
      return '安装程序已打开';
    } on PlatformException catch (error) {
      throw LocalMediaException(_cleanLocalError(error.message ?? '应用更新失败'));
    } on MissingPluginException {
      throw const LocalMediaException('当前安装包不支持应用内更新');
    } finally {
      _updateProgressListeners.remove(taskId);
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
    final json = _normalize(call.arguments);
    if (json is! Map<String, dynamic>) return;
    final processId = json['process_id']?.toString();
    if (processId == null) return;
    final progress = _transferProgressFromNativeJson(json);
    if (progress == null) return;
    switch (call.method) {
      case 'downloadProgress':
        _progressListeners[processId]?.call(progress.progress);
        _progressDetailListeners[processId]?.call(progress);
      case 'conversionProgress':
        _conversionProgressListeners[processId]?.call(progress);
      case 'updateProgress':
        _updateProgressListeners[processId]?.call(progress);
    }
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

TransferProgress? _transferProgressFromNativeJson(Map<String, dynamic> json) {
  final rawProgress = (json['progress'] as num?)?.toDouble();
  if (rawProgress == null) return null;
  // Android and iOS callbacks use percentage points (0..100), including
  // fractional values below 1 such as 0.5%. Dart-only transfer callbacks use
  // normalized values separately and must not pass through this decoder.
  final normalized = rawProgress.clamp(0, 100).toDouble() / 100;
  return TransferProgress(
    progress: normalized,
    downloadedBytes: _progressInt(json['downloaded_bytes']),
    totalBytes: _progressInt(json['total_bytes']),
    speedBytesPerSecond: (json['speed_bytes_per_second'] as num?)?.toDouble(),
    averageSpeedBytesPerSecond: (json['average_speed_bytes_per_second'] as num?)
        ?.toDouble(),
    etaSeconds: _progressInt(json['eta_seconds']),
    status: json['status']?.toString(),
  );
}

int? _progressInt(Object? value) => switch (value) {
  final int number => number,
  final num number => number.toInt(),
  final String text => int.tryParse(text),
  _ => null,
};
