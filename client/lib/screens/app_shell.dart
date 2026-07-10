import 'dart:async';

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
import '../services/link_detector.dart';
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
  bool _automaticUpdateChecksEnabled = true;
  bool _checkingForUpdate = false;
  String? _downloadDirectory;
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
    if (state == AppLifecycleState.resumed) _checkClipboard();
  }

  Future<void> _restorePreferences() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _automaticUpdateChecksEnabled =
          preferences.getBool('automatic_update_checks_enabled') ?? true;
      _downloadDirectory = preferences.getString('download_directory');
    });
    if (_demoClipboardLink.isNotEmpty) {
      final detected = _linkDetector.detect(_demoClipboardLink);
      if (detected != null && mounted) {
        _lastClipboardValue = detected.value;
        _parseDetected(detected);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_demoClipboardLink.isEmpty) _checkClipboard();
      if (_automaticUpdateChecksEnabled) _checkForUpdates();
    });
  }

  Future<void> _checkClipboard() async {
    try {
      final detected = await _linkDetector.readClipboard();
      if (!mounted || detected == null) return;
      if (detected.value == _lastClipboardValue) return;
      _lastClipboardValue = detected.value;
      _parseDetected(detected);
    } on Object {
      // Clipboard access may be denied by the platform; manual paste remains available.
    }
  }

  Future<void> _checkServiceHealth() async {
    final preferences = await SharedPreferences.getInstance();
    final baseUrl =
        preferences.getString('api_base_url')?.trim() ?? _defaultShellApiUrl;
    final api = ApiClient(baseUrl);
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

  bool get _supportsDirectorySelection =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  Future<void> _pickDownloadDirectory() async {
    try {
      final path = await getDirectoryPath(
        confirmButtonText: '选择保存文件夹',
      );
      if (path == null || path.trim().isEmpty || !mounted) return;
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('download_directory', path.trim());
      if (mounted) setState(() => _downloadDirectory = path.trim());
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法选择文件夹：$error')),
        );
      }
    }
  }

  Future<void> _clearDownloadDirectory() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('download_directory');
    if (mounted) setState(() => _downloadDirectory = null);
  }

  Future<void> _checkForUpdates({bool announceLatest = false}) async {
    if (_checkingForUpdate) return;
    setState(() => _checkingForUpdate = true);
    try {
      final result = await const UpdateService().check();
      if (!mounted) return;
      if (result.hasUpdate) {
        await _showUpdateDialog(result);
      } else if (announceLatest) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前已是最新版本')),
        );
      }
    } on Object catch (error) {
      if (mounted && announceLatest) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('检查更新失败：$error')),
        );
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已打开更新页面')),
        );
      }
    } on Object catch (error) {
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('更新失败：$error')),
        );
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
    if (detected == null) return;
    _parseDetected(detected);
  }

  void _openTool(String toolId) {
    setState(() {
      _toolInitialInput = toolId;
      _selectedIndex = 3;
    });
  }

  void _recordJob(
    DownloadJob job,
    MediaInfo media,
    MediaOption option,
  ) {
    if (!mounted) return;
    setState(() {
      _downloads[job.id] = DownloadRecord(
        job: job,
        title: media.title,
        optionLabel: option.label,
        platform: media.platform,
      );
    });
  }

  Future<void> _showSettings() async {
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
                  const Text('外观',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                          value: ThemeMode.system, label: Text('跟随系统')),
                      ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                      ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                    ],
                    selected: {widget.themeMode},
                    onSelectionChanged: (value) {
                      widget.onThemeModeChanged(value.first);
                      setDialogState(() {});
                    },
                  ),
                  const SizedBox(height: 20),
                  const Text('下载',
                      style: TextStyle(fontWeight: FontWeight.w800)),
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
                  const Text('更新',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _automaticUpdateChecksEnabled,
                    onChanged: (value) {
                      _setAutomaticUpdateChecks(value);
                      setDialogState(() {});
                    },
                    title: const Text('启动时自动检查更新'),
                    subtitle: const Text('当前版本 $appVersion · 全平台支持检测'),
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
                  Text('解析服务地址可在“解析”页面右上角调整。',
                      style: TextStyle(
                          color: dialogContext.palette.textMuted,
                          fontSize: 12)),
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
        key: ValueKey('parser-$_parserRevision'),
        initialUrl: _parserInitialUrl,
        onJobChanged: _recordJob,
      ),
      DownloadsPage(records: _downloads.values.toList().reversed.toList()),
      ToolsPage(
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
                            index: _selectedIndex, children: pages),
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
                  label: '首页'),
              NavigationDestination(
                  icon: Icon(Icons.link_rounded), label: '解析'),
              NavigationDestination(
                  icon: Icon(Icons.download_outlined),
                  selectedIcon: Icon(Icons.download_rounded),
                  label: '下载'),
              NavigationDestination(
                  icon: Icon(Icons.workspaces_outline),
                  selectedIcon: Icon(Icons.workspaces_rounded),
                  label: '工具'),
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
    required this.onSelected,
    required this.onSettings,
    required this.onAbout,
  });

  final int selectedIndex;
  final bool? serviceHealthy;
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
                            ? '正在连接解析服务'
                            : serviceHealthy!
                                ? '解析服务运行正常'
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
    return Material(
      color: selected ? context.palette.navigationSelected : Colors.transparent,
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
              Icon(icon,
                  size: 21,
                  color:
                      selected ? Theme.of(context).colorScheme.primary : null),
              const SizedBox(width: 13),
              Text(
                label,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color:
                      selected ? Theme.of(context).colorScheme.primary : null,
                ),
              ),
            ],
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
            child: Image.asset('assets/images/langbai_avatar.png',
                fit: BoxFit.cover),
          ),
        ),
        const SizedBox(width: 9),
        if (compact)
          label
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
      icon: Icon(brightness == Brightness.dark
          ? Icons.dark_mode_outlined
          : Icons.light_mode_outlined),
    );
  }
}
