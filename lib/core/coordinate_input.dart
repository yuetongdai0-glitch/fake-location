import 'package:latlong2/latlong.dart';

import 'coord.dart';

/// 一次坐标解析的结果。
class CoordinateReading {
  const CoordinateReading({
    required this.gcj,
    required this.source,
    required this.latitude,
    required this.longitude,
    this.pretty = '',
  });

  /// 换算成地图使用的 GCJ-02。
  final LatLng gcj;

  /// 用户输入时声明的坐标系。
  final CoordSystem source;

  /// 解析出来的原始纬度/经度（source 坐标系下）。
  final double latitude;
  final double longitude;

  /// 规范化后的显示文本，便于回显。
  final String pretty;

  String get sourceLabel => source.label;
}

/// 坐标文本解析：同时支持十进制、度分秒、带方向字母、geo: 链接和坐标系前缀。
///
/// 支持的写法（大小写、全角符号均可）：
/// - `39.908722, 116.397499`
/// - `39.908722N, 116.397499E`
/// - `39°54'31.4"N 116°23'51.0"E`
/// - `39 54 31.4, 116 23 51.0`
/// - `gcj:39.908722,116.397499`（wgs / bd 同理）
/// - `geo:39.908722,116.397499`
class CoordinateInput {
  /// 解析失败返回 null。
  static CoordinateReading? parse(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;

    // 全角符号归一化
    text = text
        .replaceAll('：', ':')
        .replaceAll('，', ',')
        .replaceAll('；', ';')
        .replaceAll('。', '.')
        .replaceAll('º', '°')
        .replaceAll('　', ' ');

    // geo:lat,lng?z=17 这类链接
    final geo = RegExp(
      r'^geo:\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)',
      caseSensitive: false,
    ).firstMatch(text);
    if (geo != null) {
      final lat = double.tryParse(geo.group(1)!);
      final lng = double.tryParse(geo.group(2)!);
      if (lat == null || lng == null) return null;
      if (lat.abs() > 90 || lng.abs() > 180) return null;
      final wgs = LatLng(lat, lng);
      return CoordinateReading(
        gcj: Coord.wgsToGcj(wgs),
        source: CoordSystem.wgs,
        latitude: lat,
        longitude: lng,
        pretty: 'geo:$lat,$lng',
      );
    }

    // 坐标系前缀
    var system = CoordSystem.wgs;
    final prefix = RegExp(
      r'^(wgs-?84|wgs|gcj-?02|gcj|bd-?09|bd|百度|高德|gps)\s*[:：]\s*',
      caseSensitive: false,
    ).firstMatch(text);
    if (prefix != null) {
      final tag = prefix.group(1)!.toLowerCase().replaceAll('-', '');
      system = switch (tag) {
        'gcj' || 'gcj02' || '高德' => CoordSystem.gcj,
        'bd' || 'bd09' || '百度' => CoordSystem.bd09,
        _ => CoordSystem.wgs,
      };
      text = text.substring(prefix.end);
    }

    // 把度分秒符号换成空格，逐段取数字与方向字母
    final normalized = text
        .replaceAll(RegExp(r'[°º度]'), ' ')
        .replaceAll(RegExp(r"['′’分]"), ' ')
        .replaceAll(RegExp(r'["″”秒]'), ' ');

    final tokens = RegExp(
      r'(-?\d+(?:\.\d+)?)|([NSEWnsew北南东西])',
    ).allMatches(normalized).map((m) => m.group(0)!).toList();
    if (tokens.isEmpty) return null;

    final numbers = <double>[];
    final directions = <String>[];
    for (final token in tokens) {
      final value = double.tryParse(token);
      if (value != null) {
        numbers.add(value);
      } else {
        directions.add(token.toUpperCase());
      }
    }
    if (numbers.length < 2) return null;

    double? lat;
    double? lng;

    if (directions.length >= 2) {
      // 有方向字母：按最近的数字分组，N/S 是纬度，E/W 是经度
      var index = 0;
      for (final dir in directions) {
        final isLat = dir == 'N' || dir == 'S' || dir == '北' || dir == '南';
        final remaining = numbers.length - index;
        if (remaining < 1) break;
        // 每个方向最多带走 3 个数字（度分秒）
        final take = remaining >= 3 && _looksDms(numbers, index) ? 3 : 1;
        if (take == 3) {
          final value = _dms(numbers[index], numbers[index + 1], numbers[index + 2]);
          if (isLat && lat == null) lat = value;
          if (!isLat && lng == null) lng = value;
          index += 3;
        } else {
          if (isLat && lat == null) lat = numbers[index];
          if (!isLat && lng == null) lng = numbers[index];
          index += 1;
        }
      }
      if (lat == null || lng == null) {
        // 方向不全时，剩余数字按纬度、经度补齐
        final rest = numbers.sublist(index.clamp(0, numbers.length));
        for (final value in rest) {
          if (lat == null) {
            lat = value;
          } else {
            lng ??= value;
          }
        }
      }
    } else if (numbers.length == 2) {
      lat = numbers[0];
      lng = numbers[1];
    } else if (numbers.length == 4) {
      lat = _dms(numbers[0], numbers[1], 0);
      lng = _dms(numbers[2], numbers[3], 0);
    } else if (numbers.length >= 6) {
      lat = _dms(numbers[0], numbers[1], numbers[2]);
      lng = _dms(numbers[3], numbers[4], numbers[5]);
    } else {
      return null;
    }

    if (lat == null || lng == null) return null;

    // 带方向字母时按方向取正负
    var outLat = lat;
    var outLng = lng;
    for (final dir in directions) {
      if (dir == 'S' || dir == '南') outLat = -outLat.abs();
      if (dir == 'W' || dir == '西') outLng = -outLng.abs();
    }

    // 明显写反（纬度 > 90 而经度合法）时交换
    if (outLat.abs() > 90 && outLng.abs() <= 90) {
      final swap = outLat;
      outLat = outLng;
      outLng = swap;
    }
    if (outLat.abs() > 90 || outLng.abs() > 180) return null;

    final raw100 = LatLng(outLat, outLng);
    final gcj = switch (system) {
      CoordSystem.gcj => raw100,
      CoordSystem.wgs => Coord.wgsToGcj(raw100),
      CoordSystem.bd09 => Coord.bd09ToGcj(raw100),
    };
    return CoordinateReading(
      gcj: gcj,
      source: system,
      latitude: outLat,
      longitude: outLng,
      pretty: '${outLat.toStringAsFixed(6)}, ${outLng.toStringAsFixed(6)}',
    );
  }

  /// 三个数字连续且后两个小于 60，视为度分秒。
  static bool _looksDms(List<double> numbers, int index) {
    if (index + 2 >= numbers.length) return false;
    final minute = numbers[index + 1];
    final second = numbers[index + 2];
    return minute.abs() < 60 && second.abs() < 60;
  }

  static double _dms(double degree, double minute, double second) {
    final sign = degree < 0 ? -1.0 : 1.0;
    return sign *
        (degree.abs() + minute.abs() / 60 + second.abs() / 3600);
  }
}
