import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/media_models.dart';
import '../services/api_client.dart';
import '../services/api_endpoint_policy.dart';
import '../services/download_saver.dart';
import '../services/local_media_service.dart';
import '../services/open_music_service.dart';
import '../services/service_credential_store.dart';
import '../theme/langbai_theme.dart';

const _defaultToolsApiUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8787',
);

class ToolsPage extends StatefulWidget {
  const ToolsPage({
    super.key,
    this.initialInput,
    this.defaultSaveDestination = SaveDestination.files,
    this.customSaveDestinationUri,
    this.onJobChanged,
    required this.onOpenParser,
  });

  final String? initialInput;
  final SaveDestination defaultSaveDestination;
  final String? customSaveDestinationUri;
  final void Function(DownloadJob job, String title, String optionLabel)?
  onJobChanged;
  final ValueChanged<String> onOpenParser;

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  String? _selectedTool;
  XFile? _selectedFile;
  final Map<String, String> _toolInputs = {};
  late final TextEditingController _inputController;
  late ApiClient _api;
  final _openMusic = OpenMusicService();
  bool _busy = false;
  bool _cancelRequested = false;
  String? _activeJobId;
  String? _error;
  String? _statusMessage;
  DownloadJob? _job;
  double _saveProgress = 0;
  double _quality = 78;
  String _audioFormat = 'mp3';
  String _conversionFormat = 'mp4';
  String _conversionQuality = 'high';
  bool _draggingFile = false;
  bool _localConversionRunning = false;
  bool _localProbeRunning = false;
  List<MusicSearchResult> _musicResults = const [];
  List<MusicFile> _musicFiles = const [];
  List<SniffedResource> _sniffedResources = const [];
  bool? _remoteToolsHealthy;
  LocalMediaCapabilities? _localCapabilities;

  bool get _usesDirectMusic => LocalMediaService.isSupported;
  bool get _isMobileLocal => LocalMediaService.isSupported;
  bool get _localConversionAvailable =>
      _localCapabilities?.formatConversion == true &&
      _localCapabilities!.conversion.outputFormats.isNotEmpty;
  bool get _supportsDesktopDrop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  static const _tools = [
    _ToolDefinition(
      'parser',
      '视频与图片解析',
      '解析网页媒体、分辨率、音频和封面',
      Icons.play_circle_outline_rounded,
    ),
    _ToolDefinition(
      'sniff',
      '网页公开媒体识别',
      '识别网页公开返回的媒体，不绕过登录、DRM 或应用私有请求',
      Icons.travel_explore_rounded,
    ),
    _ToolDefinition(
      'audio',
      '视频提取音频',
      '导出 MP3、M4A、FLAC 或原始音轨',
      Icons.graphic_eq_rounded,
    ),
    _ToolDefinition(
      'compress',
      '媒体压缩',
      '按质量参数缩小视频和图片体积',
      Icons.compress_rounded,
    ),
    _ToolDefinition(
      'convert',
      '格式转换',
      '拖入或选择文件，按本机/服务实际能力转换格式',
      Icons.sync_alt_rounded,
    ),
    _ToolDefinition(
      'music',
      '多源音乐搜索',
      '聚合开放下载、试听与全球曲库元数据',
      Icons.headphones_rounded,
    ),
    _ToolDefinition(
      'direct',
      '公开直链下载',
      '手机一次解析一条；桌面服务可校验镜像并分段',
      Icons.link_rounded,
    ),
    _ToolDefinition(
      'transfer',
      '磁力与种子',
      '桌面服务可用；手机端未内置 P2P / 种子引擎',
      Icons.hub_outlined,
    ),
    _ToolDefinition(
      'metadata',
      '媒体信息',
      '查看编码、码率、分辨率和元数据',
      Icons.info_outline_rounded,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _inputController = TextEditingController();
    _api = ApiClient(_defaultToolsApiUrl);
    _restoreApiUrl();
    _refreshCapabilities();
    _applyInitialInput(widget.initialInput);
  }

  Future<void> _restoreApiUrl() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = normalizeTrustedApiUrl(preferences.getString('api_base_url'));
    if (!mounted || saved == null || saved.isEmpty) {
      return;
    }
    final token = await ServiceCredentialStore.readTokenFor(saved);
    if (!mounted) return;
    _api.close();
    _api = ApiClient(saved, instanceToken: token.isEmpty ? null : token);
    await _refreshCapabilities();
  }

  Future<void> _refreshCapabilities() async {
    LocalMediaCapabilities? local;
    if (LocalMediaService.isSupported) {
      try {
        local = await LocalMediaService.instance.capabilities();
      } on Object {
        local = null;
      }
    }
    final remote = LocalMediaService.isSupported
        ? false
        : await _api.isHealthy();
    if (!mounted) return;
    setState(() {
      _localCapabilities = local;
      _remoteToolsHealthy = remote;
      final formats = _availableConversionFormats();
      if (formats.isNotEmpty && !formats.contains(_conversionFormat)) {
        _conversionFormat = formats.first;
      }
      final audioFormats = _availableAudioFormats;
      if (audioFormats.isNotEmpty && !audioFormats.contains(_audioFormat)) {
        _audioFormat = audioFormats.first;
      }
      final qualities = _conversionQualityValues;
      if (qualities.isNotEmpty && !qualities.contains(_conversionQuality)) {
        _conversionQuality = qualities.first;
      }
    });
  }

  bool _toolAvailable(String id) {
    if (id == 'parser' || id == 'music') return true;
    if (id == 'convert') {
      return _localConversionAvailable ||
          (!_isMobileLocal && _remoteToolsHealthy == true);
    }
    if (_isMobileLocal) {
      return switch (id) {
        'sniff' || 'direct' => true,
        'audio' || 'compress' => _localConversionAvailable,
        'metadata' => _localCapabilities?.mediaProbe == true,
        'transfer' => false,
        _ => false,
      };
    }
    if (_remoteToolsHealthy == true) return true;
    return false;
  }

