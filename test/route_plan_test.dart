import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:fake_location/main.dart';

void main() {
  group('路线参数', () {
    test('步行按步频×步幅换算速度', () {
      final plan = RoutePlan(
        points: const [LatLng(39.9, 116.4), LatLng(39.91, 116.41)],
        motion: MotionMode.walk,
        stepFreq: 120,
        stepLength: 0.7,
      );
      expect(plan.effectiveSpeed, closeTo(1.4, 1e-9));
    });

    test('骑行等档位直接使用设定速度', () {
      final plan = RoutePlan(
        points: const [LatLng(39.9, 116.4), LatLng(39.91, 116.41)],
        motion: MotionMode.cycle,
        speed: 5.5,
        stepFreq: 200,
        stepLength: 1.2,
      );
      expect(plan.effectiveSpeed, closeTo(5.5, 1e-9));
    });

    test('路线长度与预计耗时合理', () {
      final plan = RoutePlan(
        points: const [LatLng(39.9000, 116.4000), LatLng(39.9010, 116.4000)],
        motion: MotionMode.walk,
        stepFreq: 120,
        stepLength: 0.7,
      );
      // 纬度 0.001 度约 110 米
      expect(plan.distanceMeters, closeTo(110, 5));
      expect(plan.estimateDuration.inSeconds, closeTo(79, 6));
    });

    test('JSON 往返保持路线与参数', () {
      final plan = RoutePlan(
        points: const [LatLng(39.9, 116.4), LatLng(39.92, 116.43)],
        motion: MotionMode.run,
        playMode: PlayMode.pingpong,
        stepFreq: 160,
        stepLength: 0.9,
        name: '测试路线',
      );
      final restored = RoutePlan.tryFromJson(plan.toJson());
      expect(restored, isNotNull);
      expect(restored!.points.length, 2);
      expect(restored.points.first.latitude, closeTo(39.9, 1e-6));
      expect(restored.motion, MotionMode.run);
      expect(restored.playMode, PlayMode.pingpong);
      expect(restored.stepFreq, closeTo(160, 1e-6));
      expect(restored.name, '测试路线');
    });

    test('损坏的路线数据被拒绝', () {
      expect(RoutePlan.tryFromJson(null), isNull);
      expect(RoutePlan.tryFromJson({'points': []}), isNull);
      expect(
        RoutePlan.tryFromJson({
          'points': [
            {'lat': 999, 'lng': 0},
            {'lat': 1, 'lng': 2},
          ],
        }),
        isNull,
      );
    });
  });
}
