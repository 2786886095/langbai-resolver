import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/download_record.dart';
import '../models/media_models.dart';
import '../pages/dashboard_page.dart';
import '../pages/downloads_page.dart';
import '../pages/parser_page.dart';
import '../pages/tools_page.dart';
import '../services/api_client.dart';
import '../services/api_endpoint_policy.dart';
import '../services/link_detector.dart';
import '../services/local_media_service.dart';
import '../services/service_credential_store.dart';
import '../services/update_installer.dart';
import '../services/update_models.dart';
import '../services/update_service.dart';
import '../theme/langbai_theme.dart';

const _demoClipboardLink = String.fromEnvironment('DEMO_LINK');
const _defaultShellApiUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8787',
);

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final _linkDetector = LinkDetector();
  final Map<String, DownloadRecord> _downloads = {};
  int _selectedIndex = 0;
  int _parserRevision = 0;
  String? _parserInitialUrl;
  String? _toolInitialInput;
  String? _lastClipboardValue;
  bool _clipboardDetectionEnabled = false;
  bool _automaticUpdateChecksEnabled = true;
  bool _checkingForUpdate = false;
  DateTime? _lastAutomaticUpdateCheck;
  DateTime? _lastUpdateAttempt;
  String? _downloadDirectory;
  String _apiBaseUrl = _defaultShellApiUrl;
  String _serviceAccessToken = '';
  int _serviceConfigRevision = 0;
  bool? _serviceHealthy;
  Timer? _healthTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restorePreferences();
    unawaited(_checkServiceHealth());
    _healthTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_checkServiceHealth()),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _healthTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _clipboardDetectionEnabled) {
      unawaited(_checkClipboard());
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(_maybeCheckForUpdatesOnResume());
    }
  }

  Future<void> _restorePreferences() async {
    final preferences = await SharedPreferences.getInstance();
    final restoredApiUrl =
        normalizeTrustedApiUrl(preferences.getString('api_base_url')) ??
        _defaultShellApiUrl;
    final restoredAccessToken = await ServiceCredentialStore.readTokenFor(
      restoredApiUrl,
    );
    final restoredDownloads = <String, DownloadRecord>{};
    final history = preferences.getString('download_history');
    if (history != null && history.isNotEmpty) {
      try {
        final items = jsonDecode(history) as List<dynamic>;
        for (final raw in items.whereType<Map>()) {
          var record = DownloadRecord.fromJson(raw.cast<String, dynamic>());
          if (record.job.state == JobState.queued ||
              record.job.state == JobState.running) {
            record = record.copyWith(
              job: DownloadJob(
                id: record.job.id,
                state: JobState.failed,
                progress: record.job.progress,
                filename: record.job.filename,
                error: '应用上次退出时任务中断，请重新解析',
              ),
            );
          }
          restoredDownloads[record.job.id] = record;
        }
      } on Object {
        await preferences.remove('download_history');
      }
    }
    if (!mounted) return;
    setState(() {
      _automaticUpdateChecksEnabled =
          preferences.getBool('automatic_update_checks_enabled') ?? true;
      final lastUpdateCheck = preferences.getInt('last_app_update_check_at');
      _lastAutomaticUpdateCheck = lastUpdateCheck == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastUpdateCheck);
      _downloadDirectory = preferences.getString('download_directory');
      _apiBaseUrl = restoredApiUrl;
      _serviceAccessToken = restoredAccessToken;
      _clipboardDetectionEnabled =
          preferences.getBool('clipboard_detection_enabled') ?? false;
      _downloads
        ..clear()
        ..addAll(restoredDownloads);
    });
    if (_demoClipboardLink.isNotEmpty) {
      final detected = _linkDetector.detect(_demoClipboardLink);
      if (detected != null && mounted) {
        _lastClipboardValue = detected.value;
        _parseDetected(detected);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_demoClipboardLink.isEmpty && _clipboardDetectionEnabled) {
        unawaited(_checkClipboard());
      }
      if (_automaticUpdateChecksEnabled) {
        _checkForUpdates(automatic: true);
      }
    });
    if (LocalMediaService.isSupported) {
      unawaited(_refreshLocalParser(preferences));
    }
    unawaited(_checkServiceHealth());
  }

  Future<void> _refreshLocalParser(SharedPreferences preferences) async {
    const interval = Duration(hours: 24);
    final lastValue = preferences.getInt('local_parser_updated_at');
    final last = lastValue == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(lastValue);
    if (last != null && DateTime.now().difference(last) < interval) return;
    try {
      final capabilities = await LocalMediaService.instance.capabilities();
      if (!capabilities.engineUpdate) return;
      await LocalMediaService.instance.updateEngine();
      await preferences.setInt(
        'local_parser_updated_at',
        DateTime.now().millisecondsSinceEpoch,
      );
    } on Object {
      // The bundled extractor remains available when an update check fails.
    }
  }

  Future<void> _checkClipboard() async {
    try {
      final detected = await _linkDetector.readClipboard();
      if (!mounted || detected == null) return;
      if (detected.value == _lastClipboardValue) return;
      _lastClipboardValue = detected.value;
      _offerDetectedLink(detected);
    } on Object {
      // Clipboard access may be denied by the platform; manual paste remains available.
    }
  }

  void _offerDetectedLink(DetectedLink link) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 10),
          content: Text(
            link.kind == DetectedLinkKind.magnet
                ? '剪贴板中识别到 Magnet，是否打开下载工具？'
                : '剪贴板中识别到公开链接，是否开始处理？',
          ),
          action: SnackBarAction(
            label: '处理',
            onPressed: () => _parseDetected(link),
          ),
        ),
      );
  }

  Future<void> _checkServiceHealth() async {
    if (LocalMediaService.isSupported) {
      bool healthy;
      try {
        final capabilities = await LocalMediaService.instance.capabilities();
        healthy = capabilities.localResolver;
      } on Object {
        healthy = false;
      }
      if (mounted && _serviceHealthy != healthy) {
        setState(() => _serviceHealthy = healthy);
      }
      return;
    }
    final preferences = await SharedPreferences.getInstance();
    final baseUrl =
        preferences.getString('api_base_url')?.trim() ?? _defaultShellApiUrl;
    final token = await ServiceCredentialStore.readTokenFor(baseUrl);
    final api = ApiClient(baseUrl, instanceToken: token.isEmpty ? null : token);
    final healthy = await api.isHealthy();
    api.close();
    if (mounted && healthy != _serviceHealthy) {
      setState(() => _serviceHealthy = healthy);
    }
  }

  Future<void> _setAutomaticUpdateChecks(bool value) async {
    setState(() => _automaticUpdateChecksEnabled = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('automatic_update_checks_enabled', value);
  }

  Future<void> _setClipboardDetection(bool value) async {
    setState(() => _clipboardDetectionEnabled = value);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('clipboard_detection_enabled', value);
    if (value) unawaited(_checkClipboard());
  }

  Future<void> _maybeCheckForUpdatesOnResume() async {
    if (!_automaticUpdateChecksEnabled || _checkingForUpdate) return;
    final now = DateTime.now();
    final lastSuccess = _lastAutomaticUpdateCheck;
    if (lastSuccess != null &&
        now.difference(lastSuccess) < const Duration(hours: 24)) {
      return;
    }
    final lastAttempt = _lastUpdateAttempt;
    if (lastAttempt != null &&
        now.difference(lastAttempt) < const Duration(hours: 1)) {
      return;
    }
    await _checkForUpdates(automatic: true);
  }

  bool get _supportsDirectorySelection =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  Future<void> _pickDownloadDirectory() async {
    try {
      final path = await getDirectoryPath(confirmButtonText: '选择保存文件夹');
      if (path == null || path.trim().isEmpty || !mounted) return;
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('download_directory', path.trim());
      if (mounted) setState(() => _downloadDirectory = path.trim());
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('无法选择文件夹：$error')));
      }
    }
  }

  Future<void> _clearDownloadDirectory() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('download_directory');
    if (mounted) setState(() => _downloadDirectory = null);
  }

  Future<String?> _saveApiBaseUrl(
    String value, {
    String accessToken = '',
  }) async {
    final trimmed = normalizeTrustedApiUrl(value);
    if (trimmed == null) return '请输入 HTTPS 地址；HTTP 仅允许本机回环地址且不能包含账号密码';
    final token = accessToken.trim();
    if (!kIsWeb && token.isNotEmpty) {
      if (utf8.encode(token).length < 32) {
        return '服务访问令牌必须至少包含 32 字节';
      }
      if (token.length > 1024 || token.contains('\r') || token.contains('\n')) {
        return '服务访问令牌格式无效';
      }
    }
    if (!kIsWeb) {
      try {
        await ServiceCredentialStore.writeTokenFor(trimmed, token);
      } on Object {
        return '系统安全存储不可用，服务令牌未保存';
      }
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('api_base_url', trimmed);
    if (mounted) {
      setState(() {
        _apiBaseUrl = trimmed;
        _serviceAccessToken = token;
        _serviceConfigRevision += 1;
        _serviceHealthy = null;
      });
      unawaited(_checkServiceHealth());
    }
    return null;
  }

  Future<void> _checkForUpdates({
    bool announceLatest = false,
    bool automatic = false,
  }) async {
    if (_checkingForUpdate) return;
    _lastUpdateAttempt = DateTime.now();
    setState(() => _checkingForUpdate = true);
    try {
      final result = await const UpdateService().check();
      if (!mounted) return;
      if (automatic) {
        _lastAutomaticUpdateCheck = DateTime.now();
        final preferences = await SharedPreferences.getInstance();
        await preferences.setInt(
          'last_app_update_check_at',
          _lastAutomaticUpdateCheck!.millisecondsSinceEpoch,
        );
        if (!mounted) return;
      }
      if (result.hasUpdate) {
        await _showUpdateDialog(result);
      } else if (announceLatest) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前已是最新版本')));
      }
    } on Object catch (error) {
      if (mounted && announceLatest) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('检查更新失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _checkingForUpdate = false);
    }
  }

  Future<void> _showUpdateDialog(UpdateCheckResult result) async {
    final release = result.release;
    final hasDownload = release != null && release.url.isNotEmpty;
    final isWindows = result.platform == 'windows';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.system_update_alt_rounded, size: 34),
        title: Text('发现新版本 ${result.manifest.version}'),
        content: SizedBox(
          width: 430,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                result.manifest.notes.isEmpty
                    ? '新版本已经可以下载。'
                    : result.manifest.notes,
              ),
              const SizedBox(height: 14),
              Text(
                hasDownload
                    ? (isWindows
                          ? '安装包会在软件内下载并校验，随后自动启动安装。'
                          : '将打开当前平台的安装包或发布页面。')
                    : '已检测到新版本，但当前平台的安装包尚未发布。',
                style: TextStyle(
                  color: dialogContext.palette.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(hasDownload ? '稍后' : '知道了'),
          ),
          if (hasDownload)
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(dialogContext);
                _installRelease(release, result.manifest.version);
              },
              icon: const Icon(Icons.download_rounded),
              label: Text(isWindows ? '下载并安装' : '前往更新'),
            ),
        ],
      ),
    );
  }

  Future<void> _installRelease(
    UpdatePlatformRelease release,
    String version,
  ) async {
    final progress = ValueNotifier<double>(0);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('正在准备更新'),
          content: SizedBox(
            width: 390,
            child: ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (context, value, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(value: value > 0 ? value : null),
                  const SizedBox(height: 12),
                  Text(
                    value > 0
                        ? '已下载 ${(value * 100).clamp(0, 100).toStringAsFixed(0)}%'
                        : '正在连接更新服务器…',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    try {
      await installUpdate(
        release,
        version: version,
        onProgress: (value) => progress.value = value,
      );
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (mounted && currentUpdatePlatform != 'windows') {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已打开更新页面')));
      }
    } on Object catch (error) {
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('更新失败：$error')));
      }
    } finally {
      progress.dispose();
    }
  }

  void _parseDetected(DetectedLink link) {
    if (link.kind == DetectedLinkKind.magnet ||
        link.kind == DetectedLinkKind.torrent) {
      setState(() {
        _toolInitialInput = link.value;
        _selectedIndex = 3;
      });
      return;
    }
    if (link.kind == DetectedLinkKind.direct) {
      setState(() {
        _toolInitialInput = link.value;
        _selectedIndex = 3;
      });
      return;
    }
    setState(() {
      _parserInitialUrl = link.value;
      _parserRevision += 1;
      _selectedIndex = 1;
    });
  }

  void _parseManual(String value) {
    final detected = _linkDetector.detect(value);
    if (detected == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有识别到有效的 HTTP、Magnet 或种子链接')),
      );
      return;
    }
    _parseDetected(detected);
  }

  void _openTool(String toolId) {
    setState(() {
      _toolInitialInput = toolId;
      _selectedIndex = 3;
    });
  }

  void _recordJob(DownloadJob job, MediaInfo media, MediaOption option) {
    if (!mounted) return;
    setState(() {
      _downloads[job.id] = DownloadRecord(
        job: job,
        title: media.title,
        optionLabel: option.label,
        platform: media.platform,
        sourceUrl: media.sourceUrl,
      );
    });
    unawaited(_persistDownloads());
  }

  Future<void> _persistDownloads() async {
    final preferences = await SharedPreferences.getInstance();
    final records = _downloads.values.toList();
    final recent = records.length <= 100
        ? records
        : records.sublist(records.length - 100);
    await preferences.setString(
      'download_history',
      jsonEncode(recent.map((record) => record.toJson()).toList()),
    );
  }

  Future<void> _clearDownloadHistory() async {
    setState(() => _downloads.clear());
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('download_history');
  }

  void _reopenDownload(DownloadRecord record) {
    if (record.sourceUrl.isEmpty) return;
    _parseManual(record.sourceUrl);
  }

  Future<void> _showSettings() async {
    final apiController = TextEditingController(text: _apiBaseUrl);
    final tokenController = TextEditingController(
      text: kIsWeb ? '' : _serviceAccessToken,
    );
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('设置'),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      '外观',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: Text('跟随系统'),
                        ),
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: Text('浅色'),
                        ),
                        ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                      ],
                      selected: {widget.themeMode},
                      onSelectionChanged: (value) {
                        widget.onThemeModeChanged(value.first);
                        setDialogState(() {});
                      },
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      '下载',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.folder_outlined),
                      title: const Text('默认保存路径'),
                      subtitle: Text(
                        _supportsDirectorySelection
                            ? (_downloadDirectory ?? '每次下载时选择保存位置')
                            : '移动端下载后由系统面板选择保存位置',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_supportsDirectorySelection)
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () async {
                              await _pickDownloadDirectory();
                              setDialogState(() {});
                            },
                            icon: const Icon(Icons.folder_open_rounded),
                            label: Text(
                              _downloadDirectory == null ? '选择文件夹' : '更改文件夹',
                            ),
                          ),
                          if (_downloadDirectory != null)
                            TextButton(
                              onPressed: () async {
                                await _clearDownloadDirectory();
                                setDialogState(() {});
                              },
                              child: const Text('恢复每次询问'),
                            ),
                        ],
                      ),
                    const SizedBox(height: 18),
                    const Text(
                      '高级工具服务',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: apiController,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: '服务地址',
                        hintText: 'https://resolver.example.com',
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                    ),
                    if (!kIsWeb) ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: tokenController,
                        obscureText: true,
                        enableSuggestions: false,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: '服务访问令牌（可选）',
                          hintText: '至少 32 字节，仅保存在系统安全存储中',
                          prefixIcon: Icon(Icons.key_rounded),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '远程地址强制 HTTPS；手机和 Web 的高级工具需连接受信任服务。',
                            style: TextStyle(
                              color: dialogContext.palette.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton(
                          onPressed: () async {
                            final error = await _saveApiBaseUrl(
                              apiController.text,
                              accessToken: tokenController.text,
                            );
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(error ?? '高级工具服务地址已保存')),
                            );
                          },
                          child: const Text('保存'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      '隐私',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: _clipboardDetectionEnabled,
                      onChanged: (value) {
                        _setClipboardDetection(value);
                        setDialogState(() {});
                      },
                      title: const Text('识别剪贴板链接'),
                      subtitle: const Text('默认关闭；开启后只提示，确认后才会联网处理'),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      '更新',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: _automaticUpdateChecksEnabled,
                      onChanged: (value) {
                        _setAutomaticUpdateChecks(value);
                        setDialogState(() {});
                      },
                      title: const Text('启动时自动检查更新'),
                      subtitle: const Text('当前版本 $appVersion · 按当前平台检查'),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: _checkingForUpdate
                            ? null
                            : () {
                                Navigator.pop(dialogContext);
                                _checkForUpdates(announceLatest: true);
                              },
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('立即检查更新'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      LocalMediaService.isSupported
                          ? '手机本地解析器仅处理解析与下载；高级工具会按能力显示。'
                          : '高级工具需要已连接且受信任的解析服务。',
                      style: TextStyle(
                        color: dialogContext.palette.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('完成'),
              ),
            ],
          ),
        ),
      );
    } finally {
      apiController.dispose();
      tokenController.dispose();
    }
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'langbai解析',
      applicationVersion: appVersion,
      applicationIcon: ClipOval(
        child: Image.asset(
          'assets/images/langbai_avatar.png',
          width: 52,
          height: 52,
        ),
      ),
      children: [
        const Text('跨平台公开媒体解析、转换与下载工作台。仅处理你有权使用的公开、无 DRM 内容。'),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => launchUrl(
              Uri.parse('https://github.com/2786886095/langbai-resolver'),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.code_rounded),
            label: const Text('GitHub · langbai-resolver'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      DashboardPage(
        recentDownloads: _downloads.values.toList().reversed.toList(),
        onParseManual: _parseManual,
        onOpenTool: _openTool,
        onShowAllTasks: () => setState(() => _selectedIndex = 2),
      ),
      ParserPage(
        key: ValueKey('parser-$_parserRevision-$_serviceConfigRevision'),
        initialUrl: _parserInitialUrl,
        onJobChanged: _recordJob,
      ),
      DownloadsPage(
        records: _downloads.values.toList().reversed.toList(),
        onClear: _clearDownloadHistory,
        onRetry: _reopenDownload,
      ),
      ToolsPage(
        key: ValueKey('tools-$_serviceConfigRevision'),
        initialInput: _toolInitialInput,
        onOpenParser: _parseManual,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 960;
        if (desktop) {
          return Scaffold(
            body: Row(
              children: [
                SizedBox(
                  width: 214,
                  child: _DesktopNavigation(
                    selectedIndex: _selectedIndex,
                    serviceHealthy: _serviceHealthy,
                    localParser: LocalMediaService.isSupported,
                    onSelected: (value) =>
                        setState(() => _selectedIndex = value),
                    onSettings: _showSettings,
                    onAbout: _showAbout,
                  ),
                ),
                VerticalDivider(width: 1, color: context.palette.border),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: IndexedStack(
                          index: _selectedIndex,
                          children: pages,
                        ),
                      ),
                      Positioned(
                        top: 16,
                        right: 20,
                        child: _ThemeMenu(
                          themeMode: widget.themeMode,
                          onChanged: widget.onThemeModeChanged,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 16,
            title: const _Brand(compact: true),
            actions: [
              IconButton(
                tooltip: '设置',
                onPressed: _showSettings,
                icon: const Icon(Icons.settings_outlined),
              ),
              _ThemeMenu(
                themeMode: widget.themeMode,
                onChanged: widget.onThemeModeChanged,
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: IndexedStack(index: _selectedIndex, children: pages),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (value) =>
                setState(() => _selectedIndex = value),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: '首页',
              ),
              NavigationDestination(
                icon: Icon(Icons.link_rounded),
                label: '解析',
              ),
              NavigationDestination(
                icon: Icon(Icons.download_outlined),
                selectedIcon: Icon(Icons.download_rounded),
                label: '下载',
              ),
              NavigationDestination(
                icon: Icon(Icons.workspaces_outline),
                selectedIcon: Icon(Icons.workspaces_rounded),
                label: '工具',
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DesktopNavigation extends StatelessWidget {
  const _DesktopNavigation({
    required this.selectedIndex,
    required this.serviceHealthy,
    required this.localParser,
    required this.onSelected,
    required this.onSettings,
    required this.onAbout,
  });

  final int selectedIndex;
  final bool? serviceHealthy;
  final bool localParser;
  final ValueChanged<int> onSelected;
  final VoidCallback onSettings;
  final VoidCallback onAbout;

  @override
  Widget build(BuildContext context) {
    const items = [
      (Icons.home_outlined, Icons.home_rounded, '首页'),
      (Icons.link_rounded, Icons.link_rounded, '解析'),
      (Icons.download_outlined, Icons.download_rounded, '下载'),
      (Icons.workspaces_outline, Icons.workspaces_rounded, '工具'),
    ];
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 18, 14, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: _Brand(),
              ),
              const SizedBox(height: 28),
              for (var index = 0; index < items.length; index++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: _NavigationItem(
                    icon: selectedIndex == index
                        ? items[index].$2
                        : items[index].$1,
                    label: items[index].$3,
                    selected: selectedIndex == index,
                    onTap: () => onSelected(index),
                  ),
                ),
              const Spacer(),
              _NavigationItem(
                icon: Icons.settings_outlined,
                label: '设置',
                selected: false,
                onTap: onSettings,
              ),
              const SizedBox(height: 4),
              _NavigationItem(
                icon: Icons.info_outline_rounded,
                label: '关于',
                selected: false,
                onTap: onAbout,
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: context.palette.border),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: serviceHealthy == null
                            ? context.palette.textMuted
                            : serviceHealthy!
                            ? context.palette.success
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        serviceHealthy == null
                            ? localParser
                                  ? '正在加载本地解析器'
                                  : '正在连接解析服务'
                            : serviceHealthy!
                            ? localParser
                                  ? '本地解析器运行正常'
                                  : '解析服务运行正常'
                            : localParser
                            ? '本地解析器不可用'
                            : '解析服务未连接',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.icon,
    required this.label,
    required this.selected,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: Material(
        color: selected
            ? context.palette.navigationSelected
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            height: 48,
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 3,
                  height: selected ? 30 : 0,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(width: 13),
                Icon(
                  icon,
                  size: 21,
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                const SizedBox(width: 13),
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      'langbai解析',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: compact ? 17 : 18,
        fontWeight: FontWeight.w800,
        letterSpacing: -.3,
      ),
    );
    return Row(
      mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
      children: [
        Container(
          width: compact ? 34 : 38,
          height: compact ? 34 : 38,
          decoration: BoxDecoration(
            color: context.palette.navigationSelected,
            shape: BoxShape.circle,
          ),
          child: ClipOval(
            child: Image.asset(
              'assets/images/langbai_avatar.png',
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(width: 9),
        if (compact)
          Flexible(child: label)
        else
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: label,
            ),
          ),
      ],
    );
  }
}

class _ThemeMenu extends StatelessWidget {
  const _ThemeMenu({required this.themeMode, required this.onChanged});

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return PopupMenuButton<ThemeMode>(
      tooltip: '切换主题',
      onSelected: onChanged,
      itemBuilder: (context) => const [
        PopupMenuItem(value: ThemeMode.system, child: Text('跟随系统')),
        PopupMenuItem(value: ThemeMode.light, child: Text('浅色模式')),
        PopupMenuItem(value: ThemeMode.dark, child: Text('深色模式')),
      ],
      icon: Icon(
        brightness == Brightness.dark
            ? Icons.dark_mode_outlined
            : Icons.light_mode_outlined,
      ),
    );
  }
}
