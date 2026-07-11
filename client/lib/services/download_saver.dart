import 'download_saver_stub.dart'
    if (dart.library.io) 'download_saver_io.dart'
    if (dart.library.html) 'download_saver_web.dart'
    as implementation;
import 'download_types.dart';

export 'download_types.dart';

Future<SaveResult> saveDownload(
  Uri uri,
  String filename,
  DownloadProgress onProgress, {
  SaveDestination destination = SaveDestination.files,
  String mediaType = 'file',
  Map<String, String> headers = const {},
  bool Function()? isCancelled,
  String? customDestinationUri,
  TransferProgressCallback? onTransferProgress,
}) {
  return implementation.saveDownload(
    uri,
    filename,
    onProgress,
    destination: destination,
    mediaType: mediaType,
    headers: headers,
    isCancelled: isCancelled,
    customDestinationUri: customDestinationUri,
    onTransferProgress: onTransferProgress,
  );
}
