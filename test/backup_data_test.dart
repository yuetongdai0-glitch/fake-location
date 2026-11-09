import 'dart:convert';

import 'package:fake_location/core/backup_data.dart';
import 'package:fake_location/core/models.dart';
import 'package:fake_location/core/storage.dart';
import 'package:fake_location/ui/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

SavedPlace _place(String id) => SavedPlace(
  id: id,
  name: '地点$id',
  gcj: const LatLng(39.9, 116.4),
  address: '测试地址',
  savedAt: 1,
);

RoutePlan _route(String name) => RoutePlan(
  name: name,
  points: const [LatLng(39.9, 116.4), LatLng(39.91, 116.41)],
);

Map<String, Object?> _backup({Map<String, Object?> config = const {}}) => {
  'app': 'fake_location',
  'version': 1,
  'favorites': [_place('新').toJson()],
  'routes': [_route('新路线').toJson()],
  'config': config,
};

void main() {
  test('版本一备份整体预检且保留未导出的当前选点与上次路线', () {
    final last = _route('当前路线');
    final baseline = AppConfig(
      lastTarget: const LatLng(30, 120),
      lastName: '当前目标',
      lastAddress: '当前地址',
      lastRoute: last,
    );
    final parsed = BackupData.parse(
      jsonEncode(_backup(config: {'accuracyMeters': 10, 'motion': 'cycle'})),
      baseline: baseline,
    );
    expect(parsed.favorites.single.id, '新');
    expect(parsed.routes.single.name, '新路线');
    expect(parsed.config.accuracyMeters, 10);
    expect(parsed.config.motion, MotionMode.cycle);
    expect(parsed.config.lastTarget, baseline.lastTarget);
    expect(parsed.config.lastName, '当前目标');
    expect(parsed.config.lastAddress, '当前地址');
    expect(parsed.config.lastRoute, same(last));
    expect(baseline.accuracyMeters, 5);
    expect(baseline.motion, MotionMode.walk);
  });

  test('收藏路线有效时仍拒绝配置的错误类型、越界值与未知枚举', () {
    for (final config in <Map<String, Object?>>[
      {'intervalMs': '坏类型'},
      {'intervalMs': 100.5},
      {'intervalMs': 0},
      {'accuracyMeters': 101},
      {'radiusMeters': -1},
      {'stepFreq': 221},
      {'stepLength': 0},
      {'writeGcj': 'true'},
      {'amapKey': 123},
      {'mapStyle': '不存在'},
    ]) {
      expect(
        () => BackupData.parse(
          jsonEncode(_backup(config: config)),
          baseline: AppConfig(),
        ),
        throwsFormatException,
      );
    }
    expect(
      () => BackupData.parse(
        jsonEncode(_backup(config: {'accuracyMeters': '替换'}))
            .replaceAll('"替换"', '1e400'),
        baseline: AppConfig(),
      ),
      throwsFormatException,
    );
  });

  test('任何一个损坏地点或路线均拒绝整份备份，不静默丢弃', () {
    final badPlace = _backup();
    badPlace['favorites'] = [
      _place('有效').toJson(),
      {'lat': 999, 'lng': 0},
    ];
    final badRoute = _backup();
    badRoute['routes'] = [
      _route('有效').toJson(),
      _route('无效').toJson()..['speed'] = -1,
    ];
    final unknownMode = _backup();
    unknownMode['routes'] = [_route('无效').toJson()..['playMode'] = '不存在'];
    for (final backup in [badPlace, badRoute, unknownMode]) {
      expect(
        () => BackupData.parse(jsonEncode(backup), baseline: AppConfig()),
        throwsFormatException,
      );
    }
  });

  test('拒绝不支持版本及缺少整体数据的备份', () {
    for (final value in [
      _backup()..['version'] = 2,
      _backup()..['app'] = 'other',
      _backup()..remove('routes'),
      _backup()..['config'] = [],
    ]) {
      expect(
        () => BackupData.parse(jsonEncode(value), baseline: AppConfig()),
        throwsFormatException,
      );
    }
  });

  Future<AppStorage> setupStorage() async {
    SharedPreferences.setMockInitialValues({});
    final storage = await AppStorage.load();
    await storage.writeFavorites([_place('旧')]);
    await storage.writeRoutes([_route('旧路线')]);
    await storage.writeConfig(AppConfig(accuracyMeters: 10));
    return storage;
  }

  Future<void> showImport(
    WidgetTester tester,
    AppStorage storage,
    String clipboard,
    Future<void> Function(AppConfig) onConfigChanged,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      return call.method == 'Clipboard.getData' ? {'text': clipboard} : null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsSheet(
            config: storage.readConfig(),
            versionName: '1.3.7',
            availableUpdate: null,
            updateChecked: false,
            checkingUpdate: false,
            updateBusy: false,
            onConfigChanged: onConfigChanged,
            onCheckUpdate: () async => null,
            onInstallUpdate: (_) async {},
            onOpenUrl: (_) async {},
            storage: storage,
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('从剪贴板导入'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('从剪贴板导入'));
    await tester.pumpAndSettle();
  }

  testWidgets('坏配置不会先覆盖有效的收藏与路线，也不调用配置写入', (tester) async {
    final storage = await setupStorage();
    var writes = 0;
    await showImport(
      tester,
      storage,
      jsonEncode(_backup(config: {'accuracyMeters': '坏数据'})),
      (_) async {
        writes++;
      },
    );
    expect(writes, 0);
    expect(storage.readFavorites().single.id, '旧');
    expect(storage.readRoutes().single.name, '旧路线');
    expect(storage.readConfig().accuracyMeters, 10);
    expect(find.text('备份中的模拟精度超出允许范围'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('配置保存失败会恢复之前的收藏、路线与配置', (tester) async {
    final storage = await setupStorage();
    var attempts = 0;
    await showImport(
      tester,
      storage,
      jsonEncode(_backup(config: {'accuracyMeters': 20})),
      (config) async {
        attempts++;
        if (attempts == 1) throw StateError('simulated failure');
      },
    );
    expect(attempts, 2);
    expect(storage.readFavorites().single.id, '旧');
    expect(storage.readRoutes().single.name, '旧路线');
    expect(storage.readConfig().accuracyMeters, 10);
    expect(find.text('导入失败，已恢复原有数据'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
