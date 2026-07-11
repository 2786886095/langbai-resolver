import 'download_types.dart';

Future<SaveResult> saveDownload(
  Uri uri,
  String filename,
  DownloadProgress onProgress, {
  SaveDestination destination = SaveDestination.files,
  String mediaType = 'file',
  Map<String, String> headers = const {},
  bool Function()? isCancelled,
}) {
  throw UnsupportedError('当前平台暂不支持文件保存');
}