  String _toolAvailabilityLabel(String id) {
    if (id == 'parser' || id == 'music') {
      return LocalMediaService.isSupported ? '本机可用' : '可用';
    }
    if (id == 'convert' && _localConversionAvailable) return '本机可用';
    if (_isMobileLocal) {
      return switch (id) {
        'sniff' => '本机公开媒体识别',
        'direct' => '本机解析下载',
        'audio' || 'compress' when _localConversionAvailable => '本机可用',
        'metadata' when _localCapabilities?.mediaProbe == true => '本机可用',
        'transfer' => '手机端未内置 P2P',
        _ => '本机暂不支持',
      };
    }
    if (_remoteToolsHealthy == null) return '检测中';
    if (_remoteToolsHealthy == true) return '服务可用';
    return '需连接高级工具服务';
  }

  void _selectOrExplain(_ToolDefinition tool) {
    if (_toolAvailable(tool.id)) {
      _selectTool(tool.id);
      return;
    }
    _selectTool(tool.id);
    final message = _isMobileLocal
        ? tool.id == 'transfer'
              ? '手机端未内置 P2P / 种子引擎，当前不能创建磁力或种子任务。'
              : '${tool.title}当前没有可用的本机实现。'
        : '${tool.title}需要连接受信任的高级工具服务，请先在设置中配置。';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(label: '重试', onPressed: _refreshCapabilities),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant ToolsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialInput != oldWidget.initialInput) {
      _applyInitialInput(widget.initialInput);
    }
  }

  void _applyInitialInput(String? value) {
    if (value == null || value.isEmpty) return;
    final tool = _tools.any((item) => item.id == value)
        ? value
        : value.startsWith('magnet:') || value.endsWith('.torrent')
        ? 'transfer'
        : 'direct';
    _selectTool(
      tool,
      input: tool == 'transfer' || tool == 'direct' ? value : null,
      notify: false,
    );
  }

  void _selectTool(String tool, {String? input, bool notify = true}) {
    final current = _selectedTool;
    if (current != null) _toolInputs[current] = _inputController.text;
    if (input != null) _toolInputs[tool] = input;

    void apply() {
      _selectedTool = tool;
      _inputController.text = _toolInputs[tool] ?? '';
      _inputController.selection = TextSelection.collapsed(
        offset: _inputController.text.length,
      );
      _error = null;
      _statusMessage = null;
      _job = null;
      _saveProgress = 0;
      _musicResults = const [];
      _musicFiles = const [];
      _sniffedResources = const [];
    }

    if (notify && mounted) {
      setState(apply);
    } else {
      apply();
    }
  }

  @override
  void dispose() {
    _api.close();
    _openMusic.close();
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final file = await openFile();
    if (file == null || !mounted) return;
    _selectFile(file);
  }

  void _selectFile(XFile file) {
    if (!mounted) return;
    setState(() {
      _selectedFile = file;
      _draggingFile = false;
      _error = null;
      final formats = _availableConversionFormats(file);
      if (formats.isNotEmpty && !formats.contains(_conversionFormat)) {
        _conversionFormat = formats.first;
      }
    });
  }

  void _acceptDroppedFiles(List<XFile> files) {
    if (files.isEmpty) return;
    _selectFile(files.first);
    if (files.length > 1 && mounted) {
      setState(() => _statusMessage = '当前一次转换一个文件，已选择 ${files.first.name}');
    }
  }

  List<String> _availableConversionFormats([XFile? selected]) {
    if (_localConversionAvailable) {
      final outputs = _localCapabilities!.conversion.outputFormats
          .map(_normalizeExtension)
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList(growable: false);
      final file = selected ?? _selectedFile;
      if (file == null) return outputs;
      final extension = _fileExtension(file.name);
      if (_imageExtensions.contains(extension)) {
        return outputs
            .where(_imageMediaFormats.contains)
            .toList(growable: false);
      }
      if (_audioExtensions.contains(extension)) {
        return outputs
            .where(_audioMediaFormats.contains)
            .toList(growable: false);
      }
      if (_videoExtensions.contains(extension)) {
        return outputs
            .where(
              (format) =>
                  _videoMediaFormats.contains(format) ||
                  _audioMediaFormats.contains(format),
            )
            .toList(growable: false);
      }
      return const <String>[];
    }
    if (_remoteToolsHealthy != true) return const <String>[];
    final file = selected ?? _selectedFile;
    if (file == null) {
      return const ['mp4', 'mp3', 'm4a', 'flac', 'wav', 'jpg', 'png', 'webp'];
    }
    final extension = _fileExtension(file.name);
    if (_imageExtensions.contains(extension)) {
      return const ['jpg', 'jpeg', 'png', 'webp'];
    }
    if (_audioExtensions.contains(extension)) {
      return const ['mp3', 'm4a', 'flac', 'wav'];
    }
    if (_videoExtensions.contains(extension)) {
      return const ['mp4', 'mp3', 'm4a', 'flac', 'wav'];
    }
    return const <String>[];
  }

  List<String> get _conversionQualityValues {
    if (_localConversionAvailable &&
        _localCapabilities!.conversion.qualityValues.isNotEmpty) {
      return _localCapabilities!.conversion.qualityValues;
    }
    return const ['low', 'medium', 'high'];
  }

  List<String> get _availableAudioFormats {
    if (_localConversionAvailable) {
      return _localCapabilities!.conversion.outputFormats
          .map(_normalizeExtension)
          .where(_audioMediaFormats.contains)
          .toList(growable: false);
    }
    return const ['mp3', 'm4a', 'flac', 'wav'];
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(26, 28, 26, 42),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '工具箱',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '解析、转换和高级下载集中在一个工作台',
                  style: TextStyle(color: context.palette.textMuted),
                ),
                const SizedBox(height: 24),
                if (_remoteToolsHealthy == false) ...[
                  _ToolAvailabilityNotice(
                    onRetry: _refreshCapabilities,
                    localConversion: _localConversionAvailable,
                    mobile: _isMobileLocal,
                  ),
                  const SizedBox(height: 16),
                ],
                LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 900
                        ? 4
                        : constraints.maxWidth >= 620
                        ? 3
                        : constraints.maxWidth >= 420
                        ? 2
                        : 1;
                    final width =
                        (constraints.maxWidth - (columns - 1) * 12) / columns;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final tool in _tools)
                          SizedBox(
                            width: width,
                            child: _ToolCard(
                              tool: tool,
                              selected: _selectedTool == tool.id,
                              enabled: _toolAvailable(tool.id),
                              availability: _toolAvailabilityLabel(tool.id),
                              onTap: () => _selectOrExplain(tool),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                if (_selectedTool != null) ...[
                  const SizedBox(height: 20),
                  _ToolWorkspace(
                    tool: _tools.firstWhere((item) => item.id == _selectedTool),
                    inputController: _inputController,
                    selectedFile: _selectedFile,
                    quality: _quality,
                    audioFormat: _audioFormat,
                    audioFormats: _availableAudioFormats,
                    conversionFormat: _conversionFormat,
                    conversionFormats: _availableConversionFormats(),
                    conversionQuality: _conversionQuality,
                    conversionQualityValues: _conversionQualityValues,
                    busy: _busy,
                    supportsFileDrop: _supportsDesktopDrop,
                    draggingFile: _draggingFile,
                    onPickFile: _pickFile,
                    onDroppedFiles: _acceptDroppedFiles,
                    onDragStateChanged: (value) =>
                        setState(() => _draggingFile = value),
                    onQualityChanged: (value) =>
                        setState(() => _quality = value),
                    onAudioFormatChanged: (value) =>
                        setState(() => _audioFormat = value),
                    onConversionFormatChanged: (value) =>
                        setState(() => _conversionFormat = value),
                    onConversionQualityChanged: (value) =>
                        setState(() => _conversionQuality = value),
                    onRun: _runSelectedTool,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    _ToolError(message: _error!),
                  ],
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 12),
                    _ToolStatus(message: _statusMessage!),
                  ],
                  if (_job != null) ...[
                    const SizedBox(height: 12),
                    _ToolProgress(
                      job: _job!,
                      saveProgress: _saveProgress,
                      onCancel: _busy && !_localProbeRunning
                          ? _cancelToolTask
                          : null,
                    ),
                  ],
                  if (_musicResults.isNotEmpty ||
                      _musicFiles.isNotEmpty ||
                      _sniffedResources.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _ToolResults(
                      musicResults: _musicResults,
                      musicFiles: _musicFiles,
                      sniffedResources: _sniffedResources,
                      onOpenMusic: _openMusicResult,
                      onDownloadUrl: widget.onOpenParser,
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _runSelectedTool() async {
    final tool = _selectedTool;
    if (tool == null || _busy) return;
    if (!_toolAvailable(tool)) {
      setState(
        () => _error = _isMobileLocal && tool == 'transfer'
            ? '手机端未内置 P2P / 种子引擎，当前不能执行该任务'
            : _isMobileLocal
            ? '当前安装包没有报告可执行该工具的本机能力'
            : '当前平台未连接可执行该工具的服务',
      );
      return;
    }
    final input = _inputController.text.trim();
    if (tool == 'parser') {
      if (input.isEmpty) {
        setState(() => _error = '请先输入链接');
      } else {
        widget.onOpenParser(input);
      }
      return;
    }
    if (_isMobileLocal && (tool == 'sniff' || tool == 'direct')) {
      final sources = input
          .split(RegExp(r'[\r\n]+'))
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
      if (sources.isEmpty) {
        setState(() => _error = '请先输入公开网页或媒体直链');
      } else if (sources.length > 1) {
        setState(() => _error = '手机本机解析一次处理一条链接，请保留一条后重试');
      } else {
        widget.onOpenParser(sources.single);
      }
      return;
    }
    setState(() {
      _busy = true;
      _cancelRequested = false;
      _activeJobId = null;
      _localConversionRunning = false;
      _localProbeRunning = false;
      _error = null;
      _statusMessage = null;
      _job = null;
      _saveProgress = 0;
      _musicResults = const [];
      _musicFiles = const [];
      _sniffedResources = const [];
    });
    try {
      if (tool == 'sniff') {
        if (input.isEmpty) throw const ApiException('请输入要嗅探的网页链接');
        final result = await _api.sniff(input);
        if (mounted) {
          setState(() {
            _sniffedResources = result.resources;
            if (result.resources.isEmpty) {
              _statusMessage = '页面中没有发现公开、可直接访问的媒体资源';
            }
          });
        }
      } else if (tool == 'music') {
        if (input.isEmpty) throw const ApiException('请输入歌曲、歌手或专辑');
        final results = _usesDirectMusic
            ? await _openMusic.search(input)
            : await _api.searchMusic(input);
        if (mounted) {
          setState(() {
            _musicResults = results;
            final warnings = _usesDirectMusic
                ? _openMusic.lastWarnings
                : const <String>[];
            if (results.isEmpty) {
              _statusMessage = warnings.isEmpty
                  ? '没有找到匹配结果，请尝试歌手、歌曲或专辑的完整名称'
                  : '部分来源不可用，且其余来源没有找到结果：${warnings.join('；')}';
            } else if (warnings.isNotEmpty) {
              _statusMessage = '已返回可用结果；${warnings.join('；')}';
            }
          });
        }
      } else if (tool == 'direct') {
        if (input.isEmpty) throw const ApiException('请输入至少一条公开直链');
        await _monitorAndSave(await _api.createTransfer(input));
      } else if (tool == 'transfer') {
        final torrentFile = _selectedFile;
        if (torrentFile != null &&
            torrentFile.name.toLowerCase().endsWith('.torrent')) {
          await _monitorAndSave(await _api.createTorrentFile(torrentFile));
        } else {
          if (input.isEmpty) {
            throw const ApiException('请输入 Magnet/种子链接，或选择 .torrent 文件');
          }
          await _monitorAndSave(await _api.createTransfer(input));
        }
      } else if (tool == 'convert') {
        final file = _selectedFile;
        if (file == null) throw const ApiException('请先选择或拖入本地文件');
        await _runConversion(file);
      } else if (_isMobileLocal && (tool == 'audio' || tool == 'compress')) {
        final file = _selectedFile;
        if (file == null) throw const ApiException('请先选择本地文件');
        final outputFormat = tool == 'audio'
            ? _audioFormat
            : _preferredCompressionFormat(file);
        await _runNativeConversion(
          file,
          outputFormat: outputFormat,
          quality: _quality >= 80
              ? 'high'
              : _quality >= 55
              ? 'medium'
              : 'low',
        );
      } else if (_isMobileLocal && tool == 'metadata') {
        final file = _selectedFile;
        if (file == null) throw const ApiException('请先选择本地文件');
        await _runLocalProbe(file);
      } else {
        final file = _selectedFile;
        if (file == null) throw const ApiException('请先选择本地文件');
        final operation = switch (tool) {
          'audio' => 'extract_audio',
          'compress' =>
            _isImage(file.name) ? 'compress_image' : 'compress_video',
          'metadata' => 'metadata',
          _ => throw const ApiException('不支持的工具操作'),
        };
        final output = operation == 'extract_audio'
            ? _audioFormat
            : operation == 'compress_image'
            ? 'webp'
            : '';
        final job = await _api.createToolJob(
          file: file,
          operation: operation,
          outputFormat: output,
          quality: _quality.round(),
        );
        await _monitorAndSave(job);
      }
    } on ApiException catch (error) {
      _recordToolFailure(error.message);
    } on LocalMediaException catch (error) {
      _recordToolFailure(error.message);
    } on TimeoutException {
      _recordToolFailure('任务请求超时，请稍后重试');
    } on Object catch (error) {
      _recordToolFailure('任务失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _localConversionRunning = false;
          _localProbeRunning = false;
        });
      }
    }
  }

  void _recordToolFailure(String message) {
    if (!mounted) return;
    final current = _job;
    final terminal = current?.terminalFailure(
      message,
      cancelled: _cancelRequested,
    );
    final changed = current != null && !identical(current, terminal);
    setState(() {
      _error = message;
      if (changed) _job = terminal;
    });
    if (changed) _notifyToolJob(terminal!);
  }

  Future<void> _runConversion(XFile file) async {
    final formats = _availableConversionFormats(file);
    if (formats.isEmpty) {
      throw ApiException(
        '当前执行器不支持 ${_fileExtension(file.name).toUpperCase()} 输入',
      );
    }
    if (!formats.contains(_conversionFormat)) {
      throw ApiException('当前输入不支持转换为 ${_conversionFormat.toUpperCase()}');
    }
    if (_localConversionAvailable) {
      final supportedInputs = _localCapabilities!.conversion.inputExtensions
          .map(_normalizeExtension)
          .where((value) => value.isNotEmpty)
          .toSet();
      final inputExtension = _fileExtension(file.name);
      if (supportedInputs.isNotEmpty &&
          !supportedInputs.contains(inputExtension)) {
        throw ApiException('本机转换器不支持 ${inputExtension.toUpperCase()} 输入');
      }
      await _runNativeConversion(
        file,
        outputFormat: _conversionFormat,
        quality: _conversionQuality,
      );
      return;
    }

    final operation = _remoteConversionOperation(file, _conversionFormat);
    final job = await _api.createToolJob(
      file: file,
      operation: operation,
      outputFormat: _conversionFormat,
      quality: _remoteQuality(_conversionQuality),
    );
    await _monitorAndSave(job);
  }

  Future<void> _runNativeConversion(
    XFile file, {
    required String outputFormat,
    required String quality,
  }) async {
    final supportedOutputs = _localCapabilities!.conversion.outputFormats
        .map(_normalizeExtension)
        .toSet();
    if (!supportedOutputs.contains(outputFormat)) {
      throw ApiException('本机转换器不支持输出 ${outputFormat.toUpperCase()}');
    }
    final processId = LocalMediaService.instance.createProcessId();
    _activeJobId = processId;
    _localConversionRunning = true;
    var job = DownloadJob(id: processId, state: JobState.running, progress: 0);
    if (mounted) setState(() => _job = job);
    _notifyToolJob(job);
    final destination = _destinationForOutput(outputFormat);
    if (destination == SaveDestination.custom &&
        widget.customSaveDestinationUri?.trim().isNotEmpty != true) {
      throw const ApiException('自选保存目录不可用，请在设置中重新选择');
    }
    final result = await LocalMediaService.instance.convertMedia(
      inputPath: file.path,
      outputFormat: outputFormat,
      quality: quality,
      destination: destination,
      customDestinationUri: widget.customSaveDestinationUri,
      processId: processId,
      onProgress: (progress) {
        if (!mounted) return;
        job = DownloadJob(
          id: processId,
          state: JobState.running,
          progress: progress.progress,
          filename: job.filename,
          downloadedBytes: progress.downloadedBytes,
          totalBytes: progress.totalBytes,
          speedBytesPerSecond: progress.speedBytesPerSecond,
          averageSpeedBytesPerSecond: progress.averageSpeedBytesPerSecond,
          etaSeconds: progress.etaSeconds,
        );
        setState(() => _job = job);
        _notifyToolJob(job);
      },
    );
    job = DownloadJob(
      id: processId,
      state: JobState.completed,
      progress: 1,
      filename: result.filename,
      downloadedBytes: job.downloadedBytes,
      totalBytes: job.totalBytes,
      averageSpeedBytesPerSecond: job.averageSpeedBytesPerSecond,
    );
    if (mounted) {
      setState(() {
        _job = job;
        _saveProgress = 1;
        _statusMessage = result.path ?? result.message;
      });
    }
    _notifyToolJob(job);
  }

  String _preferredCompressionFormat(XFile file) {
    final outputs = _localCapabilities!.conversion.outputFormats
        .map(_normalizeExtension)
        .toSet();
    final preferred = _imageExtensions.contains(_fileExtension(file.name))
        ? const ['webp', 'jpg', 'jpeg', 'png', 'heic']
        : const ['mp4', 'mov', 'm4v', 'webm'];
    return preferred.firstWhere(
      outputs.contains,
      orElse: () => throw const ApiException('本机转换器没有适合该媒体的压缩输出格式'),
    );
  }

  Future<void> _runLocalProbe(XFile file) async {
    final processId = LocalMediaService.instance.createProcessId();
    _activeJobId = processId;
    _localProbeRunning = true;
    var job = DownloadJob(id: processId, state: JobState.running, progress: 0);
    if (mounted) setState(() => _job = job);
    _notifyToolJob(job);
    final result = await LocalMediaService.instance.probeMedia(
      inputPath: file.path,
    );
    job = DownloadJob(
      id: processId,
      state: JobState.completed,
      progress: 1,
      filename: result.filename,
      downloadedBytes: result.sizeBytes,
      totalBytes: result.sizeBytes,
    );
    final streamSummary = result.streams
        .map((stream) {
          final details = <String>[
            stream.type,
            if (stream.codec != null) stream.codec!,
            if (stream.width != null && stream.height != null)
              '${stream.width}×${stream.height}',
            if (stream.sampleRate != null) '${stream.sampleRate} Hz',
            if (stream.channels != null) '${stream.channels} 声道',
          ];
          return details.join(' · ');
        })
        .join('\n');
    if (mounted) {
      setState(() {
        _job = job;
        _saveProgress = 1;
        _statusMessage = <String>[
          '${result.filename} · ${_humanBytes(result.sizeBytes)}',
          if (result.mimeType != null) result.mimeType!,
          if (result.durationSeconds != null)
            '时长 ${_probeDuration(result.durationSeconds!)}',
          if (result.width != null && result.height != null)
            '画面 ${result.width}×${result.height}',
          if (streamSummary.isNotEmpty) streamSummary,
        ].join('\n');
      });
    }
    _notifyToolJob(job);
  }

  SaveDestination _destinationForOutput(String outputFormat) {
    final destination = widget.defaultSaveDestination;
    if (destination != SaveDestination.gallery) return destination;
    if (_audioMediaFormats.contains(outputFormat)) {
      return SaveDestination.files;
    }
    return SaveDestination.gallery;
  }

  String _remoteConversionOperation(XFile file, String outputFormat) {
    final input = _fileExtension(file.name);
    if (_audioOutputFormats.contains(outputFormat)) return 'extract_audio';
    if (_imageExtensions.contains(input) &&
        _imageOutputFormats.contains(outputFormat)) {
      return 'compress_image';
    }
    if (_videoExtensions.contains(input) && outputFormat == 'mp4') {
      return 'compress_video';
    }
    throw ApiException(
      '高级工具服务不支持 ${input.toUpperCase()} → ${outputFormat.toUpperCase()}',
    );
  }

  int _remoteQuality(String quality) => switch (quality) {
    'low' => 45,
    'medium' => 65,
    'original' => 95,
    _ => 82,
  };

  void _notifyToolJob(DownloadJob job) {
    final toolId = _selectedTool;
    if (toolId == null) return;
    final definition = _tools.firstWhere((item) => item.id == toolId);
    widget.onJobChanged?.call(
      job,
      _selectedFile?.name ?? definition.title,
      definition.title,
    );
  }

  Future<void> _loadMusicFiles(MusicSearchResult result) async {
    setState(() {
      _busy = true;
      _cancelRequested = false;
      _activeJobId = null;
      _error = null;
      _statusMessage = null;
    });
    try {
      final files = _usesDirectMusic
          ? await _openMusic.files(result.identifier)
          : await _api.musicFiles(result.identifier);
      if (mounted) {
        setState(() {
          _musicFiles = files;
          if (files.isEmpty) {
            _statusMessage = '该来源没有提供经过授权的直接下载文件，请打开来源页面确认权限';
          }
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on OpenMusicException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _activeJobId = null;
        });
      }
    }
  }

  Future<void> _openMusicResult(MusicSearchResult result) async {
    if (result.canDownload) {
      await _loadMusicFiles(result);
      return;
    }
    final target = result.previewUrl ?? result.itemUrl;
    final uri = Uri.tryParse(target);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) setState(() => _error = '无法打开 ${result.sourceLabel} 来源页面');
    }
  }

  Future<void> _monitorAndSave(DownloadJob initial) async {
    var job = initial;
    final taskDeadline = DateTime.now().add(const Duration(hours: 2));
    _activeJobId = job.id;
    final initialVisibleJob = _serverJobBeforePublication(job);
    if (mounted) setState(() => _job = initialVisibleJob);
    _notifyToolJob(initialVisibleJob);
    while (job.state == JobState.queued || job.state == JobState.running) {
      if (_cancelRequested) throw const ApiException('任务已取消');
      if (DateTime.now().isAfter(taskDeadline)) {
        await _api.cancelJob(job.id);
        throw TimeoutException('任务超过 2 小时，已自动取消');
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
      job = await _api.getJob(job.id);
      if (!mounted) return;
      final visibleJob = _serverJobBeforePublication(job);
      setState(() => _job = visibleJob);
      _notifyToolJob(visibleJob);
    }
    if (job.state == JobState.failed) {
      throw ApiException(job.error ?? '服务器处理失败');
    }
    if (job.state == JobState.cancelled) {
      throw const ApiException('任务已取消');
    }
    final destination = _toolSaveDestination(job.filename);
    if (destination == SaveDestination.custom &&
        widget.customSaveDestinationUri?.trim().isNotEmpty != true) {
      throw const ApiException('自选保存目录不可用，请在设置中重新选择');
    }
    final result = await saveDownload(
      _api.fileUri(job.id),
      job.filename ?? 'langbai-output.bin',
      (progress) {
        if (mounted) setState(() => _saveProgress = progress);
      },
      headers: _api.downloadHeaders,
      isCancelled: () => _cancelRequested,
      destination: destination,
      customDestinationUri: widget.customSaveDestinationUri,
      mediaType: mediaTypeFromFilename(job.filename),
      onTransferProgress: (progress) {
        if (!mounted) return;
        job = DownloadJob(
          id: job.id,
          state: progress.progress >= 1 ? JobState.completed : JobState.running,
          progress: progress.progress,
          filename: job.filename,
          downloadedBytes: progress.downloadedBytes,
          totalBytes: progress.totalBytes,
          speedBytesPerSecond: progress.speedBytesPerSecond,
          averageSpeedBytesPerSecond: progress.averageSpeedBytesPerSecond,
          etaSeconds: progress.etaSeconds,
        );
        setState(() {
          _job = job;
          _saveProgress = progress.progress;
        });
        _notifyToolJob(job);
      },
    );
    if (!mounted) return;
    if (result.cancelled) {
      job = DownloadJob(
        id: job.id,
        state: JobState.cancelled,
        progress: _saveProgress,
        filename: job.filename,
        error: '已取消保存',
        downloadedBytes: job.downloadedBytes,
        totalBytes: job.totalBytes,
      );
      setState(() => _job = job);
      _notifyToolJob(job);
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(result.path ?? result.message)));
  }

  DownloadJob _serverJobBeforePublication(DownloadJob job) =>
      job.state == JobState.completed ? job.waitingForPublication() : job;

  Future<void> _cancelToolTask() async {
    if (!_busy || _cancelRequested || _localProbeRunning) return;
    setState(() => _cancelRequested = true);
    final jobId = _activeJobId;
    if (jobId == null) return;
    try {
      late final DownloadJob cancelled;
      if (_localConversionRunning) {
        await LocalMediaService.instance.cancelConversion(jobId);
        cancelled = DownloadJob(
          id: jobId,
          state: JobState.cancelled,
          progress: _job?.progress ?? 0,
          filename: _job?.filename,
          error: '用户已取消',
          downloadedBytes: _job?.downloadedBytes,
          totalBytes: _job?.totalBytes,
          speedBytesPerSecond: _job?.speedBytesPerSecond,
          averageSpeedBytesPerSecond: _job?.averageSpeedBytesPerSecond,
        );
      } else {
        cancelled = await _api.cancelJob(jobId);
      }
      if (mounted) setState(() => _job = cancelled);
      _notifyToolJob(cancelled);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '取消失败：$error');
    }
  }

  SaveDestination _toolSaveDestination(String? filename) {
    final destination = widget.defaultSaveDestination;
    if (destination != SaveDestination.gallery) return destination;
    final extension = _fileExtension(filename ?? '');
    if (_imageExtensions.contains(extension) ||
        _videoExtensions.contains(extension)) {
      return SaveDestination.gallery;
    }
    return SaveDestination.files;
  }

  bool _isImage(String name) {
    final extension = name.contains('.')
        ? name.split('.').last.toLowerCase()
        : '';
    return const {
      'jpg',
      'jpeg',
      'png',
      'webp',
      'avif',
      'gif',
    }.contains(extension);
  }
}

