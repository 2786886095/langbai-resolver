import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/media_models.dart';
import '../services/api_client.dart';
import '../services/api_endpoint_policy.dart';
import '../services/bilibili_auth_service.dart';
import '../services/download_saver.dart';
import '../services/link_detector.dart';
import '../services/local_media_service.dart';
import '../services/service_credential_store.dart';
import '../theme/langbai_theme.dart';

const _defaultApiUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8787',
);

class ParserPage extends StatefulWidget {
  const ParserPage({super.key, this.initialUrl, this.onJobChanged});

  final String? initialUrl;
  final void Function(DownloadJob job, MediaInfo media, MediaOption option)?
  onJobChanged;

  @override
  State<ParserPage> createState() => _ParserPageState();
}

class _ParserPageState extends State<ParserPage> {
  final _urlController = TextEditingController();
  late final TextEditingController _serverController;
  late ApiClient _api;
  MediaInfo? _media;
  MediaOption? _selected;
  AssetKind _kind = AssetKind.video;
  DownloadJob? _job;
  bool _resolving = false;
  bool _saving = false;
  bool _cancelRequested = false;
  String? _activeLocalProcessId;
  double _saveProgress = 0;
  String? _error;
  BilibiliAccount? _bilibiliAccount;
  bool _bilibiliAuthBusy = false;

  bool get _usesLocalParser => LocalMediaService.isSupported;
  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  bool get _bilibiliLoginAvailable {
    if (!BilibiliAuthService.isSupported) return false;
    if (_usesLocalParser) return true;
    final host = Uri.tryParse(_api.baseUrl)?.host.toLowerCase();
    return host == '127.0.0.1' || host == 'localhost' || host == '::1';
  }

  @override
  void initState() {
    super.initState();
    _serverController = TextEditingController(text: _defaultApiUrl);
    _api = ApiClient(_defaultApiUrl);
    _initialize();
  }

  Future<void> _initialize() async {
    await _restoreApiUrl();
    await _restoreBilibiliAccount();
    final initialUrl = widget.initialUrl?.trim();
    if (!mounted || initialUrl == null || initialUrl.isEmpty) return;
    _urlController.text = initialUrl;
    await _resolve();
  }

  Future<void> _restoreBilibiliAccount() async {
    if (!_bilibiliLoginAvailable) return;
    try {
      final account = await BilibiliAuthService.instance.restore();
      if (mounted) setState(() => _bilibiliAccount = account);
    } on Object {
      // Manual QR login remains available when secure storage is temporarily unavailable.
    }
  }

  bool _isBilibiliUrl(String value) {
    final host = Uri.tryParse(value)?.host.toLowerCase() ?? '';
    return host == 'b23.tv' ||
        host == 'bilibili.com' ||
        host.endsWith('.bilibili.com');
  }

  Future<void> _showBilibiliLogin() async {
    if (_bilibiliAuthBusy) return;
    setState(() => _bilibiliAuthBusy = true);
    try {
      final account = await showDialog<BilibiliAccount>(
        context: context,
        barrierDismissible: false,
        builder: (context) => const _BilibiliLoginDialog(),
      );
      if (mounted && account != null) {
        setState(() => _bilibiliAccount = account);
      }
    } finally {
      if (mounted) setState(() => _bilibiliAuthBusy = false);
    }
  }

  Future<void> _logoutBilibili() async {
    await BilibiliAuthService.instance.logout();
    if (LocalMediaService.isSupported) {
      await LocalMediaService.instance.clearNativeSession();
    }
    if (mounted) {
      setState(() {
        _bilibiliAccount = null;
        _media = null;
        _selected = null;
        _job = null;
        _saveProgress = 0;
        _error = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已退出并清除本机 B站解析缓存')));
    }
  }

  Future<void> _restoreApiUrl() async {
    if (_usesLocalParser) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      final saved = normalizeTrustedApiUrl(
        preferences.getString('api_base_url'),
      );
      if (!mounted || saved == null || saved.isEmpty) return;
      final token = await ServiceCredentialStore.readTokenFor(saved);
      if (!mounted) return;
      _api.close();
      setState(() {
        _api = ApiClient(saved, instanceToken: token.isEmpty ? null : token);
        _serverController.text = saved;
      });
    } on Object {
      // Compile-time default remains usable if preferences are unavailable.
    }
  }

  @override
  void dispose() {
    _api.close();
    _urlController.dispose();
    _serverController.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      final text = data!.text!.trim();
      _urlController.text = LinkDetector.extractHttpUrl(text) ?? text;
    }
  }

