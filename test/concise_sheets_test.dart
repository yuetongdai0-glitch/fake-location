import 'dart:convert';

import 'package:fake_location/core/models.dart';
import 'package:fake_location/core/storage.dart';
import 'package:fake_location/ui/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('小屏大字设置保留备份操作和短说明，删除无关说明块', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final storage = await AppStorage.load();
    String? exported;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        exported = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Scaffold(
          body: SettingsSheet(
            config: AppConfig(),
            versionName: '1.4.1',
            availableUpdate: null,
            updateChecked: false,
            checkingUpdate: false,
            updateBusy: false,
            onConfigChanged: (_) async {},
            onCheckUpdate: () async => null,
            onInstallUpdate: (_) async {},
            onOpenUrl: (_) async {},
            storage: storage,
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('选填，用于高德地点搜索'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('选填，用于高德地点搜索'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('备份地点、路线和设置'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    for (final label in ['导出到剪贴板', '从剪贴板导入']) {
      final rect = tester.getRect(find.text(label));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(360));
    }
    expect(find.text('备份地点、路线和设置'), findsOneWidget);
    await tester.ensureVisible(find.text('导出到剪贴板'));
    await tester.tap(find.text('导出到剪贴板'));
    await tester.pumpAndSettle();
    expect(jsonDecode(exported!)['app'], 'fake_location');
    expect(find.text('备份已复制'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(find.text('需要系统提权的功能'), findsNothing);
    expect(find.text('使用提示'), findsNothing);
    expect(find.text('坐标转换：WGS-84 ↔ GCJ-02 ↔ BD-09'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('检测保留逐源与复制，失败时不显示系统读回通过的说明', (tester) async {
    const target = LatLng(29.75, 106.58);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MockCheckSheet(
            loadReport: () async => const MockReport(
              serviceRunning: true,
              mockAppSelected: true,
              pushCount: 10,
              elapsedMs: 100,
              providers: ['gps'],
              expectedProviders: ['gps', 'network'],
              providerErrors: {'network': '权限不足'},
              systemWgs: target,
              systemIsMock: true,
              providerLocations: [
                MockProviderReport(
                  provider: 'gps',
                  point: target,
                  isMock: true,
                  ageMs: 100,
                ),
              ],
            ),
            targetWgs: target,
            onRetryPush: () async {},
            onOpenExternalApp: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('部分定位源尚未接管'), findsOneWidget);
    expect(find.text('权限不足'), findsOneWidget);
    expect(find.text('复制检测结果'), findsOneWidget);
    expect(find.text('卫星读回'), findsOneWidget);
    expect(find.text('系统读回通过，目标应用仍可能使用独立定位。'), findsNothing);
    expect(find.text('目标应用可能使用独立定位。'), findsOneWidget);
    expect(find.text('应用兼容性说明'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('设置保存失败恢复旧值并保留错误，重试成功才提示已保存', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final storage = await AppStorage.load();
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsSheet(
            config: AppConfig(amapKey: '旧密钥'),
            versionName: '1.4.1',
            availableUpdate: null,
            updateChecked: false,
            checkingUpdate: false,
            updateBusy: false,
            onConfigChanged: (_) async {
              if (++attempts == 1) throw const FormatException('设置保存失败');
            },
            onCheckUpdate: () async => null,
            onInstallUpdate: (_) async {},
            onOpenUrl: (_) async {},
            storage: storage,
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('保存'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    final input = find.byType(TextField);
    await tester.enterText(input, '新密钥');
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(attempts, 1);
    expect(tester.widget<TextField>(input).controller!.text, '旧密钥');
    expect(find.text('设置保存失败'), findsOneWidget);
    expect(find.text('已保存'), findsNothing);
    expect(find.text('设置已保存'), findsNothing);

    await tester.enterText(input, '新密钥');
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('已保存'), findsOneWidget);
    expect(find.text('设置保存失败'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
