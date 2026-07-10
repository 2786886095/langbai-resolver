class SaveResult {
  const SaveResult({required this.message, this.path, this.cancelled = false});

  final String message;
  final String? path;
  final bool cancelled;
}

enum SaveDestination { files, gallery }

typedef DownloadProgress = void Function(double progress);
