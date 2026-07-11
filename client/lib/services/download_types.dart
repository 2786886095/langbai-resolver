class SaveResult {
  const SaveResult({required this.message, this.path, this.cancelled = false});

  final String message;
  final String? path;
  final bool cancelled;
}

enum SaveDestination { files, gallery, custom }

SaveDestination saveDestinationFromName(String? value) =>
    SaveDestination.values.firstWhere(
      (destination) => destination.name == value,
      orElse: () => SaveDestination.files,
    );

String mediaTypeFromFilename(String? filename) {
  final value = filename?.trim().toLowerCase() ?? '';
  final withoutQuery = value.split(RegExp(r'[?#]')).first;
  final separator = withoutQuery.lastIndexOf('.');
  final extension = separator < 0 ? '' : withoutQuery.substring(separator + 1);
  if (_imageExtensions.contains(extension)) return 'image';
  if (_videoExtensions.contains(extension)) return 'video';
  if (_audioExtensions.contains(extension)) return 'audio';
  return 'file';
}

class TransferProgress {
  const TransferProgress({
    required this.progress,
    this.downloadedBytes,
    this.totalBytes,
    this.speedBytesPerSecond,
    this.averageSpeedBytesPerSecond,
    this.etaSeconds,
    this.status,
  });

  final double progress;
  final int? downloadedBytes;
  final int? totalBytes;
  final double? speedBytesPerSecond;
  final double? averageSpeedBytesPerSecond;
  final int? etaSeconds;
  final String? status;
}

typedef DownloadProgress = void Function(double progress);
typedef TransferProgressCallback = void Function(TransferProgress progress);

const _imageExtensions = {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'avif',
  'gif',
  'bmp',
  'heic',
  'heif',
};
const _videoExtensions = {'mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi'};
const _audioExtensions = {
  'mp3',
  'm4a',
  'aac',
  'flac',
  'wav',
  'ogg',
  'opus',
  'wma',
  'aiff',
};
