import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:http/http.dart' as http;

import '../models/media_models.dart';

class ApiException implements Exception {
  const ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient(String baseUrl)
      : baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

  final String baseUrl;
  final http.Client _client = http.Client();

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<MediaInfo> resolve(String url) async {
    final response = await _client
        .post(
          _uri('/api/v1/resolve'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'url': url}),
        )
        .timeout(const Duration(seconds: 75));
    return MediaInfo.fromJson(_jsonOrThrow(response));
  }

  Future<DownloadJob> createJob(String mediaId, String optionId) async {
    final response = await _client
        .post(
          _uri('/api/v1/jobs'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'media_id': mediaId, 'option_id': optionId}),
        )
        .timeout(const Duration(seconds: 20));
    return DownloadJob.fromJson(_jsonOrThrow(response));
  }

  Future<DownloadJob> getJob(String jobId) async {
    final response = await _client
        .get(_uri('/api/v1/jobs/$jobId'))
        .timeout(const Duration(seconds: 20));
    return DownloadJob.fromJson(_jsonOrThrow(response));
  }

  Uri fileUri(String jobId) => _uri('/api/v1/jobs/$jobId/file');

  Future<DownloadJob> createToolJob({
    required XFile file,
    required String operation,
    String outputFormat = '',
    int quality = 78,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/api/v1/tools/process'))
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
    final streamed =
        await _client.send(request).timeout(const Duration(minutes: 10));
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
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'sources': sources}),
        )
        .timeout(const Duration(seconds: 20));
    return DownloadJob.fromJson(_jsonOrThrow(response));
  }

  Future<DownloadJob> createTorrentFile(XFile file) async {
    final request =
        http.MultipartRequest('POST', _uri('/api/v1/tools/torrent'));
    final length = await file.length();
    request.files.add(
      http.MultipartFile(
        'file',
        http.ByteStream(file.openRead()),
        length,
        filename: file.name,
      ),
    );
    final streamed =
        await _client.send(request).timeout(const Duration(minutes: 2));
    final response = await http.Response.fromStream(streamed);
    return DownloadJob.fromJson(_jsonOrThrow(response));
  }

  Future<SniffResult> sniff(String url) async {
    final response = await _client
        .post(
          _uri('/api/v1/sniff'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'url': url}),
        )
        .timeout(const Duration(seconds: 50));
    return SniffResult.fromJson(_jsonOrThrow(response));
  }

  Future<List<MusicSearchResult>> searchMusic(String query) async {
    final response = await _client
        .get(_uri('/api/v1/music/search?q=${Uri.encodeQueryComponent(query)}'))
        .timeout(const Duration(seconds: 40));
    final data = _listOrThrow(response);
    return data
        .map((item) => MusicSearchResult.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<List<MusicFile>> musicFiles(String identifier) async {
    final response = await _client
        .get(_uri('/api/v1/music/${Uri.encodeComponent(identifier)}/files'))
        .timeout(const Duration(seconds: 40));
    final data = _listOrThrow(response);
    return data
        .map((item) => MusicFile.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
  }

  Map<String, dynamic> _jsonOrThrow(http.Response response) {
    Map<String, dynamic> data;
    try {
      data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } on Object {
      throw ApiException('服务器返回了无法识别的响应（${response.statusCode}）');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = data['detail'];
      throw ApiException(detail?.toString() ?? '请求失败（${response.statusCode}）');
    }
    return data;
  }

  List<dynamic> _listOrThrow(http.Response response) {
    dynamic data;
    try {
      data = jsonDecode(utf8.decode(response.bodyBytes));
    } on Object {
      throw ApiException('服务器返回了无法识别的响应（${response.statusCode}）');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = data is Map<String, dynamic> ? data['detail'] : null;
      throw ApiException(detail?.toString() ?? '请求失败（${response.statusCode}）');
    }
    if (data is! List<dynamic>) {
      throw const ApiException('服务器返回的列表格式不正确');
    }
    return data;
  }

  void close() => _client.close();
}
