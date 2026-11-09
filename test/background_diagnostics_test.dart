import 'package:fake_location/core/models.dart';
import 'package:fake_location/ui/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// 后台状态允许单项未知，不能把接口缺失误显示成已允许后台运行。
MockReport _report({bool restricted = false}) => MockReport(
  serviceRunning: false,
  mockAppSelected: false,
  pushCount: 0,
  elapsedMs: -1,
  providers: const [],
  ignoringBatteryOptimizations: restricted ? false : null,
  powerSaveMode: restricted ? true : null,
  backgroundRestricted: restricted ? true : null,
);

void main() {
  testWidgets('后台状态未知时不显示已解除限制', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MockCheckSheet(
            loadReport: () async => _report(),
            targetWgs: const LatLng(29.75, 106.58),
            onRetryPush: () async {},
            onOpenExternalApp: (_) async {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('暂时无法读取'), findsNWidgets(2));
    expect(find.text('当前系统未提供此状态'), findsOneWidget);
    expect(find.text('系统未限制本应用后台运行'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('小屏展示实际限制并可打开用户后台设置', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MockCheckSheet(
            loadReport: () async => _report(restricted: true),
            targetWgs: const LatLng(29.75, 106.58),
            onRetryPush: () async {},
            onOpenExternalApp: (_) async {},
            onOpenAppSettings: () async {
              opened++;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('仍受系统电池优化限制'), findsOneWidget);
    expect(find.text('系统已限制本应用后台运行'), findsOneWidget);
    await tester.ensureVisible(find.text('检查后台运行设置'));
    await tester.tap(find.text('检查后台运行设置'));
    await tester.pump();
    expect(opened, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