class _ToolDefinition {
  const _ToolDefinition(this.id, this.title, this.description, this.icon);

  final String id;
  final String title;
  final String description;
  final IconData icon;
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({
    required this.tool,
    required this.selected,
    required this.enabled,
    required this.availability,
    required this.onTap,
  });

  final _ToolDefinition tool;
  final bool selected;
  final bool enabled;
  final String availability;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return LangbaiCard(
      color: selected ? context.palette.navigationSelected : null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                tool.icon,
                color: enabled
                    ? Theme.of(context).colorScheme.primary
                    : context.palette.textMuted,
                size: 28,
              ),
              const SizedBox(height: 18),
              Text(
                tool.title,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: enabled ? null : context.palette.textMuted,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                tool.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 10),
              Semantics(
                label: availability,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: enabled
                        ? Theme.of(context).colorScheme.primaryContainer
                        : context.palette.surfaceRaised,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: context.palette.border),
                  ),
                  child: Text(
                    availability,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: enabled
                          ? Theme.of(context).colorScheme.primary
                          : context.palette.textMuted,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolAvailabilityNotice extends StatelessWidget {
  const _ToolAvailabilityNotice({
    required this.onRetry,
    required this.localConversion,
    required this.mobile,
  });

  final VoidCallback onRetry;
  final bool localConversion;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.palette.surfaceRaised,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: context.palette.border),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline_rounded),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                localConversion
                    ? mobile
                          ? '解析、公开媒体识别、音乐、音频提取、压缩、格式转换和媒体信息均按手机内置能力运行；磁力/种子引擎未内置。'
                          : '解析、音乐和格式转换可在本机使用；其余高级工具需要受信任服务。'
                    : '链接解析和多源音乐可直接使用；其余高级工具已停用，连接受信任服务后才会开放。',
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('重新检测')),
          ],
        ),
      ),
    );
  }
}

