import 'package:flutter_test/flutter_test.dart';
import 'package:media_harbor/models/media_models.dart';
import 'package:media_harbor/services/download_types.dart';

void main() {
  test('image-only media keeps real per-option previews and no video kind', () {
    final media = MediaInfo.fromJson({
      'media_id': 'media-12345678',
      'source_url': 'https://example.com/post',
      'title': '图片作品',
      'platform': 'Example',
      'thumbnail_url': 'https://cdn.example.com/cover.jpg',
      'options': [
        {
          'id': 'image:1',
          'kind': 'image',
          'label': '图片 1',
          'extension': 'jpg',
          'preview_url': 'https://cdn.example.com/one.jpg',
        },
        {
          'id': 'image:2',
          'kind': 'image',
          'label': '图片 2',
          'extension': 'jpg',
          'preview_url': 'https://cdn.example.com/two.jpg',
        },
      ],
      'warnings': <String>[],
    });

    expect(media.onlyImages, isTrue);
    expect(media.hasVideo, isFalse);
    expect(media.availableKinds, [AssetKind.image]);
    expect(media.options[1].previewUrl, 'https://cdn.example.com/two.jpg');
  });

  test('unknown media kind fails instead of being invented as video', () {
    expect(
      () => MediaOption.fromJson({
        'id': 'document:1',
        'kind': 'document',
        'label': '文档',
        'extension': 'bin',
      }),
      throwsFormatException,
    );
  });

  test('download job accepts and persists byte and speed metrics', () {
    final job = DownloadJob.fromJson({
      'id': 'job-12345678',
      'state': 'running',
      'progress': 0.5,
      'downloaded_bytes': 5 * 1024 * 1024,
      'total_bytes': 10 * 1024 * 1024,
      'speed_bytes_per_second': 2.5 * 1024 * 1024,
      'average_speed_bytes_per_second': 2 * 1024 * 1024,
      'eta_seconds': 2,
    });

    final restored = DownloadJob.fromJson(job.toJson());
    expect(restored.downloadedBytes, 5 * 1024 * 1024);
    expect(restored.totalBytes, 10 * 1024 * 1024);
    expect(restored.speedBytesPerSecond, 2.5 * 1024 * 1024);
    expect(restored.averageSpeedBytesPerSecond, 2 * 1024 * 1024);
    expect(restored.etaSeconds, 2);
  });

  test('server completion stays pending until device publication succeeds', () {
    const serverCompleted = DownloadJob(
      id: 'job-publication',
      state: JobState.completed,
      progress: 1,
      filename: 'output.mp4',
      downloadedBytes: 1024,
      totalBytes: 1024,
    );

    final pending = serverCompleted.waitingForPublication();
    expect(pending.state, JobState.running);
    expect(pending.progress, 0);
    expect(pending.filename, serverCompleted.filename);
    expect(pending.totalBytes, serverCompleted.totalBytes);

    final failed = pending.terminalFailure('相册发布失败');
    expect(failed.state, JobState.failed);
    expect(failed.error, '相册发布失败');
    expect(failed.terminalFailure('不应覆盖的后续状态', cancelled: true), same(failed));
  });

  test('tool output filename maps to the native save media contract', () {
    expect(mediaTypeFromFilename('converted.MP4'), 'video');
    expect(mediaTypeFromFilename('poster.avif'), 'image');
    expect(mediaTypeFromFilename('track.flac'), 'audio');
    expect(mediaTypeFromFilename('archive.bin'), 'file');
    expect(mediaTypeFromFilename(null), 'file');
  });
}
