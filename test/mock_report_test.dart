import 'package:fake_location/core/models.dart';
import 'package:fake_location/ui/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

const _target = LatLng(29.75, 106.58);

/// 构造逐源检测快照，模拟 GPS 正常但网络源丢失、过期或返回原位。
MockReport _report({
  List<String> providers = const ['gps', 'network'],
  int elapsedMs = 100,
  int networkAge = 100,
  bool networkMock = true,
  LatLng networkPoint = _target,
  Map<String, String> errors = const {},
  LatLng? pushedWgs,
}) => MockReport(
  serviceRunning: true,
  mockAppSelected: true,
  pushCount: 100,
  elapsedMs: elapsedMs,
  providers: providers,
  expectedProviders: const ['gps', 'network'],
  providerErrors: errors,
  systemWgs: _target,
  systemIsMock: true,
  wifiEnabled: true,
  pushedWgs: pushedWgs,
  providerLocations: [
    const MockProviderReport(
      provider: 'gps',
      point: _target,
      isMock: true,
      ageMs: 100,
    ),
    MockProviderReport(
      provider: 'network',
      point: networkPoint,
      isMock: networkMock,
      ageMs: networkAge,
    ),
  ],
);

void main() {
  test('WiFi 开启不影响各系统源均命中目标时通过检测', () {
    expect(_report().matchesTarget(_target), isTrue);
  });

  test('GPS 成功不能掩盖网络源推送失败', () {
    expect(
      _report(
        providers: ['gps'],
        errors: {'network': '权限不足'},
      ).matchesTarget(_target),
      isFalse,
    );
  });

  test('过期推送或过期读回均不能通过检测', () {
    expect(_report(elapsedMs: 5000).matchesTarget(_target), isFalse);
    expect(_report(networkAge: 5000).matchesTarget(_target), isFalse);
  });

  test('网络源返回真实位置或其它目标时不能通过检测', () {
    expect(_report(networkMock: false).matchesTarget(_target), isFalse);
    expect(
      _report(networkPoint: const LatLng(30, 107)).matchesTarget(_target),
      isFalse,
    );
  });

  test('无缓存的原生读回保留错误且不产生虚假坐标', () {
    final provider = MockProviderReport.fromMap({
      'provider': 'network',
      'error': '暂无缓存',
    });
    expect(provider.point, isNull);
    expect(provider.matchesTarget(_target), isFalse);
  });

  testWidgets('小屏检测可滚动并显示部分源失败，不宣称全局生效', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MockCheckSheet(
            loadReport: () async =>
                _report(providers: ['gps'], errors: {'network': '权限不足'}),
            targetWgs: _target,
            onRetryPush: () async {},
            onOpenExternalApp: (_) async {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('部分定位源尚未接管'), findsOneWidget);
    expect(find.text('权限不足'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('检测使用服务已应用的坐标，未应用的远处草稿不会误报失效', (tester) async {
    const unappliedDraft = LatLng(39.9, 116.4);
    final report = _report(pushedWgs: _target);
    // 先确认两个点确实不能被 50 米容差混为同一位置。
    expect(report.matchesTarget(unappliedDraft), isFalse);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MockCheckSheet(
            loadReport: () async => report,
            targetWgs: unappliedDraft,
            onRetryPush: () async {},
            onOpenExternalApp: (_) async {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('系统定位源校验通过'), findsOneWidget);
    expect(find.text('系统位置与目标不一致'), findsNothing);
    expect(find.text('正在模拟的坐标'), findsOneWidget);
    expect(find.text('29.750000, 106.580000'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
