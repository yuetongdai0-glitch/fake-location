import 'package:fake_location/core/coord.dart';
import 'package:fake_location/core/models.dart';
import 'package:fake_location/core/route_tools.dart';
import 'package:fake_location/core/storage.dart';
import 'package:fake_location/ui/route_page.dart';
import 'package:fake_location/ui/saved_routes_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _points = [
  LatLng(29.75, 106.58),
  LatLng(29.751, 106.581),
  LatLng(29.752, 106.58),
];
const _channel = MethodChannel('fake_location/mock');

/// 以真实路线草稿打开页面，存储与系统通道使用本地替身。
Future<AppStorage> _openEditor(
  WidgetTester tester, {
  List<RoutePlan> saved = const [],
  bool running = false,
  double textScale = 1,
  void Function()? onStart,
  List<LatLng> points = _points,
}) async {
  SharedPreferences.setMockInitialValues({});
  final storage = await AppStorage.load();
  await storage.writeRoutes(saved);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'mockStatus') {
          return {'serviceActive': running, 'routeActive': running};
        }
        if (call.method == 'startRoute') onStart?.call();
        return null;
      });
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: RoutePage(
        initial: points.first,
        config: AppConfig()..lastRoute = RoutePlan(points: List.of(points)),
        storage: storage,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return storage;
}

/// 从地图公开图层读取草稿，验证工具不会凭空追加额外标记。
List<LatLng> _draft(WidgetTester tester) => tester
    .widget<MarkerLayer>(find.byType(MarkerLayer))
    .markers
    .map((marker) => marker.point)
    .toList();

