import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/douyin_session_service.dart';
import '../theme/langbai_theme.dart';

class DouyinLoginPage extends StatefulWidget {
  const DouyinLoginPage({super.key});

  @override
  State<DouyinLoginPage> createState() => _DouyinLoginPageState();
}

class _DouyinLoginPageState extends State<DouyinLoginPage> {
  InAppWebViewController? _controller;
  WebViewEnvironment? _environment;
  bool _preparing = true;
  bool _checking = false;
  double _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final environment = await DouyinSessionService.instance.prepareWebView();
      if (!mounted) return;
      setState(() {
        _environment = environment;
        _preparing = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  Future<void> _finishLogin() async {
    final controller = _controller;
    if (controller == null || _checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final captured = await DouyinSessionService.instance.capture(controller);
      if (!mounted) return;
      if (captured) {
        Navigator.pop(context, true);
      } else {
        setState(() => _error = '尚未检测到抖音登录会话，请完成登录后再点“登录完成”');
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = '读取登录会话失败：$error');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  bool _isAllowedNavigation(WebUri? url) {
    if (url == null) return true;
    if (!{'http', 'https'}.contains(url.scheme.toLowerCase())) return false;
    final host = url.host.toLowerCase();
    return host == 'douyin.com' ||
        host.endsWith('.douyin.com') ||
        host == 'iesdouyin.com' ||
        host.endsWith('.iesdouyin.com');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('抖音登录'),
        actions: [
          TextButton(
            onPressed: _checking ? null : _finishLogin,
            child: _checking
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('登录完成'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: context.palette.navigationSelected,
            child: const Text('请在下方抖音官方页面完成登录。langbai解析只保存解析所需会话，不保存账号密码。'),
          ),
          if (_progress > 0 && _progress < 1)
            LinearProgressIndicator(value: _progress),
          if (_error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: Theme.of(context).colorScheme.errorContainer,
              child: Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          Expanded(
            child: _preparing
                ? const Center(child: CircularProgressIndicator())
                : _error != null && _controller == null
                ? Center(
                    child: FilledButton.icon(
                      onPressed: _prepare,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重试'),
                    ),
                  )
                : InAppWebView(
                    webViewEnvironment: _environment,
                    initialUrlRequest: URLRequest(
                      url: WebUri('https://www.douyin.com/'),
                    ),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      thirdPartyCookiesEnabled: true,
                      useShouldOverrideUrlLoading: true,
                      mediaPlaybackRequiresUserGesture: true,
                      supportMultipleWindows: false,
                    ),
                    onWebViewCreated: (controller) {
                      _controller = controller;
                    },
                    onProgressChanged: (_, progress) {
                      if (mounted) setState(() => _progress = progress / 100);
                    },
                    shouldOverrideUrlLoading: (_, action) async =>
                        _isAllowedNavigation(action.request.url)
                        ? NavigationActionPolicy.ALLOW
                        : NavigationActionPolicy.CANCEL,
                    onCreateWindow: (controller, action) async {
                      final url = action.request.url;
                      if (_isAllowedNavigation(url)) {
                        await controller.loadUrl(urlRequest: action.request);
                      }
                      return false;
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
