import 'dart:async';
import 'dart:io';

import 'package:fake_location/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('英文网络异常、超时和服务器状态均返回中文', () {
    expect(userMessage(TimeoutException('Request timed out')), '请求超时，请检查网络后重试');
    for (final error in [
      const SocketException('Failed host lookup: example.invalid'),
      http.ClientException('Connection closed before full header'),
      const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
    ]) {
      expect(userMessage(error), '网络连接失败，请检查网络后重试');
    }
    expect(userMessage(const HttpException('Forbidden')), '网络请求失败，请稍后重试');
    expect(
      userMessage(Exception('HTTP 503: Service unavailable')),
      '网络请求失败，请稍后重试',
    );
  });

  test('解析失败不暴露格式异常及无效输入', () {
    expect(
      userMessage(
        const FormatException('Unexpected character', 'private data'),
      ),
      '数据格式不正确，请检查后重试',
    );
    expect(userMessage(const FormatException('纬度超出范围')), '纬度超出范围');
  });

  test('常见平台错误使用中文说明，未知错误不回显内部代码', () {
    expect(
      userMessage(
        PlatformException(code: 'NO_PERMISSION', message: 'Permission denied'),
      ),
      '尚未获得所需权限，请在系统设置中授权',
    );
    expect(
      userMessage(
        PlatformException(code: 'NOT_INSTALLED', message: 'Package not found'),
      ),
      '尚未安装目标应用',
    );
    expect(
      userMessage(
        PlatformException(
          code: 'INTERNAL_STACK_TRACE',
          message: 'java.lang.IllegalStateException',
        ),
      ),
      '操作失败，请稍后重试',
    );
    expect(
      userMessage(MissingPluginException('No implementation found')),
      '当前设备暂不支持此操作',
    );
  });

  test('已中文的简短提示保留，混合异常、路径及多行堆栈使用兜底', () {
    expect(
      userMessage(PlatformException(code: 'BAD_ARGS', message: '路线至少需要两个点')),
      '路线至少需要两个点',
    );
    expect(userMessage(Exception('暂时无法连接，请重试')), '暂时无法连接，请重试');
    for (final error in [
      Exception('定位失败：IllegalStateException'),
      Exception('无法读取 /用户/私密文件'),
      Exception('定位失败\n内部调用栈'),
      StateError('private internal state'),
    ]) {
      expect(userMessage(error, fallback: '获取位置失败，请稍后重试'), '获取位置失败，请稍后重试');
    }
  });

  testWidgets('英文系统环境下复制粘贴与弹层关闭文案仍为简体中文', (tester) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale(
      'en',
      'US',
    );
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const mockChannel = MethodChannel('fake_location/mock');
    const updateChannel = MethodChannel('fake_location/update');
    messenger.setMockMethodCallHandler(mockChannel, (call) async {
      if (call.method == 'isRunning') return false;
      if (call.method == 'getLocation') {
        return <String, dynamic>{
          'lat': 29.75,
          'lng': 106.58,
          'accuracy': 5.0,
          'provider': 'gps',
          'mock': false,
        };
      }
      return null;
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
    final context = tester.element(find.byType(Scaffold).first);
    final messages = MaterialLocalizations.of(context);
    expect(Localizations.localeOf(context), const Locale('zh', 'CN'));
    expect(messages.copyButtonLabel, '复制');
    expect(messages.pasteButtonLabel, '粘贴');
    expect(messages.selectAllButtonLabel, '全选');
    expect(messages.modalBarrierDismissLabel, '关闭');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
