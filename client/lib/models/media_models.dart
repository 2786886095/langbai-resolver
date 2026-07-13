enum AssetKind { video, audio, image }

AssetKind assetKindFromJson(String value) {
  return AssetKind.values.firstWhere(
    (kind) => kind.name == value,
    orElse: () => throw FormatException('未知媒体类型：$value'),
  );
}

class MediaOption {
  const MediaOption({
    required this.id,
    required this.kind,
    required this.label,
    required this.extension,
    this.resolution,
    this.bitrateKbps,
    this.fps,
    this.filesize,
    this.filesizeLabel,
    this.previewUrl,
    this.requiresMerge = false,
  });

  factory MediaOption.fromJson(Map<String, dynamic> json) {
    return MediaOption(
      id: json['id'] as String,
      kind: assetKindFromJson(json['kind'] as String),
      label: json['label'] as String,
      extension: json['extension'] as String,
      resolution: json['resolution'] as String?,
      bitrateKbps: (json['bitrate_kbps'] as num?)?.toInt(),
      fps: (json['fps'] as num?)?.toDouble(),
      filesize: (json['filesize'] as num?)?.toInt(),
      filesizeLabel: json['filesize_label'] as String?,
      previewUrl: json['preview_url']?.toString(),
      requiresMerge: json['requires_merge'] as bool? ?? false,
    );
  }

  final String id;
  final AssetKind kind;
  final String label;
  final String extension;
  final String? resolution;
  final int? bitrateKbps;
  final double? fps;
  final int? filesize;
  final String? filesizeLabel;
  final String? previewUrl;
  final bool requiresMerge;
}

class MediaInfo {
  const MediaInfo({
    required this.mediaId,
    required this.sourceUrl,
    required this.title,
    required this.platform,
    required this.options,
    required this.warnings,
    this.creator,
    this.durationSeconds,
    this.thumbnailUrl,
  });

