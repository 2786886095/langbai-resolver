import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  final AudioPlayer _musicPlayer = AudioPlayer();
  StreamSubscription<PlayerState>? _musicStateSubscription;
  StreamSubscription<Duration>? _musicPositionSubscription;
  StreamSubscription<Duration>? _musicDurationSubscription;
  MusicSearchResult? _activeMusic;
  PlayerState _musicPlayerState = PlayerState.stopped;
  Duration _musicPosition = Duration.zero;
  Duration _musicDuration = Duration.zero;
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
      '先选择源文件，再按实际能力选择格式并导出',
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
    _musicStateSubscription = _musicPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _musicPlayerState = state);
    });
    _musicPositionSubscription = _musicPlayer.onPositionChanged.listen(
      (position) {
        if (mounted) setState(() => _musicPosition = position);
      },
    );
    _musicDurationSubscription = _musicPlayer.onDurationChanged.listen(
      (duration) {
        if (mounted) setState(() => _musicDuration = duration);
      },
    );
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
    final remote =
        LocalMediaService.isSupported ? false : await _api.isHealthy();
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
      if (tool != 'music') _musicResults = const [];
      _sniffedResources = const [];
    }

    if (notify && mounted) {
      setState(apply);
    } else {
      apply();
    }
  }

  void _leaveTool() {
    final current = _selectedTool;
    if (current == null) return;
    _toolInputs[current] = _inputController.text;
    setState(() {
      _selectedTool = null;
      _draggingFile = false;
    });
  }

  @override
  void dispose() {
    unawaited(_musicStateSubscription?.cancel());
    unawaited(_musicPositionSubscription?.cancel());
    unawaited(_musicDurationSubscription?.cancel());
    unawaited(_musicPlayer.dispose());
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
    final file = selected ?? _selectedFile;
    // The output step is intentionally hidden until an input has been chosen.
    if (file == null) return const <String>[];
    if (_localConversionAvailable) {
      final outputs = _localCapabilities!.conversion.outputFormats
          .map(_normalizeExtension)
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList(growable: false);
      final extension = _fileExtension(file.name);
      if (_imageExtensions.contains(extension)) {
        return outputs
            .where(
              (format) =>
                  _imageMediaFormats.contains(format) ||
                  (extension == 'gif' && _videoMediaFormats.contains(format)),
            )
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
                  _audioMediaFormats.contains(format) ||
                  _imageMediaFormats.contains(format),
            )
            .toList(growable: false);
      }
      return const <String>[];
    }
    if (_remoteToolsHealthy != true) return const <String>[];
    final extension = _fileExtension(file.name);
    if (_imageExtensions.contains(extension)) {
      return const ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'tiff'];
    }
    if (_audioExtensions.contains(extension)) {
      return const [
        'mp3',
        'm4a',
        'aac',
        'flac',
        'wav',
        'ogg',
        'opus',
        'ac3',
        'aiff',
      ];
    }
    if (_videoExtensions.contains(extension)) {
      return const [
        'mp4',
        'mkv',
        'webm',
        'avi',
        'mov',
        'ts',
        'mp3',
        'm4a',
        'aac',
        'flac',
        'wav',
        'ogg',
        'opus',
        'ac3',
        'aiff',
        'jpg',
        'png',
        'webp',
        'gif',
        'bmp',
        'tiff',
      ];
    }
    if (_documentExtensions.contains(extension)) {
      return _documentFormats
          .where((format) => format != extension)
          .toList(growable: false);
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
    return const [
      'mp3',
      'm4a',
      'aac',
      'flac',
      'wav',
      'ogg',
      'opus',
      'ac3',
      'aiff',
    ];
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _selectedTool == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leaveTool();
      },
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(26, 28, 26, 42),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_selectedTool == null) ...[
                    Text(
                      '工具箱',
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
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
                            (constraints.maxWidth - (columns - 1) * 12) /
                                columns;
                        final textScale =
                            MediaQuery.textScalerOf(context).scale(12) / 12;
                        final cardHeight =
                            172.0 + (textScale > 1 ? (textScale - 1) * 72 : 0);
                        return Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            for (final tool in _tools)
                              SizedBox(
                                width: width,
                                height: cardHeight,
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
                  ] else ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _leaveTool,
                        icon: const Icon(Icons.arrow_back_rounded),
                        label: const Text('返回工具箱'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _ToolWorkspace(
                      tool:
                          _tools.firstWhere((item) => item.id == _selectedTool),
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
                        _sniffedResources.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _ToolResults(
                        musicResults: _musicResults,
                        sniffedResources: _sniffedResources,
                        activeMusic: _activeMusic,
                        playerState: _musicPlayerState,
                        position: _musicPosition,
                        duration: _musicDuration,
                        onPlayMusic: _playMusicResult,
                        onSeekMusic: (position) => _musicPlayer.seek(position),
                        onDownloadMusic: _downloadMusicResult,
                        onDownloadUrl: widget.onOpenParser,
                      ),
                    ],
                  ],
                ],
              ),
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
            final warnings =
                _usesDirectMusic ? _openMusic.lastWarnings : const <String>[];
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
        final outputFormat =
            tool == 'audio' ? _audioFormat : _preferredCompressionFormat(file);
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
    final streamSummary = result.streams.map((stream) {
      final details = <String>[
        stream.type,
        if (stream.codec != null) stream.codec!,
        if (stream.width != null && stream.height != null)
          '${stream.width}×${stream.height}',
        if (stream.sampleRate != null) '${stream.sampleRate} Hz',
        if (stream.channels != null) '${stream.channels} 声道',
      ];
      return details.join(' · ');
    }).join('\n');
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
    if (_documentFormats.contains(outputFormat)) return SaveDestination.files;
    if (destination != SaveDestination.gallery) return destination;
    if (_audioMediaFormats.contains(outputFormat)) {
      return SaveDestination.files;
    }
    return SaveDestination.gallery;
  }

  String _remoteConversionOperation(XFile file, String outputFormat) {
    final input = _fileExtension(file.name);
    if (_documentExtensions.contains(input) &&
        _documentFormats.contains(outputFormat)) {
      return 'convert_document';
    }
    if ((_imageExtensions.contains(input) ||
            _audioExtensions.contains(input) ||
            _videoExtensions.contains(input)) &&
        (_imageMediaFormats.contains(outputFormat) ||
            _audioMediaFormats.contains(outputFormat) ||
            _videoMediaFormats.contains(outputFormat))) {
      return 'convert_media';
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

  Future<List<MusicFile>> _loadMusicFiles(MusicSearchResult result) async {
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
          if (files.isEmpty) {
            _statusMessage = '该来源没有提供经过授权的直接下载文件';
          }
        });
      }
      return files;
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
    return const [];
  }

  Future<void> _playMusicResult(MusicSearchResult result) async {
    final target = result.previewUrl;
    if (target == null || target.isEmpty) {
      if (mounted) setState(() => _error = '该来源没有提供可播放的试听音频');
      return;
    }
    try {
      if (_activeMusic?.identifier == result.identifier) {
        if (_musicPlayerState == PlayerState.playing) {
          await _musicPlayer.pause();
        } else {
          if (_musicPlayerState == PlayerState.completed) {
            await _musicPlayer.seek(Duration.zero);
          }
          await _musicPlayer.resume();
        }
        return;
      }
      await _musicPlayer.stop();
      if (mounted) {
        setState(() {
          _activeMusic = result;
          _musicPosition = Duration.zero;
          _musicDuration = Duration.zero;
          _error = null;
        });
      }
      await _musicPlayer.play(UrlSource(target));
    } on Object {
      if (mounted) {
        setState(() {
          _musicPlayerState = PlayerState.stopped;
          _error = '无法在软件内播放 ${result.sourceLabel} 音频';
        });
      }
    }
  }

  Future<void> _downloadMusicResult(MusicSearchResult result) async {
    if (_busy) return;
    final files = await _loadMusicFiles(result);
    if (!mounted || files.isEmpty) return;
    final choices = [...files]
      ..sort((a, b) => _musicFileScore(b).compareTo(_musicFileScore(a)));
    final selected = await showModalBottomSheet<MusicFile>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.76,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '选择下载音质',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${result.title}${result.creator == null ? '' : ' · ${result.creator}'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: sheetContext.palette.textMuted),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '保存到：$_musicSaveDestinationLabel',
                      style: TextStyle(
                        color: sheetContext.palette.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: sheetContext.palette.border),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: choices.length,
                  separatorBuilder: (context, index) =>
                      Divider(height: 1, color: sheetContext.palette.border),
                  itemBuilder: (context, index) {
                    final file = choices[index];
                    return ListTile(
                      leading: const Icon(Icons.audio_file_rounded),
                      title: Text(_musicFileQuality(file)),
                      subtitle: Text(
                        '${file.format}${file.size == null ? '' : ' · ${_humanBytes(file.size!)}'}\n${file.name}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.download_rounded),
                      onTap: () => Navigator.pop(context, file),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) await _saveMusicFile(result, selected);
  }

  String get _musicSaveDestinationLabel {
    if (widget.defaultSaveDestination == SaveDestination.custom) {
      return '设置中的自选目录';
    }
    if (kIsWeb) return '浏览器下载目录';
    if (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux) {
      return '下载时选择保存路径';
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return '“文件”App / langbai解析';
    }
    return 'Download / langbai解析';
  }

  Future<void> _saveMusicFile(
    MusicSearchResult result,
    MusicFile file,
  ) async {
    final uri = Uri.tryParse(file.downloadUrl);
    if (uri == null || !const {'http', 'https'}.contains(uri.scheme)) {
      setState(() => _error = '音乐下载地址无效');
      return;
    }
    final destination = widget.defaultSaveDestination == SaveDestination.gallery
        ? SaveDestination.files
        : widget.defaultSaveDestination;
    if (destination == SaveDestination.custom &&
        widget.customSaveDestinationUri?.trim().isNotEmpty != true) {
      setState(() => _error = '自选保存目录不可用，请先在设置中重新选择');
      return;
    }
    final filename = _musicFilename(result, file);
    var job = DownloadJob(
      id: 'music-${DateTime.now().microsecondsSinceEpoch}',
      state: JobState.running,
      progress: 0,
      filename: filename,
    );
    setState(() {
      _busy = true;
      _cancelRequested = false;
      _error = null;
      _statusMessage = '正在下载 ${result.title}';
      _saveProgress = 0;
      _job = job;
    });
    _notifyToolJob(job);
    try {
      final saved = await saveDownload(
        uri,
        filename,
        (progress) {
          if (!mounted) return;
          setState(() => _saveProgress = progress);
        },
        destination: destination,
        mediaType: 'audio',
        customDestinationUri: widget.customSaveDestinationUri,
        isCancelled: () => _cancelRequested,
        followRedirects: true,
        onTransferProgress: (progress) {
          if (!mounted) return;
          job = DownloadJob(
            id: job.id,
            state:
                progress.progress >= 1 ? JobState.completed : JobState.running,
            progress: progress.progress,
            filename: filename,
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
      job = DownloadJob(
        id: job.id,
        state: saved.cancelled ? JobState.cancelled : JobState.completed,
        progress: saved.cancelled ? _saveProgress : 1,
        filename: filename,
        downloadedBytes: job.downloadedBytes,
        totalBytes: job.totalBytes,
        speedBytesPerSecond: job.speedBytesPerSecond,
        averageSpeedBytesPerSecond: job.averageSpeedBytesPerSecond,
      );
      setState(() {
        _job = job;
        _saveProgress = job.progress;
        _statusMessage = saved.message;
      });
      _notifyToolJob(job);
    } on Object catch (error) {
      if (!mounted) return;
      job = DownloadJob(
        id: job.id,
        state: _cancelRequested ? JobState.cancelled : JobState.failed,
        progress: _saveProgress,
        filename: filename,
        error: _cancelRequested ? '下载已取消' : error.toString(),
      );
      setState(() {
        _job = job;
        _error = _cancelRequested ? '下载已取消' : '音乐下载失败：$error';
      });
      _notifyToolJob(job);
    } finally {
      if (mounted) setState(() => _busy = false);
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
    final extension =
        name.contains('.') ? name.split('.').last.toLowerCase() : '';
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
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
              const Spacer(),
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
            ? '第 1 步 · 拖入文件，或点击选择'
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
              if (selectedFile == null)
                Text(
                  '第 1 步：先选择需要转换的文件，系统会根据文件类型列出可用格式。',
                  style: TextStyle(color: context.palette.textMuted),
                ),
              if (selectedFile != null && conversionFormats.isEmpty)
                Text(
                  '当前执行器不支持 ${_fileExtension(selectedFile!.name).toUpperCase()} 文件，请更换文件或连接支持该格式的服务。',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (selectedFile != null && conversionFormats.isNotEmpty) ...[
                DropdownButtonFormField<String>(
                  // ignore: deprecated_member_use
                  value: conversionFormats.contains(conversionFormat)
                      ? conversionFormat
                      : conversionFormats.first,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '第 2 步 · 选择输出格式',
                  ),
                  items: [
                    for (final format in conversionFormats)
                      DropdownMenuItem(
                        value: format,
                        child: Text(
                          '${_conversionFormatCategory(format)} · ${format.toUpperCase()}',
                        ),
                      ),
                  ],
                  onChanged: busy
                      ? null
                      : (value) {
                          if (value != null) onConversionFormatChanged(value);
                        },
                ),
                const SizedBox(height: 7),
                Text(
                  '已根据 ${_fileExtension(selectedFile!.name).toUpperCase()} 文件筛选 ${conversionFormats.length} 种可用格式',
                  style: TextStyle(
                    color: context.palette.textMuted,
                    fontSize: 12,
                  ),
                ),
                if (!_documentExtensions.contains(
                  _fileExtension(selectedFile!.name),
                )) ...[
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
                            if (value != null) {
                              onConversionQualityChanged(value);
                            }
                          },
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  '仅显示当前设备或已连接服务实际支持的格式；加密或 DRM 文件不受支持。',
                  style: TextStyle(
                    color: context.palette.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
            if (tool.id == 'music') ...[
              const SizedBox(height: 10),
              Text(
                '聚合 Openverse、Apple Music、Audius、Internet Archive、Wikimedia Commons 和可选 Jamendo；仅显示可播放或明确授权下载的结果。',
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
                onPressed: busy ||
                        (tool.id == 'convert' &&
                            (selectedFile == null || conversionFormats.isEmpty))
                    ? null
                    : onRun,
                icon: busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow_rounded),
                label: Text(
                  busy
                      ? '处理中…'
                      : tool.id == 'convert'
                          ? '第 3 步 · 转换并导出'
                          : '开始任务',
                ),
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
    required this.sniffedResources,
    required this.activeMusic,
    required this.playerState,
    required this.position,
    required this.duration,
    required this.onPlayMusic,
    required this.onSeekMusic,
    required this.onDownloadMusic,
    required this.onDownloadUrl,
  });

  final List<MusicSearchResult> musicResults;
  final List<SniffedResource> sniffedResources;
  final MusicSearchResult? activeMusic;
  final PlayerState playerState;
  final Duration position;
  final Duration duration;
  final ValueChanged<MusicSearchResult> onPlayMusic;
  final ValueChanged<Duration> onSeekMusic;
  final ValueChanged<MusicSearchResult> onDownloadMusic;
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
              musicResults.isNotEmpty
                  ? '可播放与下载结果 · ${musicResults.length} 首'
                  : '嗅探到的媒体资源',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          Divider(height: 1, color: context.palette.border),
          if (musicResults.isNotEmpty && activeMusic != null) ...[
            _MusicNowPlaying(
              result: activeMusic!,
              isPlaying: playerState == PlayerState.playing,
              position: position,
              duration: duration,
              onToggle: () => onPlayMusic(activeMusic!),
              onSeek: onSeekMusic,
            ),
            Divider(height: 1, color: context.palette.border),
          ],
          if (musicResults.isNotEmpty)
            for (final result in musicResults.take(60))
              _MusicResultRow(
                result: result,
                isActive: activeMusic?.identifier == result.identifier,
                isPlaying: activeMusic?.identifier == result.identifier &&
                    playerState == PlayerState.playing,
                onPlay: () => onPlayMusic(result),
                onDownload: () => onDownloadMusic(result),
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

class _MusicNowPlaying extends StatelessWidget {
  const _MusicNowPlaying({
    required this.result,
    required this.isPlaying,
    required this.position,
    required this.duration,
    required this.onToggle,
    required this.onSeek,
  });

  final MusicSearchResult result;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final VoidCallback onToggle;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    final total = duration.inMilliseconds;
    final current = position.inMilliseconds.clamp(0, total > 0 ? total : 1);
    return Container(
      color: context.palette.surfaceRaised,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton.filled(
                tooltip: isPlaying ? '暂停' : '继续播放',
                onPressed: onToggle,
                icon: Icon(
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isPlaying ? '正在软件内播放' : '已暂停',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      result.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    if (result.creator?.isNotEmpty == true)
                      Text(
                        result.creator!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.palette.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          Row(
            children: [
              Text(_clockDuration(position),
                  style: const TextStyle(fontSize: 11)),
              Expanded(
                child: Slider(
                  value: current.toDouble(),
                  max: (total > 0 ? total : 1).toDouble(),
                  onChanged: total > 0
                      ? (value) => onSeek(Duration(milliseconds: value.round()))
                      : null,
                ),
              ),
              Text(_clockDuration(duration),
                  style: const TextStyle(fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }
}

class _MusicResultRow extends StatelessWidget {
  const _MusicResultRow({
    required this.result,
    required this.isActive,
    required this.isPlaying,
    required this.onPlay,
    required this.onDownload,
  });

  final MusicSearchResult result;
  final bool isActive;
  final bool isPlaying;
  final VoidCallback onPlay;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final previewAvailable = result.previewUrl?.isNotEmpty == true;
    final subtitle = [
      result.creator,
      result.album,
      result.year,
      result.sourceLabel,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
    final info = Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: result.artworkUrl?.isNotEmpty == true
              ? Image.network(
                  result.artworkUrl!,
                  width: 44,
                  height: 44,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => const SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(Icons.album_outlined),
                  ),
                )
              : const SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(Icons.album_outlined),
                ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                result.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
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
      ],
    );
    final actions = Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.end,
      children: [
        if (previewAvailable)
          TextButton.icon(
            onPressed: onPlay,
            icon: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
            label: Text(isPlaying
                ? '暂停'
                : isActive
                    ? '继续'
                    : '播放'),
          ),
        if (result.canDownload)
          FilledButton.tonalIcon(
            onPressed: onDownload,
            icon: const Icon(Icons.download_rounded),
            label: const Text('下载'),
          ),
      ],
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 520) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    info,
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: actions),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: info),
                  const SizedBox(width: 12),
                  actions,
                ],
              );
            },
          ),
        ),
        Divider(height: 1, color: context.palette.border),
      ],
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

String _clockDuration(Duration value) {
  final total = value.inSeconds.clamp(0, 24 * 60 * 60);
  final minutes = total ~/ 60;
  final seconds = total % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String _musicFilename(MusicSearchResult result, MusicFile file) {
  final fileExtension = _fileExtension(file.name);
  final formatExtension = _normalizeExtension(file.format).split(' ').first;
  final extension = _audioMediaFormats.contains(fileExtension)
      ? fileExtension
      : _audioMediaFormats.contains(formatExtension)
          ? formatExtension
          : 'mp3';
  final creator = result.creator?.trim();
  final raw = creator == null || creator.isEmpty
      ? result.title
      : '${result.title} - $creator';
  final safe = raw
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return '${safe.isEmpty ? 'langbai-music' : safe}.$extension';
}

int _musicFileScore(MusicFile file) {
  final format = file.format.toLowerCase();
  final lossless =
      const {'flac', 'wav', 'wave', 'aiff', 'alac'}.contains(format);
  final bitrate = file.bitrate ?? 0;
  final normalizedBitrate = bitrate > 10000 ? bitrate ~/ 1000 : bitrate;
  return (lossless ? 1000000 : 0) +
      normalizedBitrate * 1000 +
      (file.sampleRate ?? 0);
}

String _musicFileQuality(MusicFile file) {
  final format = file.format.toUpperCase();
  final lossless =
      const {'FLAC', 'WAV', 'WAVE', 'AIFF', 'ALAC'}.contains(format);
  final parts = <String>[if (lossless) '无损', format];
  if (file.bitrate != null && file.bitrate! > 0) {
    final kbps = file.bitrate! > 10000 ? file.bitrate! ~/ 1000 : file.bitrate!;
    parts.add('$kbps kbps');
  }
  if (file.sampleRate != null && file.sampleRate! > 0) {
    final rate = file.sampleRate! >= 1000
        ? '${(file.sampleRate! / 1000).toStringAsFixed(file.sampleRate! % 1000 == 0 ? 0 : 1)} kHz'
        : '${file.sampleRate} Hz';
    parts.add(rate);
  }
  return parts.join(' · ');
}

String _conversionQualityLabel(String value) => switch (value) {
      'low' => '较小文件',
      'medium' => '均衡',
      'high' => '高质量',
      'original' => '保持原始质量（如格式支持）',
      _ => value,
    };

String _conversionFormatCategory(String value) {
  if (_videoMediaFormats.contains(value)) return '视频';
  if (_audioMediaFormats.contains(value)) return '音频';
  if (_imageMediaFormats.contains(value)) return '图片';
  if (_documentFormats.contains(value)) return '文档';
  return '文件';
}

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
  'tif',
  'tga',
  'heic',
  'heif',
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
  'm2ts',
  'wmv',
  'mpeg',
  'mpg',
  'vob',
  'ogv',
  'asf',
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
  'aif',
  'amr',
  'ac3',
  'eac3',
  'dts',
  'ape',
  'alac',
};
const _documentExtensions = {
  'txt',
  'md',
  'markdown',
  'html',
  'htm',
  'rtf',
  'csv',
  'json',
  'xml',
  'docx',
  'odt',
};
const _documentFormats = [
  'txt',
  'md',
  'html',
  'rtf',
  'docx',
  'odt',
  'csv',
  'json',
  'xml',
];
const _audioMediaFormats = {
  'mp3',
  'm4a',
  'aac',
  'flac',
  'wav',
  'ogg',
  'opus',
  'ac3',
  'aiff',
  'aif',
};
const _imageMediaFormats = {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'bmp',
  'gif',
  'tiff',
  'tif',
  'heic',
  'heif',
};
const _videoMediaFormats = {'mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi', 'ts'};
