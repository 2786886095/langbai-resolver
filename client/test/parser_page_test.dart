import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_harbor/pages/parser_page.dart';
import 'package:media_harbor/theme/langbai_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('com.langbai.resolver/local_media');

Map<String, Object?> _imagePayload() => {
  'media_id': 'media-image-12345678',
  'source_url': 'https://example.com/image-post',
  'title': '这是一个很长的图文作品标题，用于确认横竖屏和大字体下不会挤出界面边界',
  'creator': '测试作者',
  'platform': 'Example Images',
  'duration_seconds': 15,
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
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  void mockResolver({Object? payload, String? error}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'resolve') {
            if (error != null) {
              throw PlatformException(code: 'RESOLVE_ERROR', message: error);
            }
            return payload;
          }
          if (call.method == 'getCapabilities') {
            return <String, Object?>{
              'platform': 'android',
              'local_resolver': true,
              'tools': <String, bool>{},
            };
          }
          return null;
        });
  }

  Widget app({MediaQueryData? mediaQuery}) {
    const page = ParserPage();
    return MaterialApp(
      theme: LangbaiTheme.light(),
      home: mediaQuery == null
          ? Scaffold(body: page)
          : MediaQuery(
              data: mediaQuery,
              child: Scaffold(body: page),
            ),
    );
  }

  Future<void> resolve(WidgetTester tester) async {
    await tester.enterText(
      find.byType(TextField).first,
      'https://example.com/image-post',
    );
    await tester.ensureVisible(find.text('开始解析'));
    await tester.tap(find.text('开始解析'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'image-only result renders only real image options and previews',
    (tester) async {
      mockResolver(payload: _imagePayload());
      await tester.pumpWidget(app());
      await resolve(tester);

      expect(find.text('图片 (2)'), findsOneWidget);
      expect(find.textContaining('视频 ('), findsNothing);
      expect(
        find.byKey(const ValueKey('image-option-preview-image:1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('image-option-preview-image:2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('media-preview-image:1')),
        findsOneWidget,
      );
      expect(find.text('00:15'), findsNothing);

      final mainPreview = find.byKey(const ValueKey('media-preview-image:1'));
      final previewImage = tester.widget<Image>(
        find.descendant(of: mainPreview, matching: find.byType(Image)),
      );
      expect(previewImage.fit, BoxFit.contain);
      expect(previewImage.image, isA<ResizeImage>());
      expect((previewImage.image as ResizeImage).width, 1280);
      expect(find.text('\u91cd\u65b0\u52a0\u8f7d'), findsWidgets);

      await tester.ensureVisible(mainPreview);
      await tester.tap(mainPreview);
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byTooltip('\u5173\u95ed\u9884\u89c8'), findsOneWidget);
    },
  );

  testWidgets('repeated link parsing reuses the short page cache', (
    tester,
  ) async {
    var resolveCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'resolve') {
            resolveCalls++;
            return _imagePayload();
          }
          if (call.method == 'getCapabilities') {
            return <String, Object?>{
              'platform': 'android',
              'local_resolver': true,
              'tools': <String, bool>{},
            };
          }
          return null;
        });

    await tester.pumpWidget(app());
    await resolve(tester);
    await tester.ensureVisible(find.text('\u5f00\u59cb\u89e3\u6790'));
    await tester.tap(find.text('\u5f00\u59cb\u89e3\u6790'));
    await tester.pumpAndSettle();
    expect(resolveCalls, 1);
  });

  testWidgets('image grid fits portrait, landscape, safe areas and keyboard', (
    tester,
  ) async {
    mockResolver(payload: _imagePayload());
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    tester.view.physicalSize = const Size(360, 720);
    await tester.pumpWidget(
      app(
        mediaQuery: const MediaQueryData(
          size: Size(360, 720),
          padding: EdgeInsets.only(top: 32, bottom: 20),
          viewInsets: EdgeInsets.only(bottom: 260),
          textScaler: TextScaler.linear(2),
        ),
      ),
    );
    await resolve(tester);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(720, 360);
    await tester.pumpWidget(
      app(
        mediaQuery: const MediaQueryData(
          size: Size(720, 360),
          padding: EdgeInsets.only(left: 28, right: 28),
          textScaler: TextScaler.linear(2),
        ),
      ),
    );
    await resolve(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('图片 (2)'), findsOneWidget);
  });

  testWidgets('long resolver errors remain scrollable on a small phone', (
    tester,
  ) async {
    mockResolver(
      error: List.filled(4, '解析失败：平台返回了很长的错误说明，链接可能已经失效或需要在平台应用中重新分享。').join(),
    );
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(app());
    await resolve(tester);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('平台返回了很长的错误说明'), findsOneWidget);
  });
}
