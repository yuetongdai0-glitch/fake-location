import 'package:fake_location/core/models.dart';
import 'package:fake_location/core/storage.dart';
import 'package:fake_location/ui/route_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _start = LatLng(29.75, 106.58);
const _end = LatLng(29.751, 106.581);
const _mockChannel = MethodChannel('fake_location/mock');

/// 用已有路线打开编辑器，直接验证标记手势而不是调用私有状态。
Future<void> _openRoute(WidgetTester tester, {bool running = false}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final storage = await AppStorage.load();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_mockChannel, (call) async {
        if (call.method == 'mockStatus') {
          return {'serviceActive': running, 'routeActive': running};
        }
        return null;
      });
  await tester.pumpWidget(
    MaterialApp(
      home: RoutePage(
        initial: _start,
        config: AppConfig()..lastRoute = RoutePlan(points: [_start, _end]),
        storage: storage,
      ),
    ),
  );
  await tester.pump();
}

/// 仅读取路线标记，不依赖地图底图和外部网络。
List<LatLng> _routePoints(WidgetTester tester) => tester
    .widget<MarkerLayer>(find.byType(MarkerLayer))
    .markers
    .map((marker) => marker.point)
    .toList();

/// 长按识别后拖动，避免与地图的单指平移手势争抢。
Future<void> _dragMarker(WidgetTester tester, int index, Offset offset) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byKey(ValueKey('route-point-$index'))),
  );
  await tester.pump(const Duration(milliseconds: 600));
  await gesture.moveBy(offset);
  await tester.pump();
  await gesture.up();
}

void main() {
  testWidgets('路线单位和系统错误使用中文，不显示原始英文异常', (tester) async {
    await _openRoute(tester);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_mockChannel, (call) async {
          if (call.method == 'startRoute') {
            throw PlatformException(
              code: 'NATIVE_OPERATION_FAILED',
              message: 'java.lang.IllegalStateException: failed',
            );
          }
          return null;
        });
    expect(find.textContaining('公里/小时'), findsWidgets);
    expect(find.textContaining('km/h'), findsNothing);
    await tester.tap(find.text('开始模拟'));
    await tester.pump();
    expect(find.text('路线启动失败，请检查定位设置和路线参数后重试'), findsOneWidget);
    expect(find.textContaining('IllegalStateException'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('拖动起点和终点仅修改对应点，一次拖动可一次撤销', (tester) async {
    await _openRoute(tester);
    final camera = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!;
    final center = camera.camera.center;
    await _dragMarker(tester, 0, const Offset(50, -35));
    await tester.pump();
    final moved = _routePoints(tester);
    expect(moved.length, 2);
    expect(moved.first, isNot(_start));
    expect(moved.last, _end);
    expect(camera.camera.center, center);
    await tester.tap(find.byTooltip('撤销上一步'));
    await tester.pump();
    expect(_routePoints(tester), [_start, _end]);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '撤销上一步',
            ),
          )
          .onPressed,
      isNull,
    );

    await _dragMarker(tester, 1, const Offset(-45, -30));
    await tester.pump();
    expect(_routePoints(tester).first, _start);
    expect(_routePoints(tester).last, isNot(_end));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('取消标记拖动恢复点位，运行中的路线不可拖改', (tester) async {
    await _openRoute(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('route-point-0'))),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(25, -20));
    await gesture.moveBy(const Offset(30, -20));
    await tester.pump();
    expect(_routePoints(tester).first, isNot(_start));
    await gesture.cancel();
    await tester.pump();
    expect(_routePoints(tester), [_start, _end]);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '撤销上一步',
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await _openRoute(tester, running: true);
    await _dragMarker(tester, 0, const Offset(50, -35));
    await tester.pump();
    expect(_routePoints(tester), [_start, _end]);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('route-settings-button')),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
