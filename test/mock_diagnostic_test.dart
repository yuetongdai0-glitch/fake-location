import 'package:fake_location/core/mock_diagnostic.dart';
import 'package:fake_location/core/models.dart';
import 'package:fake_location/ui/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

const _applied = LatLng(29.73358, 106.54364);
const _draft = LatLng(39.9, 116.4);

/// 创建真机排障需要的最小快照；额外设备字段必须被白名单忽略。
MockReport _report({bool partial = false, Map<String, Object?>? deviceInfo}) =>
    MockReport(
      serviceRunning: true,
      mockAppSelected: true,
      pushCount: 27,
      elapsedMs: 200,
      providers: partial ? const ['gps'] : const ['gps', 'network', 'fused'],
      expectedProviders: const ['gps', 'network', 'fused'],
      pushedWgs: _applied,
      systemWgs: _applied,
      systemIsMock: true,
      systemAccuracy: 5,
      systemProvider: 'gps',
      providerLocations: [
        const MockProviderReport(
          provider: 'gps',
          point: _applied,
          isMock: true,
          ageMs: 200,
        ),
        MockProviderReport(
          provider: 'network',
          point: partial ? _draft : _applied,
          isMock: !partial,
          ageMs: partial ? 10000 : 200,
        ),
        if (!partial)
          const MockProviderReport(
            provider: 'fused',
            point: _applied,
            isMock: true,
            ageMs: 200,
          ),
      ],
      providerErrors: partial ? const {'fused': '推送定位失败：权限不足'} : const {},
      wifiEnabled: true,
      wifiScanEnabled: true,
      ignoringBatteryOptimizations: false,
      powerSaveMode: true,
      backgroundRestricted: true,
      deviceInfo:
          deviceInfo ??
          const {
            'manufacturer': 'Xiaomi',
            'brand': 'Xiaomi',
            'model': 'Xiaomi 14',
            'androidVersion': '16',
            'sdkInt': 36,
            'buildDisplay': '系统版本样本',
            'buildIncremental': '厂商系统构建样本',
            'appVersionName': '1.4.1',
            'appVersionCode': 15,
            'androidId': '不能导出的设备标识',
            'amapKey': '不能导出的搜索密钥',
            'ssid': '不能导出的热点名称',
            'favorites': '不能导出的收藏',
            'account': '不能导出的账号',
          },
    );

void main() {
  test('成功快照区分未应用草稿和服务执行点，保留逐源与系统版本证据', () {
    final text = buildMockDiagnostic(
      report: _report(),
      draftWgs: _draft,
      checkedAt: DateTime.utc(2026, 11, 9, 4),
    );
    expect(text, contains('检测时间：2026-11-09T04:00:00.000Z'));
    expect(text, contains('机型：Xiaomi 14'));
    expect(text, contains('安卓版本：16'));
    expect(text, contains('安卓接口级别：36'));
    expect(text, contains('系统增量版本：厂商系统构建样本'));
    expect(text, contains('应用版本：1.4.1'));
    expect(text, contains('当前选点（按写入方式换算）：39.900000, 116.400000'));
    expect(text, contains('服务执行目标（按写入方式换算）：29.733580, 106.543640'));
    expect(text, contains('逐源目标校验：通过'));
    expect(text, contains('距最近成功推送：200 毫秒'));
    expect('读回校验：通过'.allMatches(text), hasLength(3));
    expect(text, contains('与校验目标偏差：0.0 米'));
    expect(text, contains('后台运行受限：是'));
    expect(text, contains('系统读回校验不代表第三方应用采用'));
  });

  test('部分失败快照不会把卫星成功当全部通过，并保留错误与缺失源', () {
    final text = buildMockDiagnostic(
      report: _report(partial: true),
      draftWgs: _draft,
    );
    expect(text, contains('逐源目标校验：未通过或尚未确认'));
    expect(text, contains('缓存年龄：10000 毫秒'));
    expect(text, contains('模拟标记：无'));
    expect(text, contains('融合源（fused）：\n  读回：暂无结果'));
    expect(text, contains('推送错误：推送定位失败：权限不足'));
    expect('读回校验：通过'.allMatches(text), hasLength(1));
  });

  test('设备字段只取白名单，不带出标识、热点、密钥或账号', () {
    final text = buildMockDiagnostic(report: _report(), draftWgs: _draft);
    for (final secret in [
      '不能导出的设备标识',
      '不能导出的搜索密钥',
      '不能导出的热点名称',
      '不能导出的收藏',
      '不能导出的账号',
    ]) {
      expect(text, isNot(contains(secret)));
    }
    final missing = buildMockDiagnostic(
      report: _report(
        deviceInfo: {
          'model': {'unexpected': '不能导出的嵌套字段'},
        },
      ),
      draftWgs: _draft,
    );
    expect(missing, contains('机型：未知'));
    expect(missing, contains('安卓版本：未知'));
    expect(missing, isNot(contains('不能导出的嵌套字段')));
  });

  test('无效读回坐标与未知时间不会输出伪造位置或通过结论', () {
    final invalid = MockProviderReport.fromMap({
      'provider': 'gps',
      'lat': double.nan,
      'lng': 106.54364,
      'ageMs': -1,
      'mock': true,
    });
    final report = MockReport(
      serviceRunning: true,
      mockAppSelected: true,
      pushCount: 2,
      elapsedMs: -1,
      providers: const ['gps'],
      expectedProviders: const ['gps'],
      providerLocations: [invalid],
      providerErrors: const {'gps': '/private/path stack trace'},
    );
    final text = buildMockDiagnostic(report: report, draftWgs: _draft);
    expect(text, contains('读回坐标：无有效坐标'));
    expect(text, contains('缓存年龄：未知'));
    expect(text, contains('逐源目标校验：未通过或尚未确认'));
    expect(text, isNot(contains('NaN')));
    expect(text, isNot(contains('/private/path')));
  });

  testWidgets('检测面板复制当前快照到剪贴板，复制不触发重新推送', (tester) async {
    var loads = 0;
    var retries = 0;
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MockCheckSheet(
            loadReport: () async {
              loads++;
              return _report();
            },
            targetWgs: _draft,
            onRetryPush: () async {
              retries++;
            },
            onOpenExternalApp: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制检测结果'));
    await tester.pump();
    expect(copied, contains('机型：Xiaomi 14'));
    expect(copied, contains('服务执行目标（按写入方式换算）：29.733580, 106.543640'));
    expect(loads, 1);
    expect(retries, 0);
    expect(find.text('已复制检测结果'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
