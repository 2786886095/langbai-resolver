import 'package:flutter_test/flutter_test.dart';
import 'package:media_harbor/models/download_record.dart';
import 'package:media_harbor/models/media_models.dart';

void main() {
  test('persists download history and cancelled state', () {
    const record = DownloadRecord(
      job: DownloadJob(
        id: 'job-12345678',
        state: JobState.cancelled,
        progress: 0.42,
        error: '用户已取消',
      ),
      title: '测试视频',
      optionLabel: '1080p · AVC',
      platform: 'BiliBili',
      sourceUrl: 'https://www.bilibili.com/video/BV1example',
    );

    final restored = DownloadRecord.fromJson(record.toJson());

    expect(restored.job.state, JobState.cancelled);
    expect(restored.job.progress, 0.42);
    expect(restored.job.error, '用户已取消');
    expect(restored.sourceUrl, record.sourceUrl);
    expect(restored.optionLabel, record.optionLabel);
  });
}