  factory MediaInfo.fromJson(Map<String, dynamic> json) {
    return MediaInfo(
      mediaId: json['media_id'] as String,
      sourceUrl: json['source_url'] as String,
      title: json['title'] as String,
      creator: json['creator'] as String?,
      platform: json['platform'] as String,
      durationSeconds: (json['duration_seconds'] as num?)?.toInt(),
      thumbnailUrl: json['thumbnail_url'] as String?,
      options: (json['options'] as List<dynamic>)
          .map((item) => MediaOption.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
      warnings: (json['warnings'] as List<dynamic>? ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
    );
  }

  final String mediaId;
  final String sourceUrl;
  final String title;
  final String? creator;
  final String platform;
  final int? durationSeconds;
  final String? thumbnailUrl;
  final List<MediaOption> options;
  final List<String> warnings;

  List<AssetKind> get availableKinds => AssetKind.values
      .where((kind) => options.any((option) => option.kind == kind))
      .toList(growable: false);

  bool get hasVideo => options.any((option) => option.kind == AssetKind.video);
  bool get onlyImages =>
      options.isNotEmpty &&
      options.every((option) => option.kind == AssetKind.image);
}

enum JobState { queued, running, completed, failed, cancelled }

class DownloadJob {
  const DownloadJob({
    required this.id,
    required this.state,
    required this.progress,
    this.filename,
    this.error,
    this.downloadedBytes,
    this.totalBytes,
    this.speedBytesPerSecond,
    this.averageSpeedBytesPerSecond,
    this.etaSeconds,
    this.downloadUrl,
  });

  factory DownloadJob.fromJson(Map<String, dynamic> json) {
    return DownloadJob(
      id: json['id'] as String,
      state: JobState.values.firstWhere(
        (state) => state.name == json['state'],
        orElse: () => JobState.failed,
      ),
      progress: (json['progress'] as num? ?? 0).toDouble(),
      filename: json['filename'] as String?,
      error: json['error'] as String?,
      downloadedBytes: _intFromJson(
        json['downloaded_bytes'] ?? json['bytes_downloaded'],
      ),
      totalBytes: _intFromJson(json['total_bytes'] ?? json['bytes_total']),
      speedBytesPerSecond: (json['speed_bytes_per_second'] as num?)?.toDouble(),
      averageSpeedBytesPerSecond:
          (json['average_speed_bytes_per_second'] as num?)?.toDouble(),
      etaSeconds: (json['eta_seconds'] as num?)?.toInt(),
      downloadUrl: json['download_url'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'state': state.name,
        'progress': progress,
        if (filename != null) 'filename': filename,
        if (error != null) 'error': error,
        if (downloadedBytes != null) 'downloaded_bytes': downloadedBytes,
        if (totalBytes != null) 'total_bytes': totalBytes,
        if (speedBytesPerSecond != null)
          'speed_bytes_per_second': speedBytesPerSecond,
        if (averageSpeedBytesPerSecond != null)
          'average_speed_bytes_per_second': averageSpeedBytesPerSecond,
        if (etaSeconds != null) 'eta_seconds': etaSeconds,
        if (downloadUrl != null) 'download_url': downloadUrl,
      };

  final String id;
  final JobState state;
  final double progress;
  final String? filename;
  final String? error;
  final int? downloadedBytes;
  final int? totalBytes;
  final double? speedBytesPerSecond;
  final double? averageSpeedBytesPerSecond;
  final int? etaSeconds;
  final String? downloadUrl;

  DownloadJob copyWith({
    JobState? state,
    double? progress,
    String? filename,
    String? error,
    int? downloadedBytes,
    int? totalBytes,
    double? speedBytesPerSecond,
    double? averageSpeedBytesPerSecond,
    int? etaSeconds,
    String? downloadUrl,
  }) =>
      DownloadJob(
        id: id,
        state: state ?? this.state,
        progress: progress ?? this.progress,
        filename: filename ?? this.filename,
        error: error ?? this.error,
        downloadedBytes: downloadedBytes ?? this.downloadedBytes,
        totalBytes: totalBytes ?? this.totalBytes,
        speedBytesPerSecond: speedBytesPerSecond ?? this.speedBytesPerSecond,
        averageSpeedBytesPerSecond:
            averageSpeedBytesPerSecond ?? this.averageSpeedBytesPerSecond,
        etaSeconds: etaSeconds ?? this.etaSeconds,
        downloadUrl: downloadUrl ?? this.downloadUrl,
      );

  DownloadJob waitingForPublication() =>
      copyWith(state: JobState.running, progress: 0);

  DownloadJob terminalFailure(String message, {bool cancelled = false}) {
    if (state == JobState.failed || state == JobState.cancelled) return this;
    return copyWith(
      state: cancelled ? JobState.cancelled : JobState.failed,
      error: message,
    );
  }
}

int? _intFromJson(Object? value) => switch (value) {
      final int number => number,
      final num number => number.toInt(),
      final String text => int.tryParse(text),
      _ => null,
    };

class MusicSearchResult {
  const MusicSearchResult({
    required this.identifier,
    required this.title,
    required this.itemUrl,
    required this.source,
    required this.sourceLabel,
    required this.canDownload,
    this.creator,
    this.year,
    this.previewUrl,
    this.artworkUrl,
    this.album,
    this.durationSeconds,
    this.license,
  });

  factory MusicSearchResult.fromJson(Map<String, dynamic> json) {
    return MusicSearchResult(
      identifier: json['identifier'] as String,
      title: json['title'] as String,
      itemUrl: json['item_url'] as String,
      source: json['source']?.toString() ?? 'internet_archive',
      sourceLabel: json['source_label']?.toString() ?? 'Internet Archive',
      canDownload: json['can_download'] == true,
      creator: json['creator'] as String?,
      year: json['year'] as String?,
      previewUrl: json['preview_url'] as String?,
      artworkUrl: json['artwork_url'] as String?,
      album: json['album'] as String?,
      durationSeconds: (json['duration_seconds'] as num?)?.toInt(),
      license: json['license'] as String?,
    );
  }

  final String identifier;
  final String title;
  final String itemUrl;
  final String source;
  final String sourceLabel;
  final bool canDownload;
  final String? creator;
  final String? year;
  final String? previewUrl;
  final String? artworkUrl;
  final String? album;
  final int? durationSeconds;
  final String? license;
}

class MusicFile {
  const MusicFile({
    required this.name,
    required this.format,
    required this.downloadUrl,
    this.size,
    this.bitrate,
    this.sampleRate,
  });

  factory MusicFile.fromJson(Map<String, dynamic> json) {
    return MusicFile(
      name: json['name'] as String,
      format: json['format'] as String,
      downloadUrl: json['download_url'] as String,
      size: (json['size'] as num?)?.toInt(),
      bitrate: (json['bitrate'] as num?)?.toInt(),
      sampleRate: (json['sample_rate'] as num?)?.toInt(),
    );
  }

  final String name;
  final String format;
  final String downloadUrl;
  final int? size;
  final int? bitrate;
  final int? sampleRate;
}

class SniffedResource {
  const SniffedResource({
    required this.url,
    required this.kind,
    required this.source,
    this.extension,
  });

  factory SniffedResource.fromJson(Map<String, dynamic> json) {
    return SniffedResource(
      url: json['url'] as String,
      kind: json['kind'] as String,
      source: json['source'] as String,
      extension: json['extension'] as String?,
    );
  }

  final String url;
  final String kind;
  final String source;
  final String? extension;
}

class SniffResult {
  const SniffResult({
    required this.pageUrl,
    required this.resources,
    required this.warnings,
    this.title,
  });

  factory SniffResult.fromJson(Map<String, dynamic> json) {
    return SniffResult(
      pageUrl: json['page_url'] as String,
      title: json['title'] as String?,
      resources: (json['resources'] as List<dynamic>)
          .map((item) => SniffedResource.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
      warnings: (json['warnings'] as List<dynamic>? ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
    );
  }

  final String pageUrl;
  final String? title;
  final List<SniffedResource> resources;
  final List<String> warnings;
}
