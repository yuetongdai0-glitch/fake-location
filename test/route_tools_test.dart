import 'dart:math' as math;

import 'package:fake_location/core/coord.dart';
import 'package:fake_location/core/route_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  test('反转保留全部途经点，闭合幂等，均不改动原草稿', () {
    const points = [
      LatLng(29.75, 106.58),
      LatLng(29.751, 106.581),
      LatLng(29.752, 106.58),
    ];
    expect(RouteTools.reverse(points), points.reversed.toList());
    final closed = RouteTools.close(points);
    expect(closed, [...points, points.first]);
    expect(RouteTools.close(closed), closed);
    expect(points.length, 3);
  });

  test('闭合将日期线和极点的经度别名识别为同一位置', () {
    for (final aliases in const [
      [LatLng(10, 180), LatLng(10, -180)],
      [LatLng(90, 45), LatLng(90, -45)],
      [LatLng(-90, 0), LatLng(-90, 160)],
    ]) {
      expect(() => RouteTools.close(aliases), throwsFormatException);
      final closed = [aliases.first, const LatLng(0, 0), aliases.last];
      expect(RouteTools.close(closed), closed);
    }
  });

  test('WGS球面环线半径及周长符合几何约束，方向只改变顺序', () {
    for (final center in const [
      LatLng(29.75, 106.58),
      LatLng(0, 0),
      LatLng(80, 179.999),
      LatLng(90, 45),
      LatLng(-90, -45),
    ]) {
      for (final radius in [10.0, 250.0, 10000.0]) {
        final clockwise = RouteTools.circle(
          center: center,
          radiusMeters: radius,
        );
        final reversed = RouteTools.circle(
          center: center,
          radiusMeters: radius,
          clockwise: false,
        );
        expect(clockwise.length, 65);
        expect(clockwise.first, clockwise.last);
        final centerWgs = Coord.gcjToWgs(center);
        final clockwiseWgs = clockwise.map(Coord.gcjToWgs).toList();
        for (final point in clockwise) {
          expect(point.latitude, inInclusiveRange(-90, 90));
          expect(point.longitude, inInclusiveRange(-180, 180));
          expect(
            Coord.distanceMeters(centerWgs, Coord.gcjToWgs(point)),
            closeTo(radius, 0.001),
          );
        }
        var length = 0.0;
        for (var i = 1; i < clockwiseWgs.length; i++) {
          final segment = Coord.distanceMeters(
            clockwiseWgs[i - 1],
            clockwiseWgs[i],
          );
          expect(
            segment,
            closeTo(
              2 * radius * math.sin(math.pi / 64),
              math.max(0.001, radius * 0.00001),
            ),
          );
          length += segment;
        }
        // 64条弦组成的折线比圆周短约0.04%，允许球面大半径的小量差异。
        expect(length, closeTo(2 * math.pi * radius, radius * 0.004));
        expect(
          Coord.distanceMeters(clockwiseWgs[1], Coord.gcjToWgs(reversed[63])),
          lessThan(0.001),
        );
      }
    }
  });

  test('城市地图环线反解后以写入WGS坐标为圆心量取半径', () {
    for (final centerWgs in const [
      LatLng(39.9042, 116.4074),
      LatLng(31.2304, 121.4737),
      LatLng(29.563, 106.5516),
    ]) {
      final centerGcj = Coord.wgsToGcj(centerWgs);
      expect(
        Coord.distanceMeters(centerWgs, Coord.gcjToWgs(centerGcj)),
        lessThan(0.001),
      );
      for (final radius in [10.0, 250.0, 10000.0]) {
        final circleGcj = RouteTools.circle(
          center: centerGcj,
          radiusMeters: radius,
        );
        for (final pointGcj in circleGcj) {
          expect(
            Coord.distanceMeters(centerWgs, Coord.gcjToWgs(pointGcj)),
            closeTo(radius, 0.001),
          );
        }
      }
    }
  });

  test('跨日期变更线的环线使用短弧，不产生绕地球一周的线段', () {
    const center = LatLng(0, 179.9999);
    final points = RouteTools.circle(center: center, radiusMeters: 500);
    expect(points.any((point) => point.longitude < 0), isTrue);
    for (var i = 1; i < points.length; i++) {
      expect(Coord.distanceMeters(points[i - 1], points[i]), lessThan(50));
    }
  });

  test('半径边界和无效草稿返回中文错误', () {
    for (final radius in [0.0, 9.99, 10000.01, double.nan, double.infinity]) {
      expect(
        () =>
            RouteTools.circle(center: const LatLng(0, 0), radiusMeters: radius),
        throwsFormatException,
      );
    }
    expect(() => RouteTools.reverse([]), throwsFormatException);
    expect(
      () => RouteTools.close(const [LatLng(0, 0), LatLng(0, 0)]),
      throwsFormatException,
    );
    expect(
      () => RouteTools.circle(
        center: const LatLng(double.nan, 0),
        radiusMeters: 100,
      ),
      throwsFormatException,
    );
  });
}
