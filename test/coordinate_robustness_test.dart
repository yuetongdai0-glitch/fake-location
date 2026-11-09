import 'dart:convert';
import 'dart:math' as math;

import 'package:fake_location/core/coord.dart';
import 'package:fake_location/core/coordinate_input.dart';
import 'package:fake_location/core/models.dart';
import 'package:fake_location/core/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> _route({Object? speed = 1.4}) => {
  'speed': speed,
  'playMode': 'once',
  'points': [
    {'lat': 39.9, 'lng': 116.4},
    {'lat': 39.901, 'lng': 116.4},
  ],
};

void main() {
  group('球面数值边界', () {
    test('精确南北极的六十四方向保持唯一且相邻弦长均匀', () {
      const radius = 1000.0;
      const count = 64;
      final expectedChord = 2 * radius * math.sin(math.pi / count);
      for (final latitude in [-90.0, 90.0]) {
        final center = LatLng(latitude, 37);
        final ring = List.generate(count, (i) {
          final angle = i * 2 * math.pi / count;
          return Coord.offsetMeters(
            center,
            north: radius * math.cos(angle),
            east: radius * math.sin(angle),
          );
        });
        expect(
          ring.map((p) => p.longitude.toStringAsFixed(6)).toSet(),
          hasLength(count),
        );
        for (var i = 0; i < count; i++) {
          expect(
            Coord.distanceMeters(ring[i], ring[(i + 1) % count]),
            closeTo(expectedChord, 0.001),
          );
        }
      }
    });

    test('地理网格平移保持合法坐标和指定合位移', () {
      for (final lat in [
        -90.0,
        -89.999,
        -75.0,
        -45.0,
        0.0,
        45.0,
        75.0,
        89.999,
        90.0,
      ]) {
        for (final lng in [
          -180.0,
          -179.999,
          -90.0,
          0.0,
          90.0,
          179.999,
          180.0,
        ]) {
          final origin = LatLng(lat, lng);
          for (final vector in [
            (0.0, 1000.0),
            (1000.0, 0.0),
            (3000.0, 4000.0),
            (-3000.0, -4000.0),
          ]) {
            final moved = Coord.offsetMeters(
              origin,
              north: vector.$1,
              east: vector.$2,
            );
            expect(moved.isValid, isTrue, reason: '$lat,$lng $vector');
            expect(
              Coord.distanceMeters(origin, moved),
              closeTo(
                math.sqrt(vector.$1 * vector.$1 + vector.$2 * vector.$2),
                0.01,
              ),
              reason: '$lat,$lng $vector',
            );
          }
        }
      }
    });

    test('转换数值残差网格受控，但不把模型往返当成真实测量精度', () {
      var maximum = 0.0;
      var samples = 0;
      for (var lat = 2.0; lat <= 54; lat += 4) {
        for (var lng = 73.0; lng <= 136; lng += 9) {
          final origin = LatLng(lat, lng);
          final back = Coord.gcjToWgs(Coord.wgsToGcj(origin));
          maximum = math.max(maximum, Coord.distanceMeters(origin, back));
          samples++;
        }
      }
      expect(samples, 112);
      expect(maximum, lessThan(0.01));
    });

    test('非有限值在运算边界被拒绝，不向地图继续传播', () {
      expect(
        () => Coord.distanceMeters(
          const LatLng(double.nan, 0),
          const LatLng(0, 0),
        ),
        throwsArgumentError,
      );
      expect(
        () => Coord.offsetMeters(const LatLng(0, 0), north: double.infinity),
        throwsArgumentError,
      );
      expect(
        () => Coord.wgsToGcj(const LatLng(0, double.infinity)),
        throwsArgumentError,
      );
      expect(() => Coord.bd09McToGcj(double.nan, 0), throwsArgumentError);
    });

    test('对跖点距离有限并符合独立半周长基准', () {
      const a = LatLng(-8.286297643935697, 98.24959585517934);
      const b = LatLng(8.286297643935697, -81.75040414482066);
      expect(Coord.distanceMeters(a, b), closeTo(math.pi * 6371008.8, 0.5));
    });

    test('穿过日期变更线仍只平移一公里', () {
      const origin = LatLng(0, 179.999);
      final moved = Coord.offsetMeters(origin, east: 1000);
      expect(moved.isValid, isTrue);
      expect(moved.longitude, lessThan(-179.9));
      expect(Coord.distanceMeters(origin, moved), closeTo(1000, 0.001));
    });

    test('跨越北极后坐标仍合法且位移保持一公里', () {
      const origin = LatLng(89.999, 30);
      final moved = Coord.offsetMeters(origin, north: 1000);
      expect(moved.isValid, isTrue);
      expect(Coord.distanceMeters(origin, moved), closeTo(1000, 0.01));
    });

    test('定量基准覆盖赤道四分之一圆与日期线两侧短距', () {
      expect(
        Coord.distanceMeters(const LatLng(0, 0), const LatLng(0, 90)),
        closeTo(math.pi * 6371008.8 / 2, 0.001),
      );
      expect(
        Coord.distanceMeters(const LatLng(0, 179.9), const LatLng(0, -179.9)),
        closeTo(22239.016046706, 0.001),
      );
    });
  });

  group('坐标输入完整性', () {
    test('带方向的度分正确分组，不把分数当作下一坐标', () {
      final point = CoordinateInput.parse('39°54′N 116°23′E');
      expect(point, isNotNull);
      expect(point!.latitude, closeTo(39.9, 1e-12));
      expect(point.longitude, closeTo(116 + 23 / 60, 1e-12));
    });

    test('分钟秒数非法或多余数字必须拒绝', () {
      for (final text in [
        '39°75′N 116°23′E',
        '39°54′75″N 116°23′51″E',
        '39,54,31,116,23,51,2',
        '39N,116N',
        '116N,39E',
        '39°-1′N 116°23′E',
        '12foo,34',
      ]) {
        expect(CoordinateInput.parse(text), isNull, reason: text);
      }
    });

    test('方向前置和混合角度精度仍可读取', () {
      final prefix = CoordinateInput.parse('N39 54 E116 23');
      expect(prefix?.latitude, closeTo(39.9, 1e-12));
      expect(prefix?.longitude, closeTo(116 + 23 / 60, 1e-12));
      final mixed = CoordinateInput.parse('39°54′N 116°23′51″E');
      expect(mixed?.latitude, closeTo(39.9, 1e-12));
      expect(mixed?.longitude, closeTo(116.3975, 1e-12));
    });

    test('零度的负号不能在度分秒换算中丢失', () {
      final point = CoordinateInput.parse('-0°30′, 10°0′');
      expect(point?.latitude, closeTo(-0.5, 1e-12));
    });
  });

  group('导入与持久化数值边界', () {
    test('常用地点拒绝非有限坐标，损坏时间戳不抛异常', () {
      expect(
        SavedPlace.tryFromJson({
          'id': 'x',
          'name': '坏点',
          'lat': double.nan,
          'lng': 1,
        }),
        isNull,
      );
      expect(
        SavedPlace.tryFromJson({
          'id': 'x',
          'name': '坏点',
          'lat': 1,
          'lng': double.infinity,
        }),
        isNull,
      );
      expect(
        () => SavedPlace.tryFromJson({
          'id': 'x',
          'name': '地点',
          'lat': 1,
          'lng': 2,
          'savedAt': double.nan,
        }),
        returnsNormally,
      );
    });

    test('错误路线参数和非有限坐标被拒绝而不是导致整个列表崩溃', () {
      for (final value in [double.nan, double.infinity, -1, 0, '错误类型']) {
        expect(
          RoutePlan.tryFromJson(_route(speed: value)),
          isNull,
          reason: '$value',
        );
      }
      final invalid = _route();
      invalid['points'] = [
        {'lat': double.nan, 'lng': 116.4},
        {'lat': 39.901, 'lng': 116.4},
      ];
      expect(RoutePlan.tryFromJson(invalid), isNull);
      final duplicate = _route();
      duplicate['points'] = [
        {'lat': 39.9, 'lng': 116.4},
        {'lat': 39.9, 'lng': 116.4},
      ];
      expect(RoutePlan.tryFromJson(duplicate), isNull);
      for (final parameter in ['stepFreq', 'stepLength']) {
        for (final value in [double.nan, double.infinity, -1, '错误类型']) {
          final invalidParameter = _route()..[parameter] = value;
          expect(
            RoutePlan.tryFromJson(invalidParameter),
            isNull,
            reason: '$parameter $value',
          );
        }
      }
    });

    test('诊断坏坐标和坏时间保留未知，不伪造有效读回', () {
      final provider = MockProviderReport.fromMap({
        'provider': 'gps',
        'lat': double.nan,
        'lng': 1,
        'ageMs': double.nan,
        'mock': true,
      });
      expect(provider.point, isNull);
      expect(provider.error, '定位源未返回有效坐标');
      expect(provider.ageMs, -1);
      expect(provider.matchesTarget(const LatLng(0, 0)), isFalse);
    });

    test('坏路线不会抹掉同一存储列表中的其它合法路线', () async {
      SharedPreferences.setMockInitialValues({
        'saved_routes_v1': jsonEncode([_route(speed: '坏参数'), _route()]),
      });
      final routes = (await AppStorage.load()).readRoutes();
      expect(routes.length, 1);
      expect(routes.single.isValid, isTrue);
    });

    test('删除最近地点后重开存储不会复活', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await AppStorage.load();
      await storage.addRecent(const Place(name: '保留', gcj: LatLng(0, 1)));
      await storage.addRecent(const Place(name: '删除', gcj: LatLng(0, 2)));
      final removedId = storage.readRecents().first.id;
      await storage.removeRecent(removedId);
      final reopened = await AppStorage.load();
      expect(reopened.readRecents().map((place) => place.name), ['保留']);
    });

    test('写入配置前回退非有限值并移除非法目标，不把目标夹成别处', () async {
      SharedPreferences.setMockInitialValues({});
      final config = AppConfig(
        radiusMeters: double.nan,
        accuracyMeters: double.infinity,
        stepFreq: double.nan,
        stepLength: double.infinity,
        lastTarget: const LatLng(95, 1),
        lastName: '旧目标',
      );
      final storage = await AppStorage.load();
      await storage.writeConfig(config);
      final restored = storage.readConfig();
      expect(restored.lastTarget, isNull);
      expect(restored.lastName, isNull);
      expect(restored.radiusMeters, 200);
      expect(restored.accuracyMeters, 5);
      expect(restored.stepFreq, 110);
      expect(restored.stepLength, 0.65);
    });

    test('非法速度不会使预计耗时崩溃', () {
      final plan = RoutePlan(
        points: const [LatLng(0, 0), LatLng(0, 1)],
        motion: MotionMode.drive,
        speed: double.nan,
      );
      expect(plan.estimateDuration, Duration.zero);
    });

    test('日期线和极点的同一物理点不能当作有位移路线', () {
      for (final points in [
        const [LatLng(0, 180), LatLng(0, -180)],
        const [LatLng(90, 10), LatLng(90, 120)],
        const [LatLng(-90, -30), LatLng(-90, 160)],
        const [LatLng(0, 0), LatLng(0, 0.000000000001)],
      ]) {
        expect(RoutePlan(points: points).isValid, isFalse);
      }
      expect(
        RoutePlan(points: const [LatLng(0, 0), LatLng(0, 0.000000001)]).isValid,
        isTrue,
      );
    });

    test('循环长度含回程，往返预计耗时包含两个方向', () {
      const points = [LatLng(0, 0), LatLng(0, 1)];
      final once = RoutePlan(
        points: points,
        motion: MotionMode.drive,
        speed: 10,
        playMode: PlayMode.once,
      );
      final loop = once.copy()..playMode = PlayMode.loop;
      final pingpong = once.copy()..playMode = PlayMode.pingpong;
      expect(loop.distanceMeters, closeTo(once.distanceMeters * 2, 1e-6));
      expect(
        loop.estimateDuration.inSeconds,
        closeTo(once.estimateDuration.inSeconds * 2, 1),
      );
      expect(
        pingpong.estimateDuration.inSeconds,
        closeTo(once.estimateDuration.inSeconds * 2, 1),
      );
    });

    test('路线里程使用实际写入坐标，兼容默认转换和直接写入模式', () {
      const gcjPoints = [
        LatLng(39.9, 116.4),
        LatLng(40.0, 116.5),
        LatLng(39.8, 116.7),
      ];
      final wgsPoints = gcjPoints.map(Coord.gcjToWgs).toList();
      for (final mode in PlayMode.values) {
        final plan = RoutePlan(
          points: gcjPoints,
          motion: MotionMode.drive,
          speed: 5,
          playMode: mode,
        );
        var expectedWgs = 0.0;
        var expectedRaw = 0.0;
        for (var i = 1; i < gcjPoints.length; i++) {
          expectedWgs += Coord.distanceMeters(wgsPoints[i - 1], wgsPoints[i]);
          expectedRaw += Coord.distanceMeters(gcjPoints[i - 1], gcjPoints[i]);
        }
        if (mode == PlayMode.loop) {
          expectedWgs += Coord.distanceMeters(wgsPoints.last, wgsPoints.first);
          expectedRaw += Coord.distanceMeters(gcjPoints.last, gcjPoints.first);
        }
        expect((expectedWgs - expectedRaw).abs(), greaterThan(1));
        expect(plan.distanceMeters, closeTo(expectedWgs, 1e-6));
        expect(plan.distanceForWrite(), closeTo(expectedWgs, 1e-6));
        expect(
          plan.distanceForWrite(writeGcj: true),
          closeTo(expectedRaw, 1e-6),
        );
        final rounds = mode == PlayMode.pingpong ? 2 : 1;
        expect(
          plan.estimateDuration.inSeconds,
          (expectedWgs * rounds / 5).round(),
        );
        expect(plan.durationForWrite(), plan.estimateDuration);
        expect(
          plan.durationForWrite(writeGcj: true).inSeconds,
          (expectedRaw * rounds / 5).round(),
        );
        expect(plan.points, orderedEquals(gcjPoints));
      }
    });

    test('读取损坏配置时恢复合法数值，不污染其它字段', () async {
      SharedPreferences.setMockInitialValues({
        'app_config_v1': jsonEncode({
          'amapKey': '保留密钥',
          'accuracyMeters': -5,
          'radiusMeters': -2,
          'stepFreq': -1,
          'stepLength': -1,
          'intervalMs': 1,
        }),
      });
      final config = (await AppStorage.load()).readConfig();
      expect(config.amapKey, '保留密钥');
      expect(config.accuracyMeters, inInclusiveRange(1, 100));
      expect(config.radiusMeters, greaterThan(0));
      expect(config.stepFreq, inInclusiveRange(40, 220));
      expect(config.stepLength, inInclusiveRange(0.3, 1.2));
      expect(config.intervalMs, inInclusiveRange(50, 5000));
    });
  });
}