class _ToolWorkspace extends StatelessWidget {
  const _ToolWorkspace({
    required this.tool,
    required this.inputController,
    required this.selectedFile,
    required this.quality,
    required this.audioFormat,
    required this.audioFormats,
    required this.conversionFormat,
    required this.conversionFormats,
    required this.conversionQuality,
    required this.conversionQualityValues,
    required this.busy,
    required this.supportsFileDrop,
    required this.draggingFile,
    required this.onPickFile,
    required this.onDroppedFiles,
    required this.onDragStateChanged,
    required this.onQualityChanged,
    required this.onAudioFormatChanged,
    required this.onConversionFormatChanged,
    required this.onConversionQualityChanged,
    required this.onRun,
  });

  final _ToolDefinition tool;
  final TextEditingController inputController;
  final XFile? selectedFile;
  final double quality;
  final String audioFormat;
  final List<String> audioFormats;
  final String conversionFormat;
  final List<String> conversionFormats;
  final String conversionQuality;
  final List<String> conversionQualityValues;
  final bool busy;
  final bool supportsFileDrop;
  final bool draggingFile;
  final VoidCallback onPickFile;
  final ValueChanged<List<XFile>> onDroppedFiles;
  final ValueChanged<bool> onDragStateChanged;
  final ValueChanged<double> onQualityChanged;
  final ValueChanged<String> onAudioFormatChanged;
  final ValueChanged<String> onConversionFormatChanged;
  final ValueChanged<String> onConversionQualityChanged;
  final VoidCallback onRun;

