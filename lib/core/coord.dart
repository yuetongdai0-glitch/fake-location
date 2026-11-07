import 'dart:math';

import 'package:latlong2/latlong.dart';

/// 坐标系工具：全国范围内使用 GCJ-02（高德/腾讯瓦片），系统 GPS 写入 WGS-84，
/// 百度 POI 返回 BD-09 墨卡托，需要统一换算成地图坐标（GCJ-02）。
class Coord {
  static const double _a = 6378245.0;
  static const double _ee = 0.00669342162296594323;

  /// 百度墨卡托分带（由北向南），与 [_mc2ll] 的系数表一一对应。
  static const List<double> _mcBand = <double>[
    12890594.86,
    8362377.87,
    5591021,
    3481989.83,
    1678043.12,
    0,
  ];

  /// 百度官方 convertor 的多项式系数，用于把墨卡托坐标反解为 BD-09 经纬度。
  static const List<List<double>> _mc2ll = <List<double>>[
    <double>[
      1.410526172116255e-8,
      0.00000898305509648872,
      -1.9939833816331,
      200.9824383106796,
      -187.2403703815547,
      91.6087516669843,
      -23.38765649603339,
      2.57121317296198,
      -0.03801003308653,
      17337981.2,
    ],
    <double>[
      -7.435856389565537e-9,
      0.000008983055097726239,
      -0.78625201886289,
      96.32687599759846,
      -1.85204757529826,
      -59.36935905485877,
      47.40033549296737,
      -16.50741931063887,
      2.28786674699375,
      10260144.86,
    ],
    <double>[
      -3.030883460898826e-8,
      0.00000898305509983578,
      0.30071316287616,
      59.74293618442277,
      7.357984074871,
      -25.38371002664745,
      13.45380521110908,
      -3.29883767235584,
      0.32710905363475,
      6856817.37,
    ],
    <double>[
      -1.981981304930552e-8,
      0.000008983055099779535,
      0.03278182852591,
      40.31678527705744,
      0.65659298677277,
      -4.44255534477492,
      0.85341911805263,
      0.12923347998204,
      -0.04625736007561,
      4482777.06,
    ],
    <double>[
      3.09191371068437e-9,
      0.000008983055096812155,
      0.00006995724062,
      23.10934304144901,
      -0.00023663490511,
      -0.6321817810242,
      -0.00663494467273,
      0.03430082397953,
      -0.00466043876332,
      2555164.4,
    ],
    <double>[
      2.890871144776878e-9,
      0.000008983055095805407,
      -3.068298e-8,
      7.47137025468032,
      -0.00000353937994,
      -0.02145144861037,
      -0.00001234426596,
      0.00010322952773,
      -0.00000323890364,
      826088.5,
    ],
  ];

  static bool _outOfChina(double lat, double lng) =>
      lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271;

  static double _tLat(double x, double y) {
    var r =
        -100.0 +
        2.0 * x +
        3.0 * y +
        0.2 * y * y +
        0.1 * x * y +
        0.2 * sqrt(x.abs());
    r += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0;
    r += (20.0 * sin(y * pi) + 40.0 * sin(y / 3.0 * pi)) * 2.0 / 3.0;
    r += (160.0 * sin(y / 12.0 * pi) + 320 * sin(y * pi / 30.0)) * 2.0 / 3.0;
    return r;
  }

  static double _tLng(double x, double y) {
    var r =
        300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(x.abs());
    r += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0;
    r += (20.0 * sin(x * pi) + 40.0 * sin(x / 3.0 * pi)) * 2.0 / 3.0;
    r += (150.0 * sin(x / 12.0 * pi) + 300.0 * sin(x / 30.0 * pi)) * 2.0 / 3.0;
    return r;
  }

  /// WGS-84 → GCJ-02（国测局加偏）。
  static LatLng wgsToGcj(LatLng p) {
    if (_outOfChina(p.latitude, p.longitude)) return p;
    var dLat = _tLat(p.longitude - 105.0, p.latitude - 35.0);
    var dLng = _tLng(p.longitude - 105.0, p.latitude - 35.0);
    final radLat = p.latitude / 180.0 * pi;
    var magic = sin(radLat);
    magic = 1 - _ee * magic * magic;
    final sqrtMagic = sqrt(magic);
    dLat = (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * pi);
    dLng = (dLng * 180.0) / (_a / sqrtMagic * cos(radLat) * pi);
    return LatLng(p.latitude + dLat, p.longitude + dLng);
  }

