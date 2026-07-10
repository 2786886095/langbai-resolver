import 'package:url_launcher/url_launcher.dart';

import 'download_types.dart';

Future<SaveResult> saveDownload(
  Uri uri,
  String filename,
  DownloadProgress onProgress,
) async {
  final opened = await launchUrl(
    uri,
    mode: LaunchMode.externalApplication,
    webOnlyWindowName: '_blank',
  );
  if (!opened) {
    throw StateError('浏览器无法打开下载链接');
  }
  onProgress(1);
  return const SaveResult(message: '浏览器下载已开始');
}