  Future<void> _resolve() async {
    final input = _urlController.text.trim();
    final url = LinkDetector.extractHttpUrl(input);
    if (url == null) {
      setState(() => _error = '未在粘贴内容中找到 http 或 https 链接');
      return;
    }
    _urlController.text = url;
    setState(() {
      _resolving = true;
      _error = null;
      _media = null;
      _selected = null;
      _job = null;
    });
    try {
      if (!_usesLocalParser) {
        final serviceUri = Uri.tryParse(_api.baseUrl);
        final loopback =
            serviceUri != null &&
            const {
              '127.0.0.1',
              'localhost',
              '::1',
            }.contains(serviceUri.host.toLowerCase());
        if (kIsWeb && loopback) {
          throw const ApiException('Web 版尚未配置解析服务，请先在设置中填写 HTTPS 服务地址');
        }
        if (!await _api.isHealthy()) {
          throw const ApiException('解析服务未连接或身份校验失败，请检查设置后重试');
        }
      }
      final bilibiliCookie = _bilibiliLoginAvailable && _isBilibiliUrl(url)
          ? BilibiliAuthService.instance.cookieHeader
          : null;
      final media = _usesLocalParser
          ? await LocalMediaService.instance.resolve(
              url,
              bilibiliCookie: bilibiliCookie,
            )
          : await _api.resolve(url, bilibiliCookie: bilibiliCookie);
      if (!mounted) return;
      final availableKinds = AssetKind.values
          .where((kind) => media.options.any((option) => option.kind == kind))
          .toList();
      final kind = availableKinds.contains(AssetKind.video)
          ? AssetKind.video
          : availableKinds.first;
      setState(() {
        _media = media;
        _kind = kind;
        _selected = media.options.firstWhere((option) => option.kind == kind);
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on LocalMediaException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on TimeoutException {
      if (mounted) setState(() => _error = '解析超时，请检查解析服务或稍后重试');
    } on Object catch (error) {
      if (mounted) setState(() => _error = '无法连接解析服务：$error');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _startDownload() async {
    final media = _media;
    final option = _selected;
    if (media == null || option == null || _saving) return;
    final destination = await _chooseSaveDestination(option);
    if (destination == null || !mounted) return;
    setState(() {
      _error = null;
      _saving = true;
      _cancelRequested = false;
      _saveProgress = 0;
    });
    try {
      if (_usesLocalParser) {
        await _startLocalDownload(media, option, destination);
        return;
      }
      var job = await _api.createJob(media.mediaId, option.id);
      final taskDeadline = DateTime.now().add(const Duration(hours: 2));
      if (mounted) {
        setState(() => _job = job);
        widget.onJobChanged?.call(job, media, option);
      }
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
        widget.onJobChanged?.call(job, media, option);
      }
      if (job.state == JobState.failed) {
        throw ApiException(job.error ?? '服务器下载失败');
      }
      if (job.state == JobState.cancelled) {
        throw const ApiException('任务已取消');
      }
      final result = await saveDownload(
        _api.fileUri(job.id),
        job.filename ?? 'media.${option.extension}',
        (progress) {
          if (mounted) setState(() => _saveProgress = progress);
        },
        destination: destination,
        mediaType: option.kind.name,
        headers: _api.downloadHeaders,
        isCancelled: () => _cancelRequested,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.message)));
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on LocalMediaException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '下载失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _activeLocalProcessId = null;
        });
      }
    }
  }

  Future<void> _startLocalDownload(
    MediaInfo media,
    MediaOption option,
    SaveDestination destination,
  ) async {
    final jobId = LocalMediaService.instance.createProcessId();
    _activeLocalProcessId = jobId;
    var job = DownloadJob(id: jobId, state: JobState.running, progress: 0);
    if (mounted) {
      setState(() => _job = job);
      widget.onJobChanged?.call(job, media, option);
    }
    late final LocalDownloadResult result;
    try {
      result = await LocalMediaService.instance.download(
        mediaId: media.mediaId,
        optionId: option.id,
        kind: option.kind,
        destination: destination,
        processId: jobId,
        onProgress: (progress) {
          if (!mounted) return;
          job = DownloadJob(
            id: jobId,
            state: JobState.running,
            progress: progress,
            filename: job.filename,
          );
          setState(() {
            _job = job;
            _saveProgress = progress;
          });
          widget.onJobChanged?.call(job, media, option);
        },
      );
    } on Object catch (error) {
      if (mounted) {
        job = DownloadJob(
          id: jobId,
          state: _cancelRequested ? JobState.cancelled : JobState.failed,
          progress: job.progress,
          error: error.toString(),
        );
        setState(() => _job = job);
        widget.onJobChanged?.call(job, media, option);
      }
      rethrow;
    }
    if (!mounted) return;
    job = DownloadJob(
      id: jobId,
      state: JobState.completed,
      progress: 1,
      filename: result.filename,
    );
    setState(() {
      _job = job;
      _saveProgress = 1;
    });
    widget.onJobChanged?.call(job, media, option);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(result.message)));
  }

  Future<void> _cancelDownload() async {
    if (!_saving || _cancelRequested) return;
    setState(() => _cancelRequested = true);
    try {
      final localId = _activeLocalProcessId;
      DownloadJob? cancelled;
      if (_usesLocalParser && localId != null) {
        await LocalMediaService.instance.cancelDownload(localId);
        cancelled = DownloadJob(
          id: localId,
          state: JobState.cancelled,
          progress: _job?.progress ?? 0,
          error: '用户已取消',
        );
      } else if (_job != null) {
        cancelled = await _api.cancelJob(_job!.id);
      }
      if (mounted && cancelled != null) {
        setState(() => _job = cancelled);
        final media = _media;
        final option = _selected;
        if (media != null && option != null) {
          widget.onJobChanged?.call(cancelled, media, option);
        }
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = '取消失败：$error');
    }
  }

  Future<SaveDestination?> _chooseSaveDestination(MediaOption option) async {
    if (!_isMobile || option.kind == AssetKind.audio) {
      return SaveDestination.files;
    }
    final typeLabel = option.kind == AssetKind.video ? '视频' : '图片';
    return showModalBottomSheet<SaveDestination>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '保存到哪里？',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                '选择$typeLabel的保存位置',
                style: TextStyle(color: context.palette.textMuted),
              ),
              const SizedBox(height: 16),
              _SaveDestinationTile(
                icon: Icons.folder_rounded,
                title: '保存到文件',
                subtitle: defaultTargetPlatform == TargetPlatform.android
                    ? '保存到 Download/langbai解析'
                    : '保存到“文件”App/langbai解析',
                onTap: () => Navigator.pop(context, SaveDestination.files),
              ),
              const SizedBox(height: 10),
              _SaveDestinationTile(
                icon: option.kind == AssetKind.video
                    ? Icons.video_library_rounded
                    : Icons.photo_library_rounded,
                title: '保存到相册',
                subtitle: '保存到系统照片库，首次使用会请求权限',
                onTap: () => Navigator.pop(context, SaveDestination.gallery),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _changeApiUrl(String value) async {
    final normalized = normalizeTrustedApiUrl(value);
    if (normalized == null) {
      setState(() => _error = '请输入 HTTPS 地址；HTTP 仅允许本机回环地址');
      return;
    }
    final token = await ServiceCredentialStore.readTokenFor(normalized);
    _api.close();
    setState(() {
      _api = ApiClient(normalized, instanceToken: token.isEmpty ? null : token);
      _serverController.text = normalized;
      _error = null;
      _media = null;
      _job = null;
    });
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('api_base_url', normalized);
  }

  Future<void> _showSettings() async {
    final controller = TextEditingController(text: _serverController.text);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('解析服务设置'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('远程服务必须使用 HTTPS；HTTP 仅允许同一设备的本机回环地址。'),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '服务地址',
                  hintText: 'http://192.168.1.20:8787',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null && mounted) await _changeApiUrl(value);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SelectionArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(26, 28, 26, 56),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '链接解析',
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '选择视频清晰度、音频、封面或图片',
                              style: TextStyle(
                                color: context.palette.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_usesLocalParser)
                        const Chip(
                          avatar: Icon(Icons.smartphone_rounded, size: 17),
                          label: Text('本机解析'),
                        )
                      else
                        IconButton(
                          tooltip: '解析服务设置',
                          onPressed: _saving || _resolving
                              ? null
                              : _showSettings,
                          icon: const Icon(Icons.tune_rounded),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _buildHero(context),
                  if (_error != null) ...[
                    const SizedBox(height: 18),
                    _ErrorBanner(message: _error!),
                  ],
                  if (_media != null) ...[
                    const SizedBox(height: 22),
                    _buildMediaCard(context, _media!),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHero(BuildContext context) {
    return LangbaiCard(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '解析公开媒体链接',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w900,
                letterSpacing: -.6,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '识别公开的视频、音频、封面与网页图片，按清晰度选择后保存。',
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: context.palette.textMuted),
            ),
            const SizedBox(height: 18),
            const Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _PlatformChip('短视频'),
                _PlatformChip('长视频'),
                _PlatformChip('社交媒体'),
                _PlatformChip('图文页面'),
                _PlatformChip('通用网页'),
              ],
            ),
            const SizedBox(height: 24),
            if (_bilibiliLoginAvailable) ...[
              _buildBilibiliAccountCard(context),
              const SizedBox(height: 18),
            ],
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 680;
                final input = TextField(
                  controller: _urlController,
                  enabled: !_resolving && !_saving,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _resolve(),
                  decoration: InputDecoration(
                    hintText: '粘贴作品或网页链接…',
                    prefixIcon: const Icon(Icons.link_rounded),
                    suffixIcon: IconButton(
                      tooltip: '粘贴',
                      onPressed: _resolving || _saving ? null : _paste,
                      icon: const Icon(Icons.content_paste_rounded),
                    ),
                  ),
                );
                final button = SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    onPressed: _resolving || _saving ? null : _resolve,
                    icon: _resolving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome_rounded),
                    label: Text(_resolving ? '正在解析' : '开始解析'),
                  ),
                );
                if (narrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [input, const SizedBox(height: 12), button],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: input),
                    const SizedBox(width: 12),
                    button,
                  ],
                );
              },
            ),
            const SizedBox(height: 14),
            Text(
              '仅用于你有权保存的公开、无 DRM 内容。平台规则变化时需更新服务端解析器。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: context.palette.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBilibiliAccountCard(BuildContext context) {
    final account = _bilibiliAccount;
    final loggedIn = BilibiliAuthService.instance.isLoggedIn;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: context.palette.surfaceRaised,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.palette.border),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final icon = Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color.fromRGBO(255, 102, 153, .12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.tv_rounded, color: Color(0xFFFF6699)),
          );
          final details = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                loggedIn ? account?.name ?? 'B站已登录' : 'B站最高画质',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              Text(
                loggedIn
                    ? '${account?.vipLabel?.isNotEmpty == true ? '${account!.vipLabel} · ' : ''}登录会话仅加密保存在本机'
                    : '扫码登录后解析 1080P、4K、HDR 等账号可见画质',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.palette.textMuted,
                ),
              ),
            ],
          );
          final action = loggedIn
              ? TextButton(
                  onPressed: _bilibiliAuthBusy ? null : _logoutBilibili,
                  child: const Text('退出'),
                )
              : FilledButton.tonalIcon(
                  onPressed: _bilibiliAuthBusy ? null : _showBilibiliLogin,
                  icon: const Icon(Icons.qr_code_2_rounded),
                  label: const Text('扫码登录'),
                );
          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    icon,
                    const SizedBox(width: 12),
                    Expanded(child: details),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(width: double.infinity, child: action),
              ],
            );
          }
          return Row(
            children: [
              icon,
              const SizedBox(width: 12),
              Expanded(child: details),
              const SizedBox(width: 12),
              action,
            ],
          );
        },
      ),
    );
  }

  Widget _buildMediaCard(BuildContext context, MediaInfo media) {
    final kinds = AssetKind.values
        .where((kind) => media.options.any((option) => option.kind == kind))
        .toList(growable: false);
    final options = media.options
        .where((option) => option.kind == _kind)
        .toList();
    return LangbaiCard(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 700;
                final preview = _MediaPreview(media: media);
                final details = _MediaDetails(media: media);
                return narrow
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          preview,
                          const SizedBox(height: 18),
                          details,
                        ],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 340, child: preview),
                          const SizedBox(width: 22),
                          Expanded(child: details),
                        ],
                      );
              },
            ),
            if (media.warnings.isNotEmpty) ...[
              const SizedBox(height: 18),
              ...media.warnings.map(
                (warning) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 17,
                        color: context.palette.warning,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(warning)),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 22),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final kind in kinds)
                  ChoiceChip(
                    selected: _kind == kind,
                    onSelected: _saving
                        ? null
                        : (_) {
                            setState(() {
                              _kind = kind;
                              _selected = media.options.firstWhere(
                                (option) => option.kind == kind,
                              );
                            });
                          },
                    avatar: Icon(_kindIcon(kind), size: 18),
                    label: Text(
                      '${_kindLabel(kind)} (${media.options.where((o) => o.kind == kind).length})',
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            ...options.map(
              (option) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _OptionTile(
                  option: option,
                  selected: _selected?.id == option.id,
                  enabled: !_saving,
                  onTap: () => setState(() => _selected = option),
                ),
              ),
            ),
            if (_job != null || _saving) ...[
              const SizedBox(height: 8),
              _ProgressPanel(
                job: _job,
                saveProgress: _saveProgress,
                local: _usesLocalParser,
                onCancel: _saving ? _cancelDownload : null,
              ),
            ],
            const SizedBox(height: 14),
            SizedBox(
              height: 54,
              child: FilledButton.icon(
                onPressed: _selected == null || _saving ? null : _startDownload,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_rounded),
                label: Text(_saving ? '正在准备文件…' : '下载所选资源'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlatformChip extends StatelessWidget {
  const _PlatformChip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: context.palette.surfaceRaised,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: context.palette.border),
      ),
      child: Text(text, style: const TextStyle(fontSize: 12)),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: '错误：$message',
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Theme.of(context).colorScheme.error),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
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

class _MediaPreview extends StatelessWidget {
  const _MediaPreview({required this.media});

  final MediaInfo media;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: DecoratedBox(
          decoration: BoxDecoration(color: context.palette.surfaceRaised),
          child: media.thumbnailUrl == null
              ? const Center(child: Icon(Icons.movie_filter_rounded, size: 44))
              : Image.network(
                  media.thumbnailUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const Center(
                    child: Icon(Icons.broken_image_outlined, size: 42),
                  ),
                ),
        ),
      ),
    );
  }
}

