class UpdatePlatformRelease {
  const UpdatePlatformRelease({
    required this.url,
    this.sha256 = '',
  });

  factory UpdatePlatformRelease.fromJson(Map<String, dynamic> json) {
    return UpdatePlatformRelease(
      url: json['url']?.toString().trim() ?? '',
      sha256: json['sha256']?.toString().trim() ?? '',
    );
  }

  final String url;
  final String sha256;
}

class UpdateManifest {
  const UpdateManifest({
    required this.version,
    required this.notes,
    required this.publishedAt,
    required this.platforms,
  });

  factory UpdateManifest.fromJson(Map<String, dynamic> json) {
    final rawPlatforms = json['platforms'];
    final platforms = <String, UpdatePlatformRelease>{};
    if (rawPlatforms is Map<String, dynamic>) {
      for (final entry in rawPlatforms.entries) {
        if (entry.value is Map<String, dynamic>) {
          platforms[entry.key.toLowerCase()] = UpdatePlatformRelease.fromJson(
              entry.value as Map<String, dynamic>);
        }
      }
    }
    return UpdateManifest(
      version: json['version']?.toString().trim() ?? '',
      notes: json['notes']?.toString().trim() ?? '',
      publishedAt: json['published_at']?.toString().trim() ?? '',
      platforms: platforms,
    );
  }

  final String version;
  final String notes;
  final String publishedAt;
  final Map<String, UpdatePlatformRelease> platforms;

  UpdatePlatformRelease? releaseFor(String platform) =>
      platforms[platform.toLowerCase()];
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.manifest,
    required this.platform,
    required this.release,
    required this.hasUpdate,
  });

  final UpdateManifest manifest;
  final String platform;
  final UpdatePlatformRelease? release;
  final bool hasUpdate;
}
