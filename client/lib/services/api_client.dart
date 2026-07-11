import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:http/http.dart' as http;

import '../models/media_models.dart';
import 'api_endpoint_policy.dart';
import 'runtime_environment.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient(String baseUrl, {String? instanceToken, http.Client? client})
    : _client = _NoRedirectClient(client ?? http.Client()),
      baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
      _instanceToken = selectInstanceTokenForApi(
        baseUrl,
        explicitToken: instanceToken,
        runtimeToken: langbaiInstanceToken,
      );

  final String baseUrl;
  final String _instanceToken;
  final http.Client _client;

  Map<String, String> get _headers => {
    if (_instanceToken.isNotEmpty) 'X-Langbai-Instance-Token': _instanceToken,
  };

  Map<String, String> get downloadHeaders => Map.unmodifiable(_headers);

  Map<String, String> _jsonHeaders() => {
    ..._headers,
    'content-type': 'application/json',
  };

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<bool> isHealthy() async {
    try {
      final response = await _client
          .get(_uri('/api/v1/health'), headers: _headers)
          .timeout(const Duration(seconds: 3));
      return response.statusCode >= 200 && response.statusCode < 300;
    } on Object {
      return false;
    }
  }

  Future<MediaInfo> resolve(String url, {String? bilibiliCookie}) async {
    final response = await _client
        .post(
          _uri('/api/v1/resolve'),
          headers: _jsonHeaders(),
          body: jsonEncode({'url': url, 'bilibili_cookie': ?bilibiliCookie}),
        )
        .timeout(const Duration(seconds: 75));
    return MediaInfo.fromJson(_jsonOrThrow(response));
  }

  Future<DownloadJob> createJob(String mediaId, String optionId) async {
    final response = await _client
        .post(
          _uri('/api/v1/jobs'),
          headers: _jsonHeaders(),
          body: jsonEncode({'media_id': mediaId, 'option_id': optionId}),
        )
        .timeout(const Duration(seconds: 20));
    return DownloadJob.fromJson(_jsonOrThrow(response));
  }

  Future<DownloadJob> getJob(String jobId) async {
    final response = await _client
        .get(_uri('/api/v1/jobs/$jobId'), headers: _headers)
        .timeout(const Duration(seconds: 20));
    return DownloadJob.fromJson(_jsonOrThrow(response));
  }

  Uri fileUri(String jobId) => _uri('/api/v1/jobs/$jobId/file');

  Future<DownloadJob> cancelJob(String jobId) async {
    final response = await _client
        .delete(_uri('/api/v1/jobs/$jobId'), headers: _headers)
        .timeout(const Duration(seconds: 20));
    return DownloadJob.fromJson(_jsonOrThrow(response));
  }

  Future<DownloadJob> createToolJob({
    required XFile file,
    required String operation,
    String outputFormat = '',
    int quality = 78,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/api/v1/tools/process'))
      ..headers.addAll(_headers)
      ..fields['operation'] = operation
      ..fields['output_format'] = outputFormat
      ..fields['quality'] = quality.toString();
    final length = await file.length();
    request.files.add(
      http.MultipartFile(
        'file',
        http.ByteStream(file.openRead()),
        length,
        filename: file.name,
      ),
    );
    final streamed = await _client
        .send(request)
        .timeout(const Duration(minutes: 10));
    final response = await http.Response.fromStream(streamed);
    return DownloadJob.fromJson(_jsonOrThrow(response));
  }

  Future<DownloadJob> createTransfer(String source) async {
    final sources = source
        .split(RegExp(r'[\r\n]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .take(8)
        .toList();
    final response = await _client
        .post(
          _uri('/api/v1/tools/transfer'),
          headers: _jsonHeaders(),
          body: jsonEncode({'sources': sources}),
        )
        .timeout(const Duration(seconds: 20));
    return DownloadJob.fromJson(_jsonOrThrow(response));
  }

  Future<DownloadJob> createTorrentFile(XFile file) async {
    final request = http.MultipartRequest('POST', _uri('/api/v1/tools/torrent'))
      ..headers.addAll(_headers);
    final length = await file.length();
    request.files.add(
      http.MultipartFile(
        'file',
        http.ByteStream(file.openRead()),
        length,
        filename: file.name,
      ),
    );
    final streamed = await _client
        .send(request)
        .timeout(const Duration(minutes: 2));
    final response = await http.Response.fromStream(streamed);
    return DownloadJob.fromJson(_jsonOrThrow(response));
  }

  Future<SniffResult> sniff(String url) async {
    final response = await _client
        .post(
          _uri('/api/v1/sniff'),
          headers: _jsonHeaders(),
          body: jsonEncode({'url': url}),
        )
        .timeout(const Duration(seconds: 50));
    return SniffResult.fromJson(_jsonOrThrow(response));
  }

  Future<List<MusicSearchResult>> searchMusic(String query) async {
    final response = await _client
        .get(
          _uri('/api/v1/music/search?q=${Uri.encodeQueryComponent(query)}'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 40));
    final data = _listOrThrow(response);
    return data
        .map((item) => MusicSearchResult.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<List<MusicFile>> musicFiles(String identifier) async {
    final response = await _client
        .get(
          _uri('/api/v1/music/${Uri.encodeComponent(identifier)}/files'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 40));
    final data = _listOrThrow(response);
    return data
        .map((item) => MusicFile.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  Map<String, dynamic> _jsonOrThrow(http.Response response) {
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw const ApiException('服务端返回了重定向；为保护访问令牌，客户端不会跟随跳转');
    }
    Map<String, dynamic> data;
    try {
      data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } on Object {
      throw ApiException('服务器返回了无法识别的响应（${response.statusCode}）');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _apiException(data, response.statusCode);
    }
    return data;
  }

  List<dynamic> _listOrThrow(http.Response response) {
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw const ApiException('服务端返回了重定向；为保护访问令牌，客户端不会跟随跳转');
    }
    dynamic data;
    try {
      data = jsonDecode(utf8.decode(response.bodyBytes));
    } on Object {
      throw ApiException('服务器返回了无法识别的响应（${response.statusCode}）');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _apiException(data, response.statusCode);
    }
    if (data is! List<dynamic>) {
      throw const ApiException('服务器返回的列表格式不正确');
    }
    return data;
  }

  void close() => _client.close();
}

class _NoRedirectClient extends http.BaseClient {
  _NoRedirectClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.followRedirects = false;
    request.maxRedirects = 0;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

ApiException _apiException(Object? data, int statusCode) {
  final detail = data is Map<String, dynamic> ? data['detail'] : null;
  if (detail is Map) {
    return ApiException(
      detail['message']?.toString() ?? '请求失败（$statusCode）',
      code: detail['code']?.toString(),
    );
  }
  return ApiException(detail?.toString() ?? '请求失败（$statusCode）');
}