class _MediaDetails extends StatelessWidget {
  const _MediaDetails({required this.media});

  final MediaInfo media;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            media.platform,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          media.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 16,
          runSpacing: 7,
          children: [
            if (media.creator != null)
              _Meta(icon: Icons.person_outline_rounded, text: media.creator!),
            if (media.durationSeconds != null)
              _Meta(
                icon: Icons.schedule_rounded,
                text: _duration(media.durationSeconds!),
              ),
            _Meta(
              icon: Icons.layers_outlined,
              text: '${media.options.length} 个资源',
            ),
          ],
        ),
      ],
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: context.palette.textMuted),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(color: context.palette.textMuted, fontSize: 13),
        ),
      ],
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.option,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final MediaOption option;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      enabled: enabled,
      button: true,
      inMutuallyExclusiveGroup: true,
      label: option.label,
      child: Material(
        color: selected
            ? context.palette.navigationSelected
            : context.palette.surfaceRaised,
        borderRadius: BorderRadius.circular(15),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(15),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : context.palette.border,
              ),
            ),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected
                          ? Theme.of(context).colorScheme.primary
                          : context.palette.textMuted,
                      width: selected ? 6 : 2,
                    ),
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        option.label,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (option.resolution != null ||
                          option.filesizeLabel != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          [
                            option.resolution,
                            option.filesizeLabel,
                          ].whereType<String>().join(' · '),
                          style: TextStyle(
                            color: context.palette.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (option.requiresMerge)
                  Tooltip(
                    message: '服务端将用 FFmpeg 自动合并最佳音频',
                    child: Icon(
                      Icons.merge_rounded,
                      size: 19,
                      color: context.palette.textMuted,
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

class _SaveDestinationTile extends StatelessWidget {
  const _SaveDestinationTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.palette.surfaceRaised,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: Theme.of(context).colorScheme.primary),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: context.palette.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProgressPanel extends StatelessWidget {
  const _ProgressPanel({
    required this.job,
    required this.saveProgress,
    required this.local,
    this.onCancel,
  });

  final DownloadJob? job;
  final double saveProgress;
  final bool local;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final current = job;
    final serverDone = current?.state == JobState.completed;
    final value = serverDone ? saveProgress : current?.progress ?? 0;
    final label = current == null
        ? '正在创建任务…'
        : switch (current.state) {
            JobState.queued => local ? '等待本机处理…' : '等待服务器处理…',
            JobState.running => local ? '本机正在下载并处理…' : '服务器正在下载并处理…',
            JobState.completed => saveProgress >= 1 ? '保存完成' : '正在保存到设备…',
            JobState.failed => '任务失败',
            JobState.cancelled => '任务已取消',
          };
    final details = current?.speedBytesPerSecond == null
        ? null
        : '${_speed(current!.speedBytesPerSecond!)}${current.etaSeconds == null ? '' : ' · 约 ${current.etaSeconds}s'}';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.palette.surfaceRaised,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              if (details != null)
                Text(
                  details,
                  style: TextStyle(
                    color: context.palette.textMuted,
                    fontSize: 12,
                  ),
                ),
              if (onCancel != null &&
                  (current == null ||
                      current.state == JobState.queued ||
                      current.state == JobState.running)) ...[
                const SizedBox(width: 8),
                TextButton(onPressed: onCancel, child: const Text('取消')),
              ],
            ],
          ),
          const SizedBox(height: 9),
          LinearProgressIndicator(value: value <= 0 ? null : value),
        ],
      ),
    );
  }
}

