import 'dart:async';
import 'dart:convert';

import 'package:fake_location/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('WiFi 不阻断开始，推送暂失败时仍可停止自动恢复中的服务', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var started = false;
    var stopped = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const mockChannel = MethodChannel('fake_location/mock');
    const updateChannel = MethodChannel('fake_location/update');
    messenger.setMockMethodCallHandler(mockChannel, (call) async {
      switch (call.method) {
        case 'isRunning':
          return false;
        case 'start':
          started = true;
          return null;
        case 'stop':
          stopped = true;
          return null;
        case 'getLocation':
          return <String, dynamic>{
            'lat': 29.75,
            'lng': 106.58,
            'accuracy': 5.0,
            'provider': 'gps',
            'mock': false,
          };
        case 'wifiStatus':
          return <String, dynamic>{'enabled': true, 'interfering': true};
        case 'mockStatus':
          return <String, dynamic>{
            'serviceActive': true,
            'running': false,
            'pushCount': 1,
            'mockApp': true,
            'elapsedMs': 100,
            'providers': <String>[],
            'expectedProviders': ['gps', 'network'],
            'providerErrors': {'gps': '暂时失败', 'network': '暂时失败'},
          };
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(
      updateChannel,
      (call) async => call.method == 'version'
          ? <String, dynamic>{'versionName': '1.3.5', 'versionCode': 12}
          : null,
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(mockChannel, null);
      messenger.setMockMethodCallHandler(updateChannel, null);
    });

    await tester.pumpWidget(const FakeLocationApp());
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('开始模拟'));
    await tester.pump();
    expect(started, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('更新到此位置'), findsOneWidget);
    expect(find.text('模拟已停止，定位已恢复'), findsNothing);
    final stop = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '停止'),
    );
    expect(stop.onPressed, isNotNull);
    await tester.tap(find.text('停止'));
    await tester.pump();
    expect(stopped, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final readAlreadyPending in [false, true]) {
    testWidgets(
      '${readAlreadyPending ? '检测读回已在等待时' : '自动检测开始前'}停止，旧检测不恢复运行状态',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'app_config_v1': jsonEncode({'lastLat': 39.9, 'lastLng': 116.4}),
        });
        final pendingCache = Completer<Map<String, dynamic>>();
        final locations = <Map<Object?, Object?>>[];
        var stops = 0;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const channel = MethodChannel('fake_location/mock');
        const updates = MethodChannel('fake_location/update');
        messenger.setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'isRunning':
              return false;
            case 'stop':
              stops++;
              return null;
            case 'getLocation':
              final arguments = Map<Object?, Object?>.from(
                call.arguments as Map,
              );
              locations.add(arguments);
              if (arguments['cachedOnly'] == true) return pendingCache.future;
              return <String, dynamic>{
                'lat': 39.9,
                'lng': 116.4,
                'accuracy': 5.0,
                'provider': 'gps',
                'mock': false,
              };
            case 'mockStatus':
              // 故意返回停止前快照，证明迟到的校验不能覆盖用户的新操作。
              return <String, dynamic>{
                'serviceActive': true,
                'running': true,
                'mockApp': true,
                'pushCount': 10,
                'elapsedMs': 100,
                'providers': ['gps'],
                'expectedProviders': ['gps'],
              };
            default:
              return null;
          }
        });
        messenger.setMockMethodCallHandler(updates, (_) async => null);
        addTearDown(() {
          messenger.setMockMethodCallHandler(channel, null);
          messenger.setMockMethodCallHandler(updates, null);
        });

        await tester.pumpWidget(const FakeLocationApp());
        await tester.pump();
        await tester.tap(find.text('开始模拟'));
        await tester.pump();
        expect(find.text('更新到此位置'), findsOneWidget);
        if (readAlreadyPending) {
          await tester.pump(const Duration(milliseconds: 1700));
          expect(
            locations.where((arguments) => arguments['cachedOnly'] == true),
            [
              <Object?, Object?>{'fresh': false, 'cachedOnly': true},
            ],
          );
        }
        await tester.tap(find.text('停止'));
        await tester.pump();
        expect(stops, 1);
        expect(find.text('开始模拟'), findsOneWidget);

        if (readAlreadyPending) {
          pendingCache.complete({'lat': 39.9, 'lng': 116.4, 'mock': true});
        }
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(find.text('开始模拟'), findsOneWidget);
        expect(find.text('更新到此位置'), findsNothing);
        expect(find.text('部分定位源尚未确认生效，请查看检测详情'), findsNothing);
        // 仅停止动作请求一次真实定位，诊断始终只读缓存。
        expect(locations.where((arguments) => arguments['fresh'] == true), [
          <Object?, Object?>{'fresh': true, 'realOnly': true},
        ]);
        expect(
          locations
              .where((arguments) => arguments['cachedOnly'] == true)
              .length,
          readAlreadyPending ? 1 : 0,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('未使用摇杆的隐藏不打断服务，松手与后台切换立即归零且卸载清理计时器', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final manualUpdates = <Map<Object?, Object?>>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('fake_location/mock');
    const updates = MethodChannel('fake_location/update');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isRunning') return true;
      if (call.method == 'start') {
        manualUpdates.add(Map<Object?, Object?>.from(call.arguments as Map));
      }
      return null;
    });
    messenger.setMockMethodCallHandler(updates, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(updates, null);
    });

    await tester.pumpWidget(const FakeLocationApp());
    await tester.pump();
    await tester.tap(find.byTooltip('摇杆移动'));
    await tester.pump();
    await tester.tap(find.byTooltip('关闭摇杆'));
    await tester.pump();
    // 仅显示/隐藏摇杆不能向原生发送静态 start，覆盖既有路线任务。
    expect(manualUpdates, isEmpty);

    await tester.tap(find.byTooltip('摇杆移动'));
    await tester.pump();
    Listener stick() => tester
        .widgetList<Listener>(
          find.ancestor(
            of: find.byIcon(Icons.navigation),
            matching: find.byType(Listener),
          ),
        )
        .lastWhere((listener) => listener.onPointerMove != null);
    expect(find.text('模拟中'), findsOneWidget);
    stick().onPointerDown!(const PointerDownEvent(position: Offset(120, 66)));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(manualUpdates, hasLength(1));
    expect(manualUpdates.single['manualSpeed'], 0);
    await tester.pump(const Duration(seconds: 1));
    expect(manualUpdates, hasLength(1));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    stick().onPointerDown!(const PointerDownEvent(position: Offset(120, 66)));
    stick().onPointerUp!(const PointerUpEvent());
    await tester.pump();
    expect(manualUpdates, hasLength(2));
    expect(manualUpdates.last['manualSpeed'], 0);

    // 模拟按住时页面被销毁，Flutter 的 pending timer 校验应保持通过。
    stick().onPointerDown!(const PointerDownEvent(position: Offset(120, 66)));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(manualUpdates, hasLength(2));
    expect(tester.takeException(), isNull);
  });
}
