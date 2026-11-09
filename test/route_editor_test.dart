import 'dart:async';

import 'package:fake_location/core/models.dart';
import 'package:fake_location/core/storage.dart';
import 'package:fake_location/ui/route_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _initial = LatLng(29.75, 106.58);
const _end = LatLng(29.751, 106.581);
const _replacement = LatLng(29.753, 106.583);
const _channel = MethodChannel('fake_location/mock');

/// 从地图公开回调描点，避免瓦片加载和动画影响坐标断言。
Future<void> _tapMap(WidgetTester tester, LatLng point) async {
  tester.widget<FlutterMap>(find.byType(FlutterMap)).options.onTap!(
    const TapPosition(Offset.zero, Offset.zero),
    point,
  );
  await tester.pump();
}

/// 读取实际渲染路线点，验证 UI 与下发路线使用同一份草稿。
List<LatLng> _points(WidgetTester tester) => tester
    .widget<MarkerLayer>(find.byType(MarkerLayer))
    .markers
    .map((marker) => marker.point)
    .toList();

Future<void> _openEditor(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final storage = await AppStorage.load();
  await tester.pumpWidget(
    MaterialApp(
      home: RoutePage(
        initial: _initial,
        config: AppConfig()..writeGcj = true,
        storage: storage,
      ),
    ),
  );
  await tester.pump();
}

/// 经统一工具入口执行草稿操作，避免依赖已收起的主界面按钮。
Future<void> _tool(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const ValueKey('route-tools-button')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (_) async => null);
  });

  testWidgets('重选起点保留终点，撤销可恢复，任意途经点可删改', (tester) async {
    await _openEditor(tester);
    await _tapMap(tester, _end);
    await _tool(tester, '重选起点');
    await tester.pump();
    expect(find.text('点击地图重选起点'), findsOneWidget);
    await _tapMap(tester, _replacement);
    expect(_points(tester), [_replacement, _end]);

    await tester.tap(find.byTooltip('撤销上一步'));
    await tester.pump();
    expect(_points(tester), [_initial, _end]);

    // 移动与删除途经点都经标记入口，起终点也走相同路径。
    await _tapMap(tester, _replacement);
    await _tool(tester, '视角回到路线');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('route-point-1')));
    await tester.pump();
    expect(find.text('点击地图重选第 2 个点'), findsOneWidget);
    const moved = LatLng(29.7515, 106.5815);
    await _tapMap(tester, moved);
    expect(_points(tester), [_initial, moved, _replacement]);
    await tester.tap(find.byKey(const ValueKey('route-point-1')));
    await tester.pump();
    await tester.tap(find.text('删除此点'));
    await tester.pump();
    expect(_points(tester), [_initial, _replacement]);
    await tester.tap(find.byTooltip('撤销上一步'));
    await tester.pump();
    expect(_points(tester), [_initial, moved, _replacement]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('清空后首点可重新设置，删除最后一个点不崩溃，小屏布局正常', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _openEditor(tester);
    await _tapMap(tester, _end);
    await _tool(tester, '清空路线');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(_points(tester), [_initial, _end]);
    await _tool(tester, '清空路线');
    await tester.tap(find.text('清空'));
    await tester.pump();
    expect(_points(tester), isEmpty);
    await _tool(tester, '视角回到路线');
    await tester.pump();
    await _tapMap(tester, _replacement);
    expect(_points(tester), [_replacement]);
    await _tool(tester, '重选起点');
    await tester.pump();
    await tester.tap(find.text('删除此点'));
    await tester.pump();
    expect(_points(tester), isEmpty);
    await tester.tap(find.byTooltip('撤销上一步'));
    await tester.pump();
    expect(_points(tester), [_replacement]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('启动等待中和运行中禁止改点，停止后可继续编辑', (tester) async {
    final started = Completer<void>();
    Map<dynamic, dynamic>? sent;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'startRoute') {
            sent = call.arguments as Map<dynamic, dynamic>;
            await started.future;
          }
          return null;
        });
    await _openEditor(tester);
    await _tapMap(tester, _end);
    await tester.tap(find.text('开始模拟'));
    await tester.pump();
    await _tapMap(tester, _replacement);
    expect(_points(tester), [_initial, _end]);
    expect(sent!['points'], [29.75, 106.58, 29.751, 106.581]);
    started.complete();
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('route-settings-button')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('route-tools-button')));
    await tester.pumpAndSettle();
    final clear = find.widgetWithText(ListTile, '清空路线');
    await tester.ensureVisible(clear);
    expect(tester.widget<ListTile>(clear).enabled, isFalse);
    Navigator.of(tester.element(clear)).pop();
    await tester.pumpAndSettle();
    await _tapMap(tester, _replacement);
    expect(_points(tester), [_initial, _end]);
    await tester.tap(find.text('停止'));
    await tester.pump();
    await _tapMap(tester, _replacement);
    expect(_points(tester), [_initial, _end, _replacement]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('重新进入仍在运行的路线时保持编辑锁定', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'mockStatus') {
            return {'running': true, 'routeActive': true, 'routePaused': true};
          }
          return null;
        });
    await _openEditor(tester);
    expect(find.text('继续'), findsOneWidget);
    await _tapMap(tester, _end);
    expect(_points(tester), [_initial]);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('route-settings-button')),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('推送暂时失败及恢复期间保持锁定，仍可停止路线', (tester) async {
    var pushHealthy = false;
    var stopped = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'mockStatus') {
            return {
              'serviceActive': !stopped,
              'running': pushHealthy,
              'routeActive': !stopped,
              'routePaused': false,
            };
          }
          if (call.method == 'stop') stopped = true;
          return null;
        });
    await _openEditor(tester);
    // 进入页面时推送不健康，仍需恢复已有任务的控制权。
    expect(find.text('停止'), findsOneWidget);
    await _tapMap(tester, _end);
    expect(_points(tester), [_initial]);
    pushHealthy = true;
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    pushHealthy = false;
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    await _tapMap(tester, _replacement);
    expect(_points(tester), [_initial]);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('route-settings-button')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('停止'));
    await tester.pump();
    expect(stopped, isTrue);
    await _tapMap(tester, _end);
    expect(_points(tester), [_initial, _end]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
