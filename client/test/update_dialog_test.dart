import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_harbor/screens/app_shell.dart';
import 'package:media_harbor/services/update_models.dart';
import 'package:media_harbor/theme/langbai_theme.dart';

void main() {
  testWidgets('long update notes scroll on a 320px phone at 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    const release = UpdatePlatformRelease(
      url: 'https://example.com/app.apk',
      sha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      sizeBytes: 1024,
    );
    final result = UpdateCheckResult(
      manifest: UpdateManifest(
        version: '9.9.9',
        notes: List<String>.filled(
          18,
          '这是一段很长的更新说明，用于验证小屏幕和大字体下仍然可以完整滚动阅读。',
        ).join('\n'),
        publishedAt: '2026-07-11T00:00:00Z',
        platforms: const {'android': release},
      ),
      platform: 'android',
      release: release,
      hasUpdate: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: LangbaiTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (dialogContext) => UpdateAvailableDialog(
                  result: result,
                  onDismiss: () => Navigator.pop(dialogContext),
                  onInstall: () {},
                ),
              ),
              child: const Text('显示更新'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('显示更新'));
    await tester.pumpAndSettle();

    expect(find.byType(UpdateAvailableDialog), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(find.text('下载并安装'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.drag(
      find.byType(SingleChildScrollView).last,
      const Offset(0, -240),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
