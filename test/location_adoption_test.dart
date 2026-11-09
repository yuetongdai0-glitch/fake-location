import 'dart:async';
import 'dart:convert';

import 'package:fake_location/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _selected = LatLng(39.9, 116.4);
const _actualWgs = LatLng(29.73358, 106.54364);

Map<String, Object?> _actualFix() => {
  'lat': _actualWgs.latitude,
  'lng': _actualWgs.longitude,
  'accuracy': 5.0,
  'provider': 'gps',
  'mock': false,
};

/// 直接驱动地图的公开选点回调，检查最终发给原生的坐标，避免只验证文案。
Future<void> _select(WidgetTester tester, LatLng point) async {
  tester.widget<FlutterMap>(find.byType(FlutterMap)).options.onTap!(
    const TapPosition(Offset.zero, Offset.zero),
    point,
  );
  await tester.pump();
}

LatLng _target(WidgetTester tester) => tester
    .widgetList<MarkerLayer>(find.byType(MarkerLayer))
    .last
    .markers
    .single
    .point;

void main() {
  testWidgets('首次定位尚未返回时直接开始，也不能把已启动目标改回真实点', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final pending = Completer<Map<String, Object?>>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('fake_location/mock');
    const updates = MethodChannel('fake_location/update');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isRunning') return false;
      if (call.method == 'getLocation') return pending.future;
      return null;
    });
    messenger.setMockMethodCallHandler(updates, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(updates, null);
    });
    await tester.pumpWidget(const FakeLocationApp());
    await tester.pump();
    final before = _target(tester);
    await tester.tap(find.text('开始模拟'));
    await tester.pump();
    pending.complete(_actualFix());
    await tester.pump();
    await tester.pump();
    expect(_target(tester), before);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  for (final startBeforeFix in [false, true]) {
    testWidgets('首次定位迟到不覆盖手选点${startBeforeFix ? '及已启动的目标' : '，未启动也保留'}', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final pending = Completer<Map<String, Object?>>();
      final sends = <Map<Object?, Object?>>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('fake_location/mock');
      const updates = MethodChannel('fake_location/update');
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'isRunning') return false;
        if (call.method == 'getLocation') return pending.future;
        if (call.method == 'start') {
          sends.add(Map<Object?, Object?>.from(call.arguments as Map));
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
      await _select(tester, _selected);
      if (startBeforeFix) {
        await tester.tap(find.text('开始模拟'));
        await tester.pump();
      }
      pending.complete(_actualFix());
      await tester.pump();
      await tester.pump();
      expect(_target(tester), _selected);
      // 位置读回仍可更新蓝点，但不能改变用户的目标或随后发送的坐标。
      final actual = tester
          .widgetList<MarkerLayer>(find.byType(MarkerLayer))
          .first
          .markers
          .single
          .point;
      expect(
        actual.latitude,
        closeTo(Coord.wgsToGcj(_actualWgs).latitude, 1e-9),
      );
      await tester.tap(find.text(startBeforeFix ? '更新到此位置' : '开始模拟'));
      await tester.pump();
      final expected = Coord.gcjToWgs(_selected);
      expect(sends.last['lat'], closeTo(expected.latitude, 1e-9));
      expect(sends.last['lng'], closeTo(expected.longitude, 1e-9));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
    });
  }

  testWidgets('权限请求期间已手选目标，后续首次定位不能接管它', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final permissions = Completer<void>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('fake_location/mock');
    const updates = MethodChannel('fake_location/update');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isRunning') return false;
      if (call.method == 'requestPermissions') {
        await permissions.future;
        return null;
      }
      if (call.method == 'getLocation') return _actualFix();
      return null;
    });
    messenger.setMockMethodCallHandler(updates, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(updates, null);
    });
    await tester.pumpWidget(const FakeLocationApp());
    await tester.pump();
    await _select(tester, _selected);
    permissions.complete();
    await tester.pump();
    await tester.pump();
    expect(_target(tester), _selected);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('没有用户选点时，首次定位仍正常设为目标', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('fake_location/mock');
    const updates = MethodChannel('fake_location/update');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isRunning') return false;
      if (call.method == 'getLocation') return _actualFix();
      return null;
    });
    messenger.setMockMethodCallHandler(updates, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(updates, null);
    });
    await tester.pumpWidget(const FakeLocationApp());
    await tester.pump();
    expect(_target(tester), Coord.wgsToGcj(_actualWgs));
    expect(find.text('当前位置'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('权限尚未返回时已经开始模拟，初始化不能再采用真实点', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final permissions = Completer<void>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('fake_location/mock');
    const updates = MethodChannel('fake_location/update');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isRunning') return false;
      if (call.method == 'requestPermissions') {
        await permissions.future;
        return null;
      }
      if (call.method == 'getLocation') return _actualFix();
      return null;
    });
    messenger.setMockMethodCallHandler(updates, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(updates, null);
    });
    await tester.pumpWidget(const FakeLocationApp());
    await tester.pump();
    final before = _target(tester);
    await tester.tap(find.text('开始模拟'));
    await tester.pump();
    permissions.complete();
    await tester.pump();
    await tester.pump();
    expect(_target(tester), before);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('显式定位等待期间重新选点，迟到结果不改目标也不移动镜头', (tester) async {
    SharedPreferences.setMockInitialValues({
      'app_config_v1': jsonEncode({'lastLat': 30.0, 'lastLng': 110.0}),
    });
    final pending = Completer<Map<String, Object?>>();
    var reads = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('fake_location/mock');
    const updates = MethodChannel('fake_location/update');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isRunning') return false;
      if (call.method == 'getLocation') {
        reads++;
        return reads == 1 ? null : pending.future;
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
    await tester.tap(find.byTooltip('定位到当前位置'));
    await tester.pump();
    await _select(tester, _selected);
    final controller = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!;
    controller.move(_selected, 17);
    await tester.pump();
    pending.complete(_actualFix());
    await tester.pump();
    await tester.pump();
    expect(_target(tester), _selected);
    expect(
      controller.camera.center.latitude,
      closeTo(_selected.latitude, 1e-8),
    );
    expect(
      controller.camera.center.longitude,
      closeTo(_selected.longitude, 1e-8),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
