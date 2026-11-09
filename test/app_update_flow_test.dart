import 'dart:async';
import 'dart:convert';

import 'package:fake_location/core/app_update.dart';
import 'package:fake_location/core/app_update_controller.dart';
import 'package:fake_location/ui/app_update_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const channel = MethodChannel('fake_location/update');

Map<String, Object> manifest({int code = 16, String? hash}) => {
  'appId': 'com.rz.fake_location',
  'android': {
    'versionName': '1.4.${code - 14}',
    'versionCode': code,
    'minSdk': 24,
    'apkBytes': 1000,
    'sha256': hash ?? 'a' * 64,
    'apkUrl':
        'https://yuetongdai0-glitch.github.io/fake-location-releases/releases/android/latest.apk?v=$code',
  },
};
AppUpdate update({int code = 16}) => AppUpdate.fromJson(manifest(code: code));

Future<void> emit(Map<String, Object> snapshot) async {
  final complete = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('updateStatus', snapshot),
        ),
        (_) => complete.complete(),
      );
  await complete.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('并发比较同仓库三入口，缓存旧版本不能盖住新版本', () async {
    final requests = <http.Request>[];
    final result = await fetchLatestUpdate(
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode(
            manifest(code: request.url.host == 'api.github.com' ? 17 : 16),
          ),
          200,
        );
      }),
    );
    expect(result.versionCode, 17);
    expect(requests, hasLength(3));
    expect(
      requests.every((r) => r.headers['Cache-Control']!.contains('no-store')),
      isTrue,
    );
  });

  test('单入口失败时可继续，最高版本摘要冲突不会任选一包', () async {
    final fallback = await fetchLatestUpdate(
      client: MockClient(
        (request) async => http.Response(
          request.url.host == 'raw.githubusercontent.com'
              ? jsonEncode(manifest())
              : '<html>失败</html>',
          request.url.host == 'raw.githubusercontent.com' ? 200 : 503,
        ),
      ),
    );
    expect(fallback.versionCode, 16);
    await expectLater(
      fetchLatestUpdate(
        client: MockClient(
          (request) async => http.Response(
            jsonEncode(
              manifest(
                hash: request.url.host == 'api.github.com' ? 'b' * 64 : null,
              ),
            ),
            200,
          ),
        ),
      ),
      throwsA(
        isA<FormatException>().having((e) => e.message, '原因', contains('不一致')),
      ),
    );
  });

  test('三入口共用时限，错误页或跳转不能冒充最新', () async {
    final never = Completer<http.Response>();
    await expectLater(
      fetchLatestUpdate(
        client: MockClient((_) => never.future),
        timeout: const Duration(milliseconds: 20),
      ),
      throwsFormatException,
    );
    final calls = <Uri>[];
    await expectLater(
      fetchLatestUpdate(
        client: MockClient((request) async {
          calls.add(request.url);
          return http.Response(
            '',
            302,
            headers: {'location': 'https://example.com/update.json'},
          );
        }),
      ),
      throwsFormatException,
    );
    expect(calls, hasLength(3));
    expect(calls.every((uri) => uri.host != 'example.com'), isTrue);
  });

  test('安装包来源限制到自己的发行路径，不接受其他GitHub仓库', () {
    for (final url in [
      'https://someone.github.io/fake-location-releases/releases/android/latest.apk',
      'https://raw.githubusercontent.com/other/fake-location-releases/main/releases/android/latest.apk',
      'https://github.com/yuetongdai0-glitch/other/raw/main/latest.apk',
      'https://yuetongdai0-glitch.github.io:8443/fake-location-releases/releases/android/latest.apk',
    ]) {
      final json = manifest();
      (json['android'] as Map)['apkUrl'] = url;
      expect(() => AppUpdate.fromJson(json), throwsFormatException);
    }
  });

  test('官方接口安装包仅接受本仓库main单文件，允许缓存标记', () {
    const valid =
        'https://api.github.com/repos/yuetongdai0-glitch/fake-location-releases/contents/releases/android/latest.apk?ref=main';
    expect(isTrustedUpdateApk(Uri.parse(valid)), isTrue);
    expect(isTrustedUpdateApk(Uri.parse('$valid&_=123')), isTrue);
    for (final invalid in [
      valid.replaceFirst('fake-location-releases', 'other-repository'),
      valid.replaceFirst('yuetongdai0-glitch', 'other-owner'),
      valid.replaceFirst('latest.apk', 'other.apk'),
      valid.replaceFirst('ref=main', 'ref=dev'),
      valid.replaceFirst('?ref=main', ''),
      '$valid&ref=dev',
      '$valid&ref=main',
      '$valid&download_url=https://example.com/other.apk',
      '$valid&_=1&_=2',
    ]) {
      expect(isTrustedUpdateApk(Uri.parse(invalid)), isFalse, reason: invalid);
    }
  });

  test('版本读取失败明确报错，重新检查恢复且并发检查只发一次请求', () async {
    var validVersion = false;
    var loads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'version') {
        return validVersion
            ? {'versionName': '1.4.1', 'versionCode': 15, 'sdkInt': 36}
            : null;
      }
      return {'state': 'idle'};
    });
    final pending = Completer<AppUpdate>();
    final controller = AppUpdateController(
      loadLatest: () {
        loads++;
        return pending.future;
      },
    );
    addTearDown(controller.dispose);
    await expectLater(controller.check(), throwsFormatException);
    expect(controller.state.phase, AppUpdatePhase.error);
    expect(controller.state.error, contains('当前版本'));
    expect(loads, 0);
    validVersion = true;
    final first = controller.check();
    final second = controller.check(manual: true);
    expect(identical(first, second), isTrue);
    await Future<void>.delayed(Duration.zero);
    pending.complete(update());
    expect((await first)?.versionCode, 16);
    expect((await second)?.versionCode, 16);
    expect(loads, 1);
    expect(controller.state.phase, AppUpdatePhase.available);
  });

  test('原生进度先到时不会被旧命令响应覆盖，取消及缓存安装可重试', () async {
    final downloadingResponse = Completer<Map<String, Object>>();
    var downloads = 0;
    var installs = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'version') {
        return {'versionName': '1.4.1', 'versionCode': 15};
      }
      if (call.method == 'download') {
        downloads++;
        expect((call.arguments as Map)['apkBytes'], 1000);
        return downloadingResponse.future;
      }
      if (call.method == 'cancelDownload') {
        return {'state': 'cancelled', 'operationId': 1, 'versionCode': 16};
      }
      if (call.method == 'install') {
        installs++;
        return {
          'state': 'permission',
          'operationId': 2,
          'versionCode': 16,
          'canInstall': true,
        };
      }
      return {'state': 'idle'};
    });
    final controller = AppUpdateController(loadLatest: () async => update());
    addTearDown(controller.dispose);
    await controller.check();
    final download = controller.download();
    await emit({
      'state': 'downloading',
      'operationId': 1,
      'versionCode': 16,
      'receivedBytes': 500,
      'totalBytes': 1000,
      'progress': 50,
    });
    downloadingResponse.complete({
      'state': 'downloading',
      'operationId': 1,
      'versionCode': 16,
      'receivedBytes': 0,
      'progress': 0,
    });
    await download;
    expect(controller.state.receivedBytes, 500);
    expect(controller.state.progress, 50);
    await controller.cancel();
    expect(controller.state.phase, AppUpdatePhase.cancelled);
    await emit({
      'state': 'ready',
      'operationId': 2,
      'versionCode': 16,
      'canInstall': true,
    });
    await emit({
      'state': 'downloading',
      'operationId': 1,
      'versionCode': 16,
      'progress': 5,
    });
    expect(controller.state.phase, AppUpdatePhase.ready);
    await controller.install();
    expect(controller.state.phase, AppUpdatePhase.permission);
    await controller.install();
    expect(installs, 2);
    expect(downloads, 1);
  });

  test('重开可恢复已校验缓存与授权阶段，不重复联网或下载', () async {
    var loads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'version') {
        return {'versionName': '1.4.1', 'versionCode': 15};
      }
      return {
        'state': 'permission',
        'versionName': '1.4.2',
        'versionCode': 16,
        'operationId': 1,
        'canInstall': true,
      };
    });
    final controller = AppUpdateController(
      loadLatest: () async {
        loads++;
        return update();
      },
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.state.phase, AppUpdatePhase.permission);
    expect(controller.state.availableVersionName, '1.4.2');
    expect(controller.hasUpdate, isTrue);
    expect(controller.state.canInstall, isTrue);
    expect(loads, 0);
  });

  test('恢复缓存校验失败时显示错误，重新检查后可正常下载', () async {
    var downloads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'version') {
        return {'versionName': '1.4.1', 'versionCode': 15};
      }
      if (call.method == 'download') {
        downloads++;
        return {
          'state': 'downloading',
          'versionCode': 16,
          'operationId': 2,
          'revision': 4,
        };
      }
      return {'state': 'idle'};
    });
    final controller = AppUpdateController(loadLatest: () async => update());
    addTearDown(controller.dispose);
    await emit({
      'state': 'verifying',
      'versionCode': 0,
      'operationId': 1,
      'revision': 1,
    });
    expect(controller.state.phase, AppUpdatePhase.verifying);
    await emit({
      'state': 'error',
      'versionCode': 0,
      'operationId': 1,
      'revision': 2,
      'error': '安装包已失效，请重新检查更新',
      'canInstall': false,
    });
    expect(controller.state.phase, AppUpdatePhase.error);
    expect(controller.state.update, isNull);
    expect(controller.state.error, '安装包已失效，请重新检查更新');
    expect(controller.state.canInstall, isFalse);
    expect(controller.hasUpdate, isFalse);
    await controller.check(manual: true);
    expect(controller.state.phase, AppUpdatePhase.available);
    await controller.download();
    expect(downloads, 1);
    expect(controller.state.phase, AppUpdatePhase.downloading);
  });

  test('仅有原生版本的坏缓存重试会先取清单，显式不可安装优先于阶段', () async {
    var checks = 0;
    var downloads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'version') {
        return {'versionName': '1.4.1', 'versionCode': 15};
      }
      if (call.method == 'download') {
        downloads++;
        expect((call.arguments as Map)['sha256'], 'a' * 64);
        return {
          'state': 'downloading',
          'versionCode': 16,
          'operationId': 2,
          'revision': 4,
        };
      }
      return {
        'state': 'permission',
        'versionName': '1.4.2',
        'versionCode': 16,
        'operationId': 1,
        'revision': 1,
        'canInstall': true,
      };
    });
    final controller = AppUpdateController(
      loadLatest: () async {
        checks++;
        return update();
      },
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.state.update, isNull);
    expect(controller.state.canInstall, isTrue);
    await emit({
      'state': 'ready',
      'versionCode': 16,
      'operationId': 1,
      'revision': 2,
      'canInstall': false,
    });
    expect(controller.state.canInstall, isFalse);
    await emit({
      'state': 'error',
      'versionCode': 16,
      'versionName': '1.4.2',
      'operationId': 1,
      'revision': 3,
      'canInstall': false,
      'error': '安装包已失效，请重新检查更新',
    });
    expect(controller.state.update, isNull);
    await controller.download();
    expect(checks, 1);
    expect(downloads, 1);
    expect(controller.state.phase, AppUpdatePhase.downloading);
  });

  test('安装调用异常后清除过期可安装标记并同步原生错误', () async {
    var statuses = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'version') {
        return {'versionName': '1.4.1', 'versionCode': 15};
      }
      if (call.method == 'install') {
        throw PlatformException(code: 'UPDATE_FAILED', message: '安装包已失效');
      }
      if (call.method == 'status') {
        statuses++;
        return {
          'state': 'error',
          'versionCode': 16,
          'operationId': 1,
          'revision': 2,
          'canInstall': false,
          'error': '安装包已失效，请重新检查更新',
        };
      }
      return {'state': 'idle'};
    });
    final controller = AppUpdateController(loadLatest: () async => update());
    addTearDown(controller.dispose);
    await controller.check();
    await emit({
      'state': 'ready',
      'versionCode': 16,
      'operationId': 1,
      'revision': 1,
      'canInstall': true,
    });
    await controller.install();
    expect(statuses, 1);
    expect(controller.state.phase, AppUpdatePhase.error);
    expect(controller.state.canInstall, isFalse);
    expect(controller.state.error, contains('已失效'));
  });

  test('旧清单不能降级已验证原生缓存，更高版本仍可替换', () async {
    var manifestCode = 15;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'version') {
        return {'versionName': '1.4.1', 'versionCode': 15};
      }
      return {
        'state': 'permission',
        'versionName': '1.4.2',
        'versionCode': 16,
        'operationId': 1,
        'revision': 1,
        'canInstall': true,
      };
    });
    final controller = AppUpdateController(
      loadLatest: () async => update(code: manifestCode),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.state.update, isNull);
    expect(controller.state.canInstall, isTrue);
    await controller.check(manual: true);
    expect(controller.state.phase, AppUpdatePhase.ready);
    expect(controller.state.availableVersionName, '1.4.2');
    expect(controller.state.canInstall, isTrue);
    expect(controller.hasUpdate, isTrue);
    await emit({
      'state': 'ready',
      'versionCode': 16,
      'versionName': '1.4.2',
      'operationId': 1,
      'revision': 2,
      'canInstall': true,
    });
    expect(controller.state.phase, AppUpdatePhase.ready);
    manifestCode = 17;
    expect((await controller.check(manual: true))?.versionCode, 17);
    expect(controller.state.phase, AppUpdatePhase.available);
    expect(controller.state.update?.versionCode, 17);
    expect(controller.state.canInstall, isFalse);
    await emit({
      'state': 'ready',
      'versionCode': 16,
      'operationId': 1,
      'revision': 3,
      'canInstall': true,
    });
    expect(controller.state.update?.versionCode, 17);
    expect(controller.state.phase, AppUpdatePhase.available);
  });

  test('系统不支持新版时保留错误，不宣称当前已是最新', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'version') {
        return {'versionName': '1.4.1', 'versionCode': 15, 'sdkInt': 24};
      }
      return {'state': 'idle'};
    });
    final data = manifest();
    (data['android'] as Map)['minSdk'] = 36;
    final controller = AppUpdateController(
      loadLatest: () async => AppUpdate.fromJson(data),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.state.phase, AppUpdatePhase.error);
    expect(controller.state.error, '新版暂不支持当前系统');
  });

  testWidgets('更新面板显示下载进度和持久错误，小屏大字号可重试安装', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'version') {
        return {'versionName': '1.4.1', 'versionCode': 15};
      }
      return {'state': 'idle'};
    });
    final controller = AppUpdateController(loadLatest: () async => update());
    addTearDown(controller.dispose);
    await controller.check();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Scaffold(body: AppUpdateSheet(controller: controller)),
      ),
    );
    await tester.pump();
    await emit({
      'state': 'downloading',
      'operationId': 1,
      'versionCode': 16,
      'receivedBytes': 500,
      'totalBytes': 1000,
      'progress': 50,
    });
    await tester.pump();
    expect(find.textContaining('50%'), findsOneWidget);
    expect(find.byKey(const ValueKey('app-update-cancel')), findsOneWidget);
    await emit({
      'state': 'error',
      'operationId': 1,
      'versionCode': 16,
      'error': '下载中断，请重试',
    });
    await tester.pump();
    expect(find.text('下载中断，请重试'), findsOneWidget);
    expect(find.text('重新下载'), findsOneWidget);
    await emit({
      'state': 'ready',
      'operationId': 2,
      'versionCode': 16,
      'canInstall': true,
    });
    await tester.pump();
    expect(find.text('安装更新'), findsOneWidget);
    expect(find.text('当前版本 1.4.1'), findsOneWidget);
    expect(find.text('新版本 1.4.2'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
