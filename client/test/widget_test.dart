import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_harbor/main.dart';
import 'package:media_harbor/services/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({
        'automatic_update_checks_enabled': false,
      }));

  test('compares update versions numerically', () {
    expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));
    expect(compareVersions('2.0.0', '2.0.0+8'), 0);
    expect(compareVersions('1.0.0', '1.0.1'), lessThan(0));
  });

  testWidgets('renders the resolver home screen', (tester) async {
    await tester.pumpWidget(const LangbaiResolverApp());
    await tester.pumpAndSettle();

    expect(find.text('langbai解析'), findsOneWidget);
    expect(find.text('识别链接'), findsOneWidget);
    expect(find.text('粘贴链接开始'), findsOneWidget);
  });

  testWidgets('fits a narrow phone viewport without layout exceptions',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const LangbaiResolverApp());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('识别链接'), findsOneWidget);
  });

  testWidgets('shows automatic update controls in settings', (tester) async {
    await tester.pumpWidget(const LangbaiResolverApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();

    expect(find.text('启动时自动检查更新'), findsOneWidget);
    expect(find.text('立即检查更新'), findsOneWidget);
    expect(find.text('当前版本 1.0.0 · 全平台支持检测'), findsOneWidget);
  });
}
