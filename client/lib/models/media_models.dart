enum AssetKind { video, audio, image }

AssetKind assetKindFromJson(String value) {
  return AssetKind.values.firstWhere(
    (kind) => kind.name == value,
    orElse: () => AssetKind.video,
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
}

enum JobState { queued, running, completed, failed }

class DownloadJob {
  const DownloadJob({
    required this.id,
    required this.state,
    required this.progress,
    this.filename,
    this.error,
    this.speedBytesPerSecond,
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
      speedBytesPerSecond: (json['speed_bytes_per_second'] as num?)?.toDouble(),
      etaSeconds: (json['eta_seconds'] as num?)?.toInt(),
      downloadUrl: json['download_url'] as String?,
    );
  }

  final String id;
  final JobState state;
  final double progress;
  final String? filename;
  final String? error;
  final double? speedBytesPerSecond;
  final int? etaSeconds;
  final String? downloadUrl;
}

class MusicSearchResult {
  const MusicSearchResult({
    required this.identifier,
    required this.title,
    required this.itemUrl,
    this.creator,
    this.year,
  });

  factory MusicSearchResult.fromJson(Map<String, dynamic> json) {
    return MusicSearchResult(
      identifier: json['identifier'] as String,
      title: json['title'] as String,
      itemUrl: json['item_url'] as String,
      creator: json['creator'] as String?,
      year: json['year'] as String?,
    );
  }

  final String identifier;
  final String title;
  final String itemUrl;
  final String? creator;
  final String? year;
}

class MusicFile {
  const MusicFile({
    required this.name,
    required this.format,
    required this.downloadUrl,
    this.size,
  });

  factory MusicFile.fromJson(Map<String, dynamic> json) {
    return MusicFile(
      name: json['name'] as String,
      format: json['format'] as String,
      downloadUrl: json['download_url'] as String,
      size: (json['size'] as num?)?.toInt(),
    );
  }

  final String name;
  final String format;
  final String downloadUrl;
  final int? size;
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
