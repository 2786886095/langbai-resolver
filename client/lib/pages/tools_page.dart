import 'dart:async';

import 'package:file_selector/file_selector.dart';
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
  const ToolsPage({super.key, this.initialInput, required this.onOpenParser});

  final String? initialInput;
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
  List<MusicSearchResult> _musicResults = const [];
  List<MusicFile> _musicFiles = const [];
  List<SniffedResource> _sniffedResources = const [];
  bool? _remoteToolsHealthy;
  LocalMediaCapabilities? _localCapabilities;

  bool get _usesDirectMusic => LocalMediaService.isSupported;

  static const _tools = [
    _ToolDefinition(
      'parser',
      '视频与图片解析',
      '解析网页媒体、分辨率、音频和封面',
      Icons.play_circle_outline_rounded,
    ),
    _ToolDefinition(
      'sniff',
      '网页嗅探',
      '识别页面中的媒体与播放列表请求',
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
      'music',
      '多源音乐搜索',
      '聚合开放下载、试听与全球曲库元数据',
      Icons.headphones_rounded,
    ),
    _ToolDefinition('direct', '多线路直链下载', '校验镜像一致性后并发分段下载', Icons.link_rounded),
    _ToolDefinition(
      'transfer',
      '磁力与种子',
      'BT / Magnet 任务与文件选择',
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
    final remote = await _api.isHealthy();
    if (!mounted) return;
    setState(() {
      _localCapabilities = local;
      _remoteToolsHealthy = remote;
    });
  }

  bool _toolAvailable(String id) {
    if (id == 'parser' || id == 'music') return true;
    if (_remoteToolsHealthy == true) return true;
    return _localCapabilities?.tools[id] == true;
  }

  String _toolAvailabilityLabel(String id) {
    if (id == 'parser' || id == 'music') {
      return LocalMediaService.isSupported ? '本机可用' : '可用';
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${tool.title}需要连接受信任的高级工具服务，请先在设置中配置。'),
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
    setState(() => _selectedFile = file);
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
                  _ToolAvailabilityNotice(onRetry: _refreshCapabilities),
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
                    busy: _busy,
                    onPickFile: _pickFile,
                    onQualityChanged: (value) =>
                        setState(() => _quality = value),
                    onAudioFormatChanged: (value) =>
                        setState(() => _audioFormat = value),
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
                      onCancel: _busy ? _cancelToolTask : null,
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
      setState(() => _error = '当前平台未连接可执行该工具的服务');
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
    setState(() {
      _busy = true;
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
      if (mounted) setState(() => _error = error.message);
    } on TimeoutException {
      if (mounted) setState(() => _error = '任务请求超时，请稍后重试');
    } on Object catch (error) {
      if (mounted) setState(() => _error = '任务失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
    if (mounted) setState(() => _job = job);
    while (job.state == JobState.queued || job.state == JobState.running) {
      if (_cancelRequested) throw const ApiException('任务已取消');
      if (DateTime.now().isAfter(taskDeadline)) {
        await _api.cancelJob(job.id);
        throw TimeoutException('任务超过 2 小时，已自动取消');
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
      job = await _api.getJob(job.id);
      if (!mounted) return;
      setState(() => _job = job);
    }
    if (job.state == JobState.failed) {
      throw ApiException(job.error ?? '服务器处理失败');
    }
    if (job.state == JobState.cancelled) {
      throw const ApiException('任务已取消');
    }
    final result = await saveDownload(
      _api.fileUri(job.id),
      job.filename ?? 'langbai-output.bin',
      (progress) {
        if (mounted) setState(() => _saveProgress = progress);
      },
      headers: _api.downloadHeaders,
      isCancelled: () => _cancelRequested,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(result.path ?? result.message)));
  }

  Future<void> _cancelToolTask() async {
    if (!_busy || _cancelRequested) return;
    setState(() => _cancelRequested = true);
    final jobId = _activeJobId;
    if (jobId == null) return;
    try {
      final cancelled = await _api.cancelJob(jobId);
      if (mounted) setState(() => _job = cancelled);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '取消失败：$error');
    }
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
  const _ToolAvailabilityNotice({required this.onRetry});

  final VoidCallback onRetry;

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
            const Expanded(
              child: Text('链接解析和多源音乐可直接使用；其余高级工具已停用，连接受信任服务后才会开放。'),
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
    required this.busy,
    required this.onPickFile,
    required this.onQualityChanged,
    required this.onAudioFormatChanged,
    required this.onRun,
  });

  final _ToolDefinition tool;
  final TextEditingController inputController;
  final XFile? selectedFile;
  final double quality;
  final String audioFormat;
  final bool busy;
  final VoidCallback onPickFile;
  final ValueChanged<double> onQualityChanged;
  final ValueChanged<String> onAudioFormatChanged;
  final VoidCallback onRun;

  bool get _needsFile =>
      const {'audio', 'compress', 'metadata', 'transfer'}.contains(tool.id);
  bool get _needsInput => const {
    'parser',
    'sniff',
    'music',
    'direct',
    'transfer',
  }.contains(tool.id);

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
                      ? '镜像直链（每行一条，最多 8 条）'
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
                '多条线路必须指向同一文件；系统会测速并将分段分配到可用线路。',
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
            if (_needsFile) ...[
              OutlinedButton.icon(
                onPressed: busy ? null : onPickFile,
                icon: const Icon(Icons.file_open_outlined),
                label: Text(
                  tool.id == 'transfer' ? '选择 .torrent 种子文件' : '选择本地文件',
                ),
              ),
              if (selectedFile != null) ...[
                const SizedBox(height: 8),
                Text(
                  selectedFile!.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.palette.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
            if (tool.id == 'audio') ...[
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                // Keep compatibility with the Flutter version used by the
                // desktop toolchain. Newer SDKs call this initialValue.
                // ignore: deprecated_member_use
                value: audioFormat,
                decoration: const InputDecoration(labelText: '输出格式'),
                items: const [
                  DropdownMenuItem(value: 'mp3', child: Text('MP3 · 320 kbps')),
                  DropdownMenuItem(value: 'm4a', child: Text('M4A · 256 kbps')),
                  DropdownMenuItem(
                    value: 'flac',
                    child: Text('FLAC · 不提升原始音质'),
                  ),
                  DropdownMenuItem(value: 'wav', child: Text('WAV · PCM')),
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
                if (onCancel != null &&
                    (job.state == JobState.queued ||
                        job.state == JobState.running)) ...[
                  const SizedBox(width: 8),
                  TextButton(onPressed: onCancel, child: const Text('取消')),
                ],
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: value <= 0 ? null : value,
              borderRadius: BorderRadius.circular(8),
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
