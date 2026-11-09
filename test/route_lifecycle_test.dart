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

const _channel = MethodChannel('fake_location/mock');
const _prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');
const _initial = LatLng(29.75, 106.58);
const _end = LatLng(29.751, 106.581);
const _replacement = LatLng(29.752, 106.582);
const _holdingMessage = '终点保持中';

Future<void> _open(WidgetTester tester, AppStorage storage) async {
  await tester.pumpWidget(
    MaterialApp(
      home: RoutePage(
        initial: _initial,
        config: AppConfig()
          ..writeGcj = true
          ..lastRoute = RoutePlan(
            points: const [_initial, _end],
            playMode: PlayMode.once,
          ),
        storage: storage,
      ),
    ),
  );
  await tester.pump();
}

/// 原生单程完成时停止路线移动，但服务会继续推送终点。
Map<String, Object> _status({bool active = true, bool completed = false}) => {
  'serviceActive': active,
  'running': false, // 推送暂时不健康也不能隐藏停止入口。
  'routeActive': active && !completed,
  'routeProgress': completed ? 1.0 : 0.2,
  'routeTotal': 150.0,
  'routeTravelled': completed ? 150.0 : 30.0,
  'lat': _end.latitude,
  'lng': _end.longitude,
};

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
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<String, Object> persisted;
  var failWrites = false;

  setUp(() {
    SharedPreferences.resetStatic();
    persisted = {};
    failWrites = false;
    // 与存储失败回归相同的真实插件通道替身，保留磁盘与内存缓存的差异。
    messenger.setMockMethodCallHandler(_prefsChannel, (call) async {
      if (call.method == 'getAll') return Map<String, Object>.from(persisted);
      if (failWrites) return false;
      final args = Map<String, Object>.from(call.arguments as Map);
      final key = args['key']! as String;
      if (call.method == 'remove') {
        persisted.remove(key);
      } else {
        persisted[key] = args['value']!;
      }
      return true;
    });
    messenger.setMockMethodCallHandler(_channel, (_) async => null);
  });

  tearDown(() {
    SharedPreferences.resetStatic();
    messenger.setMockMethodCallHandler(_prefsChannel, null);
    messenger.setMockMethodCallHandler(_channel, null);
  });

  testWidgets('单程完成后仍能停止，失败可重试，编辑草稿不清掉终点保持状态', (tester) async {
    var started = false;
    var completed = false;
    var stopFails = true;
    var stopped = false;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'startRoute') started = true;
      if (call.method == 'stop') {
        if (stopFails) throw PlatformException(code: 'failed');
        stopped = true;
      }
      if (call.method == 'mockStatus') {
        return _status(active: started && !stopped, completed: completed);
      }
      return null;
    });
    await _open(tester, await AppStorage.load());
    await tester.tap(find.text('开始模拟'));
    await tester.pump();
    expect(find.text('暂停'), findsOneWidget);
    completed = true;
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(find.text(_holdingMessage), findsOneWidget);
    expect(find.text('停止'), findsOneWidget);
    expect(find.text('重新模拟'), findsOneWidget);
    expect(find.text('暂停'), findsNothing);
    await _tool(tester, '重选起点');
    await tester.pump();
    tester.widget<FlutterMap>(find.byType(FlutterMap)).options.onTap!(
      const TapPosition(Offset.zero, Offset.zero),
      _replacement,
    );
    await tester.pump();
    expect(
      tester.widget<MarkerLayer>(find.byType(MarkerLayer)).markers.first.point,
      _replacement,
    );
    expect(find.text(_holdingMessage), findsOneWidget);
    await tester.tap(find.text('停止'));
    await tester.pump();
    expect(find.text('停止失败，请重试'), findsOneWidget);
    expect(find.text(_holdingMessage), findsOneWidget);
    stopFails = false;
    await tester.tap(find.text('停止'));
    await tester.pump();
    expect(stopped, isTrue);
    expect(find.text(_holdingMessage), findsNothing);
    expect(find.text('停止'), findsNothing);
    expect(find.text('开始模拟'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('重新进入恢复终点保持及停止入口，外部停止后自动清除状态', (tester) async {
    var active = true;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'mockStatus') {
        return _status(active: active, completed: true);
      }
      return null;
    });
    await _open(tester, await AppStorage.load());
    expect(find.text(_holdingMessage), findsOneWidget);
    expect(find.text('停止'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('route-settings-button')),
          )
          .onPressed,
      isNotNull,
    );
    active = false;
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(find.text(_holdingMessage), findsNothing);
    expect(find.text('停止'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('普通定点模拟保留停止入口但不误报单程完成', (tester) async {
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'mockStatus') {
        return {'serviceActive': true, 'routeActive': false, 'routeTotal': 0};
      }
      return null;
    });
    await _open(tester, await AppStorage.load());
    expect(find.text('停止'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('route-settings-button')),
          )
          .onPressed,
      isNotNull,
    );
    expect(find.text(_holdingMessage), findsNothing);
    expect(find.text('开始模拟'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('停止成功后迟到的轮询结果不能恢复旧终点状态', (tester) async {
    final lateStatus = Completer<Map<String, Object>>();
    var reads = 0;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'mockStatus') {
        if (++reads > 1) return lateStatus.future;
        return _status(completed: true);
      }
      return null;
    });
    await _open(tester, await AppStorage.load());
    await tester.pump(const Duration(milliseconds: 700));
    await tester.tap(find.text('停止'));
    await tester.pump();
    lateStatus.complete(_status(completed: true));
    await tester.pump();
    expect(find.text('停止'), findsNothing);
    expect(find.text(_holdingMessage), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('启动成功但配置写入失败时保留运行和停止，提示中文草稿保存失败', (tester) async {
    var started = false;
    var stopped = false;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'startRoute') started = true;
      if (call.method == 'stop') stopped = true;
      return null;
    });
    await _open(tester, await AppStorage.load());
    failWrites = true;
    await tester.tap(find.text('开始模拟'));
    await tester.pump();
    expect(started, isTrue);
    expect(find.text('暂停'), findsOneWidget);
    expect(find.text('停止'), findsOneWidget);
    expect(find.textContaining('路线已启动，但草稿保存失败'), findsOneWidget);
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
    expect(find.text('停止'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('保存替换写入失败时报告中文并保留旧路线和当前草稿', (tester) async {
    final storage = await AppStorage.load();
    final old = RoutePlan(
      name: '路线 2 点',
      points: const [_initial, _replacement],
    );
    await storage.writeRoutes([old]);
    final before = Map<String, Object>.from(persisted);
    await _open(tester, storage);
    failWrites = true;
    await _tool(tester, '保存路线');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('替换'));
    await tester.pumpAndSettle();
    expect(find.text('保存路线失败，请重试'), findsOneWidget);
    expect(storage.readRoutes().single.points, old.points);
    expect(persisted, before);
    expect(
      tester.widget<MarkerLayer>(find.byType(MarkerLayer)).markers.last.point,
      _end,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