/// 打开工具并选择动作，等待弹层动画完成后再验证新的草稿。
Future<void> _tool(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const ValueKey('route-tools-button')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(label));
  await tester.pump();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('65点密集环线只缩小普通点，起终和选中点突出且手势保持可用', (tester) async {
    final points = RouteTools.circle(center: _points.first, radiusMeters: 10);
    await _openEditor(tester, points: points);
    expect(find.text('放大地图可编辑密集途经点，长按可拖动'), findsNothing);
    for (var index = 0; index < points.length; index++) {
      final badge = find.byKey(ValueKey('route-point-badge-$index'));
      expect(
        tester.getSize(badge),
        Size.square(index == 0 || index == 64 ? 28 : 8),
      );
      final marker = tester.widget<GestureDetector>(
        find.byKey(ValueKey('route-point-$index')),
      );
      expect(marker.onTap, isNotNull);
      expect(marker.onLongPressStart, isNotNull);
      expect(marker.onLongPressMoveUpdate, isNotNull);
      expect(marker.onLongPressEnd, isNotNull);
      final semantics = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.byKey(ValueKey('route-point-$index')),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(semantics.properties.label, '编辑路线第 ${index + 1} 个点');
    }
    expect(find.text('32'), findsNothing);
    // 放大到可分辨相邻采样点后，真实点击仍选中对应小圆点。
    final map = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!;
    map.move(points[32], 22);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('route-point-32')));
    await tester.pump();
    expect(find.text('点击地图重选第 33 个点'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('route-point-badge-32'))),
      const Size.square(34),
    );
    expect(find.text('32'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    map.move(points.last, 20);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('route-point-64')));
    await tester.pump();
    expect(find.text('点击地图重选终点'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    // 闭合环线起终重合时，现有重选起点入口仍能明确选中起点。
    await _tool(tester, '重选起点');
    await tester.pump();
    expect(find.text('点击地图重选起点'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('route-point-badge-0'))),
      const Size.square(34),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('反转和闭合均可一次撤销，重复闭合不会污染撤销栈', (tester) async {
    var starts = 0;
    await _openEditor(tester, onStart: () => starts++);
    expect(find.byType(ChoiceChip), findsNothing);
    await _tool(tester, '反转路线');
    expect(_draft(tester), _points.reversed.toList());
    await tester.tap(find.byTooltip('撤销上一步'));
    await tester.pump();
    expect(_draft(tester), _points);
    await _tool(tester, '闭合路线');
    expect(_draft(tester), [..._points, _points.first]);
    await _tool(tester, '闭合路线');
    await tester.tap(find.byTooltip('撤销上一步'));
    await tester.pump();
    expect(_draft(tester), _points);
    expect(starts, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('半径环线沿用草稿设置且生成不自动启动，一次撤销恢复完整原草稿', (tester) async {
    var starts = 0;
    await _openEditor(tester, onStart: () => starts++);
    await _tool(tester, '按半径生成环线');
    await tester.enterText(
      find.byKey(const ValueKey('circle-radius-input')),
      '500',
    );
    await tester.tap(find.text('逆时针'));
    await tester.tap(find.text('生成环线'));
    await tester.pumpAndSettle();
    final generated = _draft(tester);
    expect(generated.length, 65);
    expect(generated.first, generated.last);
    expect(
      Coord.distanceMeters(
        Coord.gcjToWgs(_points.first),
        Coord.gcjToWgs(generated.first),
      ),
      closeTo(500, 0.001),
    );
    expect(starts, 0);
    await tester.tap(find.byTooltip('撤销上一步'));
    await tester.pump();
    expect(_draft(tester), _points);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('非法半径与取消保留草稿，服务运行期间工具入口锁定', (tester) async {
    await _openEditor(tester);
    await _tool(tester, '按半径生成环线');
    await tester.enterText(
      find.byKey(const ValueKey('circle-radius-input')),
      '9',
    );
    await tester.tap(find.text('生成环线'));
    await tester.pump();
    expect(find.text('请输入 10 至 10000 米之间的半径'), findsOneWidget);
    expect(_draft(tester), _points);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(_draft(tester), _points);
    await tester.pumpWidget(const SizedBox.shrink());
    await _openEditor(tester, running: true);
    await tester.tap(find.byKey(const ValueKey('route-tools-button')));
    await tester.pumpAndSettle();
    final circle = find.widgetWithText(ListTile, '按半径生成环线');
    expect(tester.widget<ListTile>(circle).enabled, isFalse);
    await tester.tap(circle);
    await tester.pump();
    expect(find.byKey(const ValueKey('circle-radius-input')), findsNothing);
    Navigator.of(tester.element(circle)).pop();
    await tester.pumpAndSettle();
    expect(_draft(tester), _points);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('已存路线可按名称筛选，删除取消保留原路线，确认后列表保持打开', (tester) async {
    final storage = await _openEditor(
      tester,
      saved: [
        RoutePlan(points: _points, name: '公园环线'),
        RoutePlan(points: _points, name: '通勤路线'),
      ],
    );
    await _tool(tester, '已保存路线');
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '按路线名称搜索'), '公园');
    await tester.pump();
    expect(find.text('公园环线'), findsOneWidget);
    expect(find.text('通勤路线'), findsNothing);
    await tester.tap(find.byTooltip('删除「公园环线」'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(storage.readRoutes().length, 2);
    await tester.tap(find.byTooltip('删除「公园环线」'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(storage.readRoutes().map((route) => route.name), ['通勤路线']);
    expect(find.byType(SavedRoutesSheet), findsOneWidget);
    expect(find.text('没有找到匹配的路线'), findsOneWidget);
    await tester.tap(find.byTooltip('清空路线搜索'));
    await tester.pump();
    expect(find.text('通勤路线'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('同名路线保存必须确认替换，取消不改旧存储或当前草稿', (tester) async {
    final old = RoutePlan(
      points: const [LatLng(30, 107), LatLng(30.01, 107.01)],
      name: '路线 3 点',
    );
    final storage = await _openEditor(tester, saved: [old]);
    for (final replace in [false, true]) {
      await _tool(tester, '保存路线');
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('替换同名路线'), findsOneWidget);
      await tester.tap(find.text(replace ? '替换' : '取消'));
      await tester.pumpAndSettle();
      expect(storage.readRoutes().length, 1);
      expect(
        storage.readRoutes().single.points,
        replace ? _points : old.points,
      );
      expect(_draft(tester), _points);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('循环预览包含回程但不追加草稿点，跨日期线环线保持局部视角', (tester) async {
    await _openEditor(
      tester,
      points: const [LatLng(0, 179.9999), LatLng(0.001, -179.9999)],
    );
    final layer = tester.widget<PolylineLayer>(find.byType(PolylineLayer));
    expect(layer.polylines.length, 2);
    expect(_draft(tester).length, 2);
    final camera = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!;
    expect(camera.camera.zoom, greaterThan(10));
    expect(camera.camera.center.longitude.abs(), greaterThan(170));
    await _tool(tester, '按半径生成环线');
    await tester.tap(find.text('生成环线'));
    await tester.pumpAndSettle();
    expect(_draft(tester).length, 65);
    expect(camera.camera.zoom, greaterThan(10));
    expect(camera.camera.center.longitude.abs(), greaterThan(170));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('360像素大字号下工具弹层和环线输入不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _openEditor(tester, textScale: 1.6);
    expect(tester.takeException(), isNull);
    await _tool(tester, '按半径生成环线');
    expect(find.byKey(const ValueKey('circle-radius-input')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(_draft(tester), _points);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
