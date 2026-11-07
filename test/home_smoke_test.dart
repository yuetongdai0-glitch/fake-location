import 'package:fake_location/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('首屏正常渲染，定位成功后显示坐标与操作按钮', (tester) async {
    SharedPreferences.setMockInitialValues({});

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('fake_location/mock'),
      (call) async {
        switch (call.method) {
          case 'isRunning':
            return false;
          case 'getLocation':
            return <String, dynamic>{
              'lat': 29.750134,
              'lng': 106.583211,
              'accuracy': 12.0,
              'provider': 'gps',
              'mock': false,
            };
          default:
            return null;
        }
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('fake_location/update'),
      (call) async => call.method == 'version'
          ? <String, dynamic>{'versionName': '1.1.0', 'versionCode': 5}
          : null,
    );

    await tester.pumpWidget(const FakeLocationApp());
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('开始模拟'), findsOneWidget);
    expect(find.text('未启动'), findsOneWidget);
    expect(find.text('搜索地点，或输入 29.75,106.58'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 卸载组件，确保所有计时器被清理
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('小屏手机（360x640）下底部面板不溢出', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('fake_location/mock'),
      (call) async => call.method == 'getLocation'
          ? <String, dynamic>{
              'lat': 29.750134,
              'lng': 106.583211,
              'accuracy': 40.0,
              'provider': 'network',
              'mock': false,
            }
          : null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('fake_location/update'),
      (call) async => call.method == 'version'
          ? <String, dynamic>{'versionName': '1.1.0', 'versionCode': 5}
          : null,
    );

    await tester.pumpWidget(const FakeLocationApp());
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('开始模拟'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
