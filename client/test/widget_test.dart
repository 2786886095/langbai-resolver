import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_harbor/main.dart';
import 'package:media_harbor/services/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'automatic_update_checks_enabled': false,
    }),
  );

  test('compares update versions numerically', () {
    expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));
    expect(compareVersions('2.0.0', '2.0.0+8'), 0);
    expect(compareVersions('1.0.0', '1.0.1'), lessThan(0));
    expect(compareVersions('1.0.0', '1.0.0-rc.1'), greaterThan(0));
    expect(compareVersions('1.0.0-rc.2', '1.0.0-rc.10'), lessThan(0));
    expect(compareVersions('1.0.0-beta.11', '1.0.0-rc.1'), lessThan(0));
    expect(() => compareVersions('1.0', '1.0.0'), throwsFormatException);
    expect(() => compareVersions('1.0.0-01', '1.0.0'), throwsFormatException);
    expect(() => compareVersions('1.0.0+!', '1.0.0'), throwsFormatException);
  });

  testWidgets('renders the resolver home screen', (tester) async {
    await tester.pumpWidget(const LangbaiResolverApp());
    await tester.pumpAndSettle();

    expect(find.text('langbai解析'), findsOneWidget);
    expect(find.text('识别链接'), findsOneWidget);
    expect(find.text('粘贴链接开始'), findsOneWidget);
    await tester.tap(find.text('解析').first);
    await tester.pumpAndSettle();
    expect(find.text('B站最高画质'), findsOneWidget);
  });

  testWidgets('fits a narrow phone viewport without layout exceptions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const LangbaiResolverApp());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('识别链接'), findsOneWidget);
  });

  testWidgets('supports a small phone at 200 percent text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(const LangbaiResolverApp());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.tap(find.text('工具').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('stacks the Bilibili login action below its copy on phones', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const LangbaiResolverApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('解析').first);
    await tester.pumpAndSettle();

    final titleRect = tester.getRect(find.text('B站最高画质'));
    final actionRect = tester.getRect(find.text('扫码登录'));
    expect(actionRect.top, greaterThan(titleRect.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows automatic update controls in settings', (tester) async {
    await tester.pumpWidget(const LangbaiResolverApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();

    expect(find.text('启动时自动检查更新'), findsOneWidget);
    expect(find.text('立即检查更新'), findsOneWidget);
    expect(find.text('当前版本 1.1.4 · 按当前平台检查'), findsOneWidget);
    expect(find.text('默认保存位置'), findsOneWidget);
    expect(find.text('识别剪贴板链接'), findsOneWidget);
    expect(find.text('高级工具服务'), findsNothing);
  });

  testWidgets('persists the default mobile save destination', (tester) async {
    await tester.pumpWidget(const LangbaiResolverApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件 / 下载目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('系统相册（视频和图片）').last);
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('default_save_destination'), 'gallery');
  });

  testWidgets('shows the GitHub repository in about', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const LangbaiResolverApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于').first);
    await tester.pumpAndSettle();

    expect(find.text('GitHub · langbai-resolver'), findsOneWidget);
  });

  testWidgets('keeps each tool input isolated', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const LangbaiResolverApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('工具').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('多源音乐搜索').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '周杰伦');

    await tester.tap(find.text('返回工具箱'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('公开直链下载').first);
    await tester.pumpAndSettle();
    final directField = tester.widget<TextField>(find.byType(TextField));
    expect(directField.controller!.text, isEmpty);

    await tester.tap(find.text('返回工具箱'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('多源音乐搜索').first);
    await tester.pumpAndSettle();
    final musicField = tester.widget<TextField>(find.byType(TextField));
    expect(musicField.controller!.text, '周杰伦');
  });
}
