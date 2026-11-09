import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'coord.dart';

/// 路线草稿的纯本地工具，不启动模拟，也不修改传入的路线点。
class RouteTools {
  static const double minRadiusMeters = 10;
  static const double maxRadiusMeters = 10000;
  static const int circleSegments = 64;

  /// 交换起终点并反转途经顺序；非法坐标不会进入路线编辑器。
  static List<LatLng> reverse(List<LatLng> points) {
    _validateRoute(points);
    return points.reversed.toList();
  }

  /// 把起点作为最后一个点保存，已经闭合的路线不会再次追加。
  static List<LatLng> close(List<LatLng> points) {
    _validateRoute(points);
    if (!points
        .skip(1)
        .any((point) => Coord.distanceMeters(point, points.first) > 1e-6)) {
      throw const FormatException('路线至少需要两个不同的点');
    }
    // 日期线两侧和极点可用不同经度表示同一位置，不重复添加物理同点。
    return [
      ...points,
      if (Coord.distanceMeters(points.last, points.first) > 1e-6) points.first,
    ];
  }

  /// 以指定地图点为圆心生成闭合环线，起点在圆心正北，顺逆时针仅改变行进方向。
  /// 地图草稿使用 GCJ-02，先反解为实际写入的 WGS-84，再沿统一球面量取半径。
  /// 生成后转回地图坐标；球面与加偏模型的数值精度不等于真实 GPS 定位精度。
  static List<LatLng> circle({
    required LatLng center,
    required double radiusMeters,
    bool clockwise = true,
  }) {
    _validatePoint(center);
    if (!radiusMeters.isFinite ||
        radiusMeters < minRadiusMeters ||
        radiusMeters > maxRadiusMeters) {
      throw const FormatException('环线半径须为 10 至 10000 米');
    }
    final centerWgs = Coord.gcjToWgs(center);
    final points = List<LatLng>.generate(circleSegments, (index) {
      final angle = 2 * math.pi * index / circleSegments * (clockwise ? 1 : -1);
      return Coord.wgsToGcj(
        Coord.offsetMeters(
          centerWgs,
          north: radiusMeters * math.cos(angle),
          east: radiusMeters * math.sin(angle),
        ),
      );
    });
    return [...points, points.first];
  }

  /// 路线工具仅接受至少两个合法点，空草稿仍可通过环线生成器建立路线。
  static void _validateRoute(List<LatLng> points) {
    if (points.length < 2) throw const FormatException('路线至少需要两个点');
    for (final point in points) {
      _validatePoint(point);
    }
  }

  /// 在输入边界拒绝非有限值，避免投影或距离计算产生无效坐标。
  static void _validatePoint(LatLng point) {
    if (!point.latitude.isFinite ||
        !point.longitude.isFinite ||
        point.latitude.abs() > 90 ||
        point.longitude.abs() > 180) {
      throw const FormatException('路线坐标超出有效范围');
    }
  }
}