  bool get _needsFile => const {
    'audio',
    'compress',
    'convert',
    'metadata',
    'transfer',
  }.contains(tool.id);
  bool get _needsInput => const {
    'parser',
    'sniff',
    'music',
    'direct',
    'transfer',
  }.contains(tool.id);

  Widget _buildFilePicker(BuildContext context) {
    final label = tool.id == 'transfer'
        ? '选择 .torrent 种子文件'
        : tool.id == 'convert' && supportsFileDrop
        ? '拖入文件，或点击选择'
        : '选择本地文件';
    final content = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      decoration: BoxDecoration(
        color: draggingFile
            ? Theme.of(context).colorScheme.primaryContainer
            : context.palette.surfaceRaised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: draggingFile
              ? Theme.of(context).colorScheme.primary
              : context.palette.border,
          width: draggingFile ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: busy ? null : onPickFile,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Column(
            children: [
              Icon(
                tool.id == 'convert'
                    ? Icons.file_upload_outlined
                    : Icons.file_open_outlined,
                size: 28,
              ),
              const SizedBox(height: 8),
              Text(label, textAlign: TextAlign.center),
              if (selectedFile != null) ...[
                const SizedBox(height: 6),
                Text(
                  selectedFile!.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: context.palette.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (!supportsFileDrop || tool.id != 'convert') return content;
    return DropTarget(
      onDragDone: (details) => onDroppedFiles(details.files),
      onDragEntered: (_) => onDragStateChanged(true),
      onDragExited: (_) => onDragStateChanged(false),
      child: content,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LangbaiCard(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(tool.icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Text(
                  tool.title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              tool.description,
              style: TextStyle(color: context.palette.textMuted),
            ),
            const SizedBox(height: 18),
            if (_needsInput)
              TextField(
                controller: inputController,
                minLines: tool.id == 'direct' ? 3 : 1,
                maxLines: tool.id == 'direct' ? 6 : 1,
                decoration: InputDecoration(
                  labelText: tool.id == 'music'
                      ? '歌曲、歌手或专辑'
                      : tool.id == 'direct'
                      ? '公开直链（每行一条；桌面最多 8 条）'
                      : '链接 / Magnet',
                  prefixIcon: Icon(
                    tool.id == 'music'
                        ? Icons.search_rounded
                        : Icons.link_rounded,
                  ),
                ),
              ),
            if (tool.id == 'direct') ...[
              const SizedBox(height: 8),
              Text(
                '手机本机一次处理一条；桌面服务的多条线路必须指向同一文件，并会校验后分段。',
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
            if (_needsFile) ...[_buildFilePicker(context)],
            if (tool.id == 'audio') ...[
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                // Keep compatibility with the Flutter version used by the
                // desktop toolchain. Newer SDKs call this initialValue.
                // ignore: deprecated_member_use
                value: audioFormat,
                decoration: const InputDecoration(labelText: '输出格式'),
                items: [
                  for (final format in audioFormats)
                    DropdownMenuItem(
                      value: format,
                      child: Text(_audioFormatLabel(format)),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (value) {
                        if (value != null) onAudioFormatChanged(value);
                      },
              ),
            ],
            if (tool.id == 'compress') ...[
              const SizedBox(height: 14),
              Text(
                '质量 ${quality.round()}%',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Slider(
                value: quality,
                min: 20,
                max: 95,
                divisions: 15,
                label: '${quality.round()}%',
                onChanged: busy ? null : onQualityChanged,
              ),
            ],
            if (tool.id == 'convert') ...[
              const SizedBox(height: 14),
              if (conversionFormats.isEmpty)
                Text(
                  '当前执行器没有报告可用的输入/输出格式。',
                  style: TextStyle(color: context.palette.textMuted),
                )
              else
                DropdownButtonFormField<String>(
                  // ignore: deprecated_member_use
                  value: conversionFormats.contains(conversionFormat)
                      ? conversionFormat
                      : conversionFormats.first,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '输出格式'),
                  items: [
                    for (final format in conversionFormats)
                      DropdownMenuItem(
                        value: format,
                        child: Text(format.toUpperCase()),
                      ),
                  ],
                  onChanged: busy
                      ? null
                      : (value) {
                          if (value != null) onConversionFormatChanged(value);
                        },
                ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                // ignore: deprecated_member_use
                value: conversionQualityValues.contains(conversionQuality)
                    ? conversionQuality
                    : conversionQualityValues.first,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '转换质量'),
                items: [
                  for (final quality in conversionQualityValues)
                    DropdownMenuItem(
                      value: quality,
                      child: Text(_conversionQualityLabel(quality)),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (value) {
                        if (value != null) onConversionQualityChanged(value);
                      },
              ),
              const SizedBox(height: 8),
              Text(
                '仅显示当前本机转换器或已连接服务明确报告支持的格式；DRM 文件不受支持。',
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
            if (tool.id == 'music') ...[
              const SizedBox(height: 10),
              Text(
                '聚合 Apple Music、MusicBrainz、Audius、Internet Archive、Wikimedia Commons 和可选 Jamendo；仅对来源明确授权的文件提供下载。',
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: busy ? null : onRun,
                icon: busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow_rounded),
                label: Text(busy ? '处理中…' : '开始任务'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolError extends StatelessWidget {
  const _ToolError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: '错误：$message',
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Theme.of(context).colorScheme.error),
        ),
        child: Row(
          children: [
            Icon(
              Icons.error_outline_rounded,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

class _ToolStatus extends StatelessWidget {
  const _ToolStatus({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.palette.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline_rounded),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

class _ToolProgress extends StatelessWidget {
  const _ToolProgress({
    required this.job,
    required this.saveProgress,
    this.onCancel,
  });

  final DownloadJob job;
  final double saveProgress;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final saving = job.state == JobState.completed && saveProgress < 1;
    final value = saving ? saveProgress : job.progress;
    final label = switch (job.state) {
      JobState.queued => '等待服务器处理',
      JobState.running => '正在处理',
      JobState.completed => saving ? '正在保存到设备' : '任务完成',
      JobState.failed => '任务失败',
      JobState.cancelled => '任务已取消',
    };
    final metrics = <String>[
      if (job.downloadedBytes != null)
        job.totalBytes == null
            ? _humanBytes(job.downloadedBytes!)
            : '${_humanBytes(job.downloadedBytes!)} / ${_humanBytes(job.totalBytes!)}',
      if ((job.speedBytesPerSecond ?? job.averageSpeedBytesPerSecond) != null)
        '${_humanBytes((job.speedBytesPerSecond ?? job.averageSpeedBytesPerSecond!).round())}/s',
      if (job.etaSeconds != null) '约 ${job.etaSeconds}s',
    ].join(' · ');
    return LangbaiCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  '${(value * 100).round()}%',
                  style: TextStyle(color: context.palette.textMuted),
                ),
              ],
            ),
            if (metrics.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                metrics,
                key: ValueKey('tool-progress-metrics-${job.id}'),
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: value <= 0 ? null : value,
              borderRadius: BorderRadius.circular(8),
            ),
            if (onCancel != null &&
                (job.state == JobState.queued || job.state == JobState.running))
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: onCancel, child: const Text('取消')),
              ),
          ],
        ),
      ),
    );
  }
}

class _ToolResults extends StatelessWidget {
  const _ToolResults({
    required this.musicResults,
    required this.musicFiles,
    required this.sniffedResources,
    required this.onOpenMusic,
    required this.onDownloadUrl,
  });

  final List<MusicSearchResult> musicResults;
  final List<MusicFile> musicFiles;
  final List<SniffedResource> sniffedResources;
  final ValueChanged<MusicSearchResult> onOpenMusic;
  final ValueChanged<String> onDownloadUrl;

  @override
  Widget build(BuildContext context) {
    return LangbaiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              musicFiles.isNotEmpty
                  ? '可用音频文件 · ${musicFiles.length} 个'
                  : musicResults.isNotEmpty
                  ? '多源音乐搜索结果 · ${musicResults.length} 条'
                  : '嗅探到的媒体资源',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          Divider(height: 1, color: context.palette.border),
          if (musicFiles.isNotEmpty)
            for (final file in musicFiles.take(24))
              _ResultRow(
                icon: Icons.audio_file_outlined,
                title: file.name,
                subtitle:
                    '${file.format}${file.size == null ? '' : ' · ${_humanBytes(file.size!)}'}',
                actionLabel: '下载',
                onTap: () => onDownloadUrl(file.downloadUrl),
              )
          else if (musicResults.isNotEmpty)
            for (final result in musicResults.take(60))
              _ResultRow(
                icon: Icons.album_outlined,
                title: result.title,
                subtitle:
                    [
                          result.sourceLabel,
                          result.creator,
                          result.year,
                          result.album,
                          result.license,
                        ]
                        .whereType<String>()
                        .where((value) => value.isNotEmpty)
                        .join(' · '),
                actionLabel: result.canDownload
                    ? '查看文件'
                    : result.previewUrl != null
                    ? '试听'
                    : '打开来源',
                onTap: () => onOpenMusic(result),
              )
          else
            for (final resource in sniffedResources.take(30))
              _ResultRow(
                icon: resource.kind == 'audio'
                    ? Icons.audio_file_outlined
                    : resource.kind == 'image'
                    ? Icons.image_outlined
                    : Icons.movie_outlined,
                title: resource.url,
                subtitle:
                    '${resource.kind} · ${resource.extension ?? '未知格式'} · ${resource.source}',
                actionLabel: '处理',
                onTap: () => onDownloadUrl(resource.url),
              ),
        ],
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.palette.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              TextButton(onPressed: onTap, child: Text(actionLabel)),
            ],
          ),
        ),
        Divider(height: 1, color: context.palette.border),
      ],
    );
  }
}

String _humanBytes(int bytes) {
  var value = bytes.toDouble();
  for (final unit in const ['B', 'KB', 'MB', 'GB']) {
    if (value < 1024 || unit == 'GB') {
      return '${value.toStringAsFixed(unit == 'B' ? 0 : 1)} $unit';
    }
    value /= 1024;
  }
  return '$bytes B';
}

String _conversionQualityLabel(String value) => switch (value) {
  'low' => '较小文件',
  'medium' => '均衡',
  'high' => '高质量',
  'original' => '保持原始质量（如格式支持）',
  _ => value,
};

String _audioFormatLabel(String value) => switch (value) {
  'mp3' => 'MP3 · 320 kbps',
  'm4a' => 'M4A · AAC',
  'flac' => 'FLAC · 不提升原始音质',
  'wav' => 'WAV · PCM',
  _ => value.toUpperCase(),
};

String _probeDuration(double seconds) {
  final total = seconds.round().clamp(0, 24 * 60 * 60);
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final remaining = total % 60;
  return hours > 0
      ? '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}'
      : '${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}';
}

String _normalizeExtension(String value) =>
    value.trim().toLowerCase().replaceFirst(RegExp(r'^\.'), '');

String _fileExtension(String filename) {
  final leaf = filename.split(RegExp(r'[\\/]')).last;
  final dot = leaf.lastIndexOf('.');
  return dot <= 0 || dot == leaf.length - 1
      ? ''
      : _normalizeExtension(leaf.substring(dot + 1));
}

const _imageExtensions = {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'avif',
  'gif',
  'bmp',
  'tiff',
  'heic',
};
const _videoExtensions = {
  'mp4',
  'mov',
  'mkv',
  'webm',
  'avi',
  'flv',
  'm4v',
  '3gp',
  'ts',
  'mts',
};
const _audioExtensions = {
  'mp3',
  'm4a',
  'aac',
  'flac',
  'wav',
  'ogg',
  'opus',
  'wma',
  'aiff',
};
const _audioOutputFormats = {'mp3', 'm4a', 'flac', 'wav'};
const _imageOutputFormats = {'jpg', 'jpeg', 'png', 'webp'};
const _audioMediaFormats = {'mp3', 'm4a', 'aac', 'flac', 'wav', 'ogg', 'opus'};
const _imageMediaFormats = {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'bmp',
  'heic',
  'heif',
};
const _videoMediaFormats = {'mp4', 'm4v', 'mov', 'mkv', 'webm'};