  /// GCJ-02 → WGS-84，迭代反解，误差约厘米级。
  static LatLng gcjToWgs(LatLng g) {
    if (_outOfChina(g.latitude, g.longitude)) return g;
    var w = g;
    for (var i = 0; i < 6; i++) {
      final t = wgsToGcj(w);
      w = LatLng(
        w.latitude - (t.latitude - g.latitude),
        w.longitude - (t.longitude - g.longitude),
      );
    }
    return w;
  }

  /// BD-09 → GCJ-02。
  static LatLng bd09ToGcj(LatLng b) {
    const xPi = pi * 3000.0 / 180.0;
    final x = b.longitude - 0.0065;
    final y = b.latitude - 0.006;
    final z = sqrt(x * x + y * y) - 0.00002 * sin(y * xPi);
    final theta = atan2(y, x) - 0.000003 * cos(x * xPi);
    return LatLng(z * sin(theta), z * cos(theta));
  }

  /// GCJ-02 → BD-09（少数需要百度坐标的场景备用）。
  static LatLng gcjToBd09(LatLng g) {
    const xPi = pi * 3000.0 / 180.0;
    final z = sqrt(g.longitude * g.longitude + g.latitude * g.latitude) +
        0.00002 * sin(g.latitude * xPi);
    final theta = atan2(g.latitude, g.longitude) + 0.000003 * cos(g.longitude * xPi);
    return LatLng(
      z * sin(theta) + 0.006,
      z * cos(theta) + 0.0065,
    );
  }

  /// 百度墨卡托（BD-09MC）→ GCJ-02：百度地图网页搜索只返回墨卡托坐标。
  static LatLng bd09McToGcj(double x, double y) {
    final row = _pickRow(y);
    final lng = (row[0] + row[1] * x.abs()) * (x < 0 ? -1 : 1);
    final basis = y.abs() / row[9];
    var lat = row[2];
    var power = 1.0;
    for (var i = 3; i < 9; i++) {
      power *= basis;
      lat += row[i] * power;
    }
    lat = lat * (y < 0 ? -1 : 1);
    return bd09ToGcj(LatLng(lat, lng));
  }

  static List<double> _pickRow(double y) {
    final abs = y.abs();
    for (var i = 0; i < _mcBand.length; i++) {
      if (abs >= _mcBand[i]) return _mc2ll[i];
    }
    return _mc2ll.last;
  }

  /// 按米平移坐标（正北 / 正东为正）。
  static LatLng offsetMeters(LatLng p, {double north = 0, double east = 0}) {
    const metersPerDegree = 111319.49079327358;
    final dLat = north / metersPerDegree;
    final dLng =
        east / (metersPerDegree * cos(p.latitude * pi / 180).abs().clamp(1e-6, 1));
    return LatLng(p.latitude + dLat, p.longitude + dLng);
  }

  /// 两点间距离（米）。
  static double distanceMeters(LatLng a, LatLng b) {
    const earthRadius = 6378137.0;
    final dLat = (b.latitude - a.latitude) * pi / 180;
    final dLng = (b.longitude - a.longitude) * pi / 180;
    final lat1 = a.latitude * pi / 180;
    final lat2 = b.latitude * pi / 180;
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
    return 2 * earthRadius * atan2(sqrt(h), sqrt(1 - h));
  }
}

/// 坐标显示格式。
enum CoordSystem {
  gcj('GCJ-02', '高德/腾讯'),
  wgs('WGS-84', '系统 GPS'),
  bd09('BD-09', '百度');

  const CoordSystem(this.label, this.hint);

  final String label;
  final String hint;

  /// 把地图坐标（GCJ-02）转换成本坐标系下的值。
  LatLng fromGcj(LatLng gcj) => switch (this) {
    CoordSystem.gcj => gcj,
    CoordSystem.wgs => Coord.gcjToWgs(gcj),
    CoordSystem.bd09 => Coord.gcjToBd09(gcj),
  };
}

/// 距离的易读表示。
String formatDistance(double meters) {
  if (meters < 1000) return '${meters.round()} 米';
  return '${(meters / 1000).toStringAsFixed(meters < 10000 ? 1 : 0)} 公里';
}

/// 经纬度的易读表示（6 位小数约 0.1 米）。
String formatLatLng(LatLng p, {int digits = 6}) =>
    '${p.latitude.toStringAsFixed(digits)}, ${p.longitude.toStringAsFixed(digits)}';