class _BilibiliLoginDialog extends StatefulWidget {
  const _BilibiliLoginDialog();

  @override
  State<_BilibiliLoginDialog> createState() => _BilibiliLoginDialogState();
}

class _BilibiliLoginDialogState extends State<_BilibiliLoginDialog> {
  BilibiliQrSession? _session;
  Timer? _timer;
  String _message = '正在生成登录二维码…';
  bool _loading = true;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _createSession();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _createSession() async {
    _timer?.cancel();
    setState(() {
      _loading = true;
      _message = '正在生成登录二维码…';
    });
    try {
      final session = await BilibiliAuthService.instance.createQrSession();
      if (!mounted) return;
      setState(() {
        _session = session;
        _loading = false;
        _message = '请使用手机哔哩哔哩扫码';
      });
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _message = error.toString();
        });
      }
    }
  }

  Future<void> _poll() async {
    final session = _session;
    if (session == null || _polling) return;
    _polling = true;
    try {
      final status = await BilibiliAuthService.instance.poll(session);
      if (!mounted) return;
      if (status.state == BilibiliQrState.confirmed) {
        _timer?.cancel();
        Navigator.pop(context, BilibiliAuthService.instance.account);
        return;
      }
      if (status.state == BilibiliQrState.expired) _timer?.cancel();
      setState(() => _message = status.message ?? '请使用手机哔哩哔哩扫码');
    } on Object catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      _polling = false;
    }
  }

  Future<void> _openBilibili() async {
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse('bilibili://root'),
        mode: LaunchMode.externalApplication,
      );
    } on Object {
      opened = false;
    }
    if (!opened) {
      await launchUrl(
        Uri.parse('https://www.bilibili.com/'),
        mode: LaunchMode.externalApplication,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.qr_code_2_rounded, color: Color(0xFFFF6699)),
          SizedBox(width: 10),
          Text('B站扫码登录'),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_loading)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 228),
                child: const AspectRatio(
                  aspectRatio: 1,
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else if (session != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 228),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: ColoredBox(
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: QrImageView(
                        data: session.url,
                        version: QrVersions.auto,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Text(_message, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              '会话仅保存在本机加密存储，不上传账号密码。',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: context.palette.textMuted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _openBilibili,
          icon: const Icon(Icons.open_in_new_rounded),
          label: const Text('打开哔哩哔哩'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton.icon(
          onPressed: _loading ? null : _createSession,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('刷新二维码'),
        ),
      ],
    );
  }
}

IconData _kindIcon(AssetKind kind) => switch (kind) {
  AssetKind.video => Icons.movie_outlined,
  AssetKind.audio => Icons.graphic_eq_rounded,
  AssetKind.image => Icons.image_outlined,
};

String _kindLabel(AssetKind kind) => switch (kind) {
  AssetKind.video => '视频',
  AssetKind.audio => '音频',
  AssetKind.image => '封面 / 图片',
};

String _duration(int total) {
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

String _speed(double bytesPerSecond) {
  final megabytes = bytesPerSecond / 1024 / 1024;
  return megabytes >= 1
      ? '${megabytes.toStringAsFixed(1)} MB/s'
      : '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
}
