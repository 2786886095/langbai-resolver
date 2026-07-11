import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_harbor/models/download_record.dart';
import 'package:media_harbor/models/media_models.dart';
import 'package:media_harbor/pages/downloads_page.dart';
import 'package:media_harbor/theme/langbai_theme.dart';

void main() {
  const record = DownloadRecord(
    job: DownloadJob(
      id: 'job-progress-123',
      state: JobState.running,
      progress: 0.5,
      downloadedBytes: 5 * 1024 * 1024,
      totalBytes: 10 * 1024 * 1024,
      speedBytesPerSecond: 2 * 1024 * 1024,
      etaSeconds: 3,
    ),
    title: '一个很长但仍应安全截断的下载视频标题，用于验证小屏布局',
    optionLabel: '1080p · MP4',
    platform: '测试平台',
    sourceUrl: 'https://example.com/watch/1',
  );

  testWidgets('shows bytes, total and live speed for a running download', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LangbaiTheme.light(),
        home: Scaffold(
          body: DownloadsPage(
            records: const [record],
            onClear: () {},
            onRetry: (_) {},
          ),
        ),
      ),
    );

    expect(find.textContaining('5.0 MB / 10.0 MB'), findsOneWidget);
    expect(find.textContaining('2.0 MB/s'), findsOneWidget);
    expect(find.textContaining('约 3s'), findsOneWidget);
  });

  testWidgets('download rows fit a narrow phone at 200 percent text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      MaterialApp(
        theme: LangbaiTheme.light(),
        home: Scaffold(
          body: DownloadsPage(
            records: const [record],
            onClear: () {},
            onRetry: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('5.0 MB / 10.0 MB'), findsOneWidget);
  });
}
