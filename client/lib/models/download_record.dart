import 'media_models.dart';

class DownloadRecord {
  const DownloadRecord({
    required this.job,
    required this.title,
    required this.optionLabel,
    required this.platform,
  });

  final DownloadJob job;
  final String title;
  final String optionLabel;
  final String platform;

  DownloadRecord copyWith({DownloadJob? job}) => DownloadRecord(
        job: job ?? this.job,
        title: title,
        optionLabel: optionLabel,
        platform: platform,
      );
}
