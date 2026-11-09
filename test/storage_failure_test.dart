import 'dart:convert';

import 'package:fake_location/core/models.dart';
import 'package:fake_location/core/storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/shared_preferences');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<String, Object> persisted;
  var failWrite = false;
  var throwWrite = false;
  var failReload = false;

  setUp(() {
    SharedPreferences.resetStatic();
    persisted = {};
    failWrite = false;
    throwWrite = false;
    failReload = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAll') {
        if (failReload) throw PlatformException(code: 'unavailable');
        return Map<String, Object>.from(persisted);
      }
      if (throwWrite) throw PlatformException(code: 'disk_error');
      if (failWrite) return false;
      final arguments = Map<String, Object>.from(call.arguments as Map);
      final key = arguments['key']! as String;
      if (call.method == 'remove') {
        persisted.remove(key);
      } else {
        persisted[key] = arguments['value']!;
      }
      return true;
    });
  });

  tearDown(() {
    SharedPreferences.resetStatic();
    messenger.setMockMethodCallHandler(channel, null);
  });

  const oldPlace = SavedPlace(
    id: 'old',
    name: '旧地点',
    gcj: LatLng(30, 120),
    savedAt: 1,
  );

  final writeCases = <String, Future<void> Function(AppStorage)>{
    '配置': (storage) => storage.writeConfig(AppConfig(accuracyMeters: 20)),
    '路线': (storage) => storage.writeRoutes([]),
    '收藏': (storage) => storage.writeFavorites([]),
    '新增最近地点': (storage) =>
        storage.addRecent(const Place(name: '新地点', gcj: LatLng(31, 121))),
    '删除最近地点': (storage) => storage.removeRecent('old'),
  };

  for (final entry in writeCases.entries) {
    test('${entry.key}写入返回false时报告中文失败并重新同步缓存', () async {
      final storage = await AppStorage.load();
      await storage.writeConfig(AppConfig(accuracyMeters: 10));
      await storage.writeRoutes([
        RoutePlan(points: const [LatLng(30, 120), LatLng(31, 121)]),
      ]);
      await storage.writeFavorites([oldPlace]);
      persisted['flutter.recent_places_v1'] = jsonEncode([oldPlace.toJson()]);
      await (await SharedPreferences.getInstance()).reload();
      final before = Map<String, Object>.from(persisted);
      failWrite = true;
      await expectLater(
        entry.value(storage),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            '中文提示',
            contains('失败'),
          ),
        ),
      );
      expect(persisted, before);
      expect(storage.readConfig().accuracyMeters, 10);
      expect(storage.readRoutes(), hasLength(1));
      expect(storage.readFavorites().single.name, '旧地点');
      expect(storage.readRecents().single.name, '旧地点');
    });
  }

  test('清空最近记录返回false时不误报成功也不清空读缓存', () async {
    persisted['flutter.recent_places_v1'] = jsonEncode([oldPlace.toJson()]);
    final storage = await AppStorage.load();
    failWrite = true;
    await expectLater(storage.clearRecents(), throwsFormatException);
    expect(storage.readRecents().single.id, 'old');
    expect(persisted.containsKey('flutter.recent_places_v1'), isTrue);
  });

  test('底层写入异常变为中文错误，成功重试仍可保存', () async {
    final storage = await AppStorage.load();
    throwWrite = true;
    await expectLater(
      storage.writeConfig(AppConfig(accuracyMeters: 20)),
      throwsA(
        isA<FormatException>().having((e) => e.message, '中文提示', '保存配置失败，请重试'),
      ),
    );
    expect(storage.readConfig().accuracyMeters, 5);
    throwWrite = false;
    await storage.writeConfig(AppConfig(accuracyMeters: 20));
    expect(storage.readConfig().accuracyMeters, 20);
  });

  test('写入和重新同步同时失败时仍返回保存失败，不假称恢复成功', () async {
    final storage = await AppStorage.load();
    failWrite = true;
    failReload = true;
    await expectLater(
      storage.writeConfig(AppConfig()),
      throwsA(
        isA<FormatException>().having((e) => e.message, '中文提示', '保存配置失败，请重试'),
      ),
    );
  });
}
