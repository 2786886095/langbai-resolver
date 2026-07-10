import 'dart:io';
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'download_types.dart';

Future<SaveResult> saveDownload(
  Uri uri,
  String filename,
  DownloadProgress onProgress,
) async {
  late final File target;
  final isMobile = Platform.isAndroid || Platform.isIOS;
  if (isMobile) {
    final directory = await getApplicationDocumentsDirectory();
    target = File('${directory.path}${Platform.pathSeparator}$filename');
  } else {
    final location = await getSaveLocation(suggestedName: filename);
    if (location == null) {
      return const SaveResult(message: '已取消保存', cancelled: true);
    }
    target = File(location.path);
  }

  final request = http.Request('GET', uri);
  final response = await http.Client().send(request);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw HttpException('文件下载失败（${response.statusCode}）', uri: uri);
  }
  final total = response.contentLength;
  var received = 0;
  final sink = target.openWrite();
  try {
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total != null && total > 0) {
        onProgress((received / total).clamp(0, 1));
      }
    }
  } finally {
    await sink.close();
  }
  onProgress(1);

  if (isMobile) {
    await Share.shareXFiles(
      [XFile(target.path)],
      subject: filename,
      text: '保存或分享 $filename',
      sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
    );
    return SaveResult(
      message: Platform.isIOS ? '文件已下载，可在系统面板中选择“存储到文件”' : '文件已下载，可从系统面板保存或分享',
      path: target.path,
    );
  }
  return SaveResult(message: '文件已保存', path: target.path);
}
