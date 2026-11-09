import 'dart:async';

import 'package:fake_location/main.dart';
import 'package:fake_location/ui/app_update_sheet.dart';
import 'package:fake_location/ui/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _mockChannel = MethodChannel('fake_location/mock');
const _updateChannel = MethodChannel('fake_location/update');

/// 复用原生已存在的下载快照，集成验证不访问公网，也不触发真实下载。
Map<String, Object> _downloading(int progress) => {
  'state': 'downloading',
  'operationId': 7,
  'versionCode': 17,
  'versionName': '1.4.3',
  'receivedBytes': progress * 100,
  'totalBytes': 10000,
  'progress': progress,
  'canInstall': false,
};

/// 提供真实首页所需的两条通道；仅拦截系统边界，不调用页面私有方法。
class _NativeBridge {
  final mockCalls = <String>[];
  final updateCalls = <String>[];
  Map<String, Object>? status = _downloading(25);
  bool versionAvailable = true;
  String? blockedMethod;
  final pendingLocation = Completer<Object?>();

  void install() {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_mockChannel, (call) async {
      mockCalls.add(call.method);
      if (call.method == blockedMethod) return pendingLocation.future;
      if (call.method == 'isRunning') return false;
      if (call.method == 'getLocation') {
        return <String, Object>{
          'lat': 29.75,
          'lng': 106.58,
          'accuracy': 5.0,
          'provider': 'gps',
          'mock': false,
        };
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_updateChannel, (call) async {
      updateCalls.add(call.method);
      if (call.method == 'version') {
        return versionAvailable
            ? <String, Object>{
                'versionName': '1.4.2',
                'versionCode': 16,
                'sdkInt': 36,
              }
            : null;
      }
      if (call.method == 'status') return status;
      return null;
    });
  }

  void dispose() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_mockChannel, null);
    messenger.setMockMethodCallHandler(_updateChannel, null);
  }
}

/// 模拟原生主动推送进度，经过与真机一致的 MethodChannel 解码和监听链路。
Future<void> _emitUpdate(Map<String, Object> snapshot) async {
  final delivered = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        _updateChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('updateStatus', snapshot),
        ),
        (_) => delivered.complete(),
      );
  await delivered.future;
}

/// 通过抽屉进入设置，再滚动到更新入口，覆盖懒构建列表中的真实入口。
Future<void> _openSettingsUpdate(WidgetTester tester) async {
  await tester.tap(find.byTooltip('菜单'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('设置'));
  await tester.pumpAndSettle();
  final settingsList = find.descendant(
    of: find.byType(SettingsSheet),
    matching: find.byType(ListView),
  );
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('settings-app-update')),
    400,
    scrollable: find
        .descendant(of: settingsList, matching: find.byType(Scrollable))
        .first,
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final method in ['requestPermissions', 'getLocation']) {
    testWidgets('$method 尚未返回时已读取应用版本，更新不等待定位', (tester) async {
      final bridge = _NativeBridge()..blockedMethod = method;
      bridge.install();
      addTearDown(bridge.dispose);
      await tester.pumpWidget(const FakeLocationApp());
      await tester.pump(const Duration(milliseconds: 500));

      expect(bridge.mockCalls, contains(method));
      expect(bridge.pendingLocation.isCompleted, isFalse);
      expect(bridge.updateCalls, contains('version'));
      expect(bridge.updateCalls, contains('status'));
      // 原生恢复下载可以只有版本元数据，不能强行解引用尚未下载的清单。
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('菜单'));
      await tester.pumpAndSettle();
      expect(find.text('版本 1.4.2'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      bridge.pendingLocation.complete(null);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('设置打开后实时显示下载进度，关闭重开仍保留同一更新状态', (tester) async {
    final bridge = _NativeBridge();
    bridge.install();
    addTearDown(bridge.dispose);
    await tester.pumpWidget(const FakeLocationApp());
    await tester.pumpAndSettle();
    await _openSettingsUpdate(tester);
    expect(find.text('虚拟定位 1.4.2'), findsOneWidget);
    expect(find.text('下载中 25%'), findsOneWidget);

    bridge.status = _downloading(62);
    await _emitUpdate(bridge.status!);
    await tester.pump();
    expect(find.text('下载中 62%'), findsOneWidget);
    expect(find.text('下载中 25%'), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsSheet), findsNothing);
    await _openSettingsUpdate(tester);
    expect(find.text('下载中 62%'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-app-update')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AppUpdateSheet), findsOneWidget);
    expect(find.text('当前版本 1.4.2'), findsOneWidget);
    expect(find.text('新版本 1.4.3'), findsOneWidget);
    expect(find.textContaining('62%'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('版本读取失败保留错误，设置与更新面板均不误报最新版', (tester) async {
    final bridge = _NativeBridge()
      ..versionAvailable = false
      ..status = null;
    bridge.install();
    addTearDown(bridge.dispose);
    await tester.pumpWidget(const FakeLocationApp());
    await tester.pumpAndSettle();
    await _openSettingsUpdate(tester);
    expect(find.text('无法读取当前版本，请重试'), findsOneWidget);
    expect(find.text('已是最新版'), findsNothing);
    expect(find.text('已是最新版本'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-app-update')));
    await tester.pumpAndSettle();
    final sheet = find.byType(AppUpdateSheet);
    expect(sheet, findsOneWidget);
    expect(
      find.descendant(of: sheet, matching: find.text('无法读取当前版本，请重试')),
      findsOneWidget,
    );
    expect(find.text('已是最新版'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
