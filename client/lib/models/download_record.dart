import 'media_models.dart';

class DownloadRecord {
  const DownloadRecord({
    required this.job,
    required this.title,
    required this.optionLabel,
    required this.platform,
    required this.sourceUrl,
  });

  factory DownloadRecord.fromJson(Map<String, dynamic> json) => DownloadRecord(
    job: DownloadJob.fromJson((json['job'] as Map).cast<String, dynamic>()),
    title: json['title']?.toString() ?? '下载任务',
    optionLabel: json['option_label']?.toString() ?? '媒体资源',
    platform: json['platform']?.toString() ?? '未知平台',
    sourceUrl: json['source_url']?.toString() ?? '',
  );

  final DownloadJob job;
  final String title;
  final String optionLabel;
  final String platform;
  final String sourceUrl;

  DownloadRecord copyWith({DownloadJob? job}) => DownloadRecord(
    job: job ?? this.job,
    title: title,
    optionLabel: optionLabel,
    platform: platform,
    sourceUrl: sourceUrl,
  );

  Map<String, dynamic> toJson() => {
    'job': job.toJson(),
    'title': title,
    'option_label': optionLabel,
    'platform': platform,
    'source_url': sourceUrl,
  };
}
