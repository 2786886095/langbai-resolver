import 'download_types.dart';

Future<SaveResult> saveDownload(
  Uri uri,
  String filename,
  DownloadProgress onProgress,
) {
  throw UnsupportedError('当前平台暂不支持文件保存');
}
