import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_harbor/pages/tools_page.dart';
import 'package:media_harbor/theme/langbai_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('com.langbai.resolver/local_media');
const _fileSelectorChannel = MethodChannel('plugins.flutter.io/file_selector');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_fileSelectorChannel, null);
  });

  Widget app({String initialInput = 'convert'}) => MaterialApp(
    theme: LangbaiTheme.light(),
    home: ToolsPage(initialInput: initialInput, onOpenParser: (_) {}),
  );

  testWidgets('desktop conversion workspace accepts OS file drops', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(app());
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('格式转换'), findsWidgets);
      expect(find.text('第 1 步 · 拖入文件，或点击选择'), findsOneWidget);
      expect(find.byType(DropTarget), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('mobile conversion only exposes native reported formats', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'getCapabilities') {
            return <String, Object?>{
              'platform': 'android',
              'local_resolver': true,
              'format_conversion': true,
              'media_probe': true,
              'conversion_progress': true,
              'conversion_cancellation': true,
              'conversion': {
                'input_extensions': ['mp4', 'mkv'],
                'output_formats': [
                  'mp4',
                  'webm',
                  'avi',
                  'm4a',
                  'ac3',
                  'jpg',
                  'tiff',
                ],
                'quality_values': ['medium', 'high'],
              },
              'tools': <String, bool>{},
            };
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_fileSelectorChannel, (call) async {
          expect(call.method, 'openFile');
          return <String>['/tmp/sample.mp4'];
        });
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('选择本地文件'), findsOneWidget);
    expect(
      find.text('第 1 步：先选择需要转换的文件，系统会根据文件类型列出可用格式。'),
      findsOneWidget,
    );
    expect(find.textContaining('MP4'), findsNothing);
    await tester.ensureVisible(find.text('选择本地文件'));
    await tester.tap(find.text('选择本地文件'));
    await tester.pumpAndSettle();
    expect(find.textContaining('MP4'), findsOneWidget);
    await tester.ensureVisible(find.textContaining('MP4'));
    await tester.tap(find.textContaining('MP4'));
    await tester.pumpAndSettle();
    expect(find.textContaining('WEBM'), findsOneWidget);
    expect(find.textContaining('AVI'), findsOneWidget);
    expect(find.textContaining('AC3'), findsOneWidget);
    expect(find.text('本机可用'), findsWidgets);
    expect(find.text('手机端未内置 P2P'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native probe does not expose or route a remote cancel action', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final probe = Completer<Map<String, Object?>>();
    var probeCalls = 0;
    var filePickerCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'getCapabilities') {
            return <String, Object?>{
              'platform': 'android',
              'local_resolver': true,
              'media_probe': true,
              'tools': <String, bool>{'metadata': true},
            };
          }
          if (call.method == 'probeMedia') {
            probeCalls++;
            return probe.future;
          }
          fail('unexpected local method ${call.method}');
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_fileSelectorChannel, (call) async {
          filePickerCalls++;
          expect(call.method, 'openFile');
          return <String>[
            Platform.isWindows ? r'C:\tmp\sample.mp4' : '/tmp/sample.mp4',
          ];
        });
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await tester.pumpWidget(app(initialInput: 'metadata'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.ensureVisible(find.text('选择本地文件'));
    await tester.tap(find.text('选择本地文件'));
    await tester.pumpAndSettle();
    expect(filePickerCalls, 1);
    expect(find.text('sample.mp4'), findsOneWidget);

    await tester.ensureVisible(find.text('开始任务'));
    await tester.tap(find.text('开始任务'));
    await tester.pump();

    expect(probeCalls, 1);
    expect(find.text('取消'), findsNothing);

    probe.complete(<String, Object?>{
      'filename': 'sample.mp4',
      'extension': 'mp4',
      'mime_type': 'video/mp4',
      'size_bytes': 1024,
      'duration_seconds': 1.5,
      'width': 320,
      'height': 180,
      'has_video': true,
      'has_audio': false,
      'streams': <Object?>[],
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('任务完成'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
