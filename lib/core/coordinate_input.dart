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
  /// 分享文本含链接时使用专用解析，禁止从短链 ID 或任意网页数字猜测坐标。
  static bool containsLink(String text) =>
      RegExp(r'https?://', caseSensitive: false).hasMatch(text);

  /// 地理链接必须单独解析，地址查询不能按普通地点名称或主体占位坐标处理。
  static bool isGeoLink(String text) =>
      text.trim().toLowerCase().startsWith('geo:');

  /// 解析失败返回 null。
  static CoordinateReading? parse(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    if (containsLink(text) && !isGeoLink(text)) return _parseMapLink(text);

    // 全角符号归一化
    text = text
        .replaceAll('：', ':')
        .replaceAll('，', ',')
        .replaceAll('；', ';')
        .replaceAll('。', '.')
        .replaceAll('º', '°')
        .replaceAll('　', ' ');

    if (isGeoLink(text)) return _parseGeoUri(text);

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

    // 按完整角度分组，禁止把非法分钟、多余数字或文本静默吞掉。
    final normalized = text
        .replaceAll(RegExp(r'[°º度]'), ' ')
        .replaceAll(RegExp(r"['′’分]"), ' ')
        .replaceAll(RegExp(r'["″”秒:]'), ' ')
        .trim();
    final directional = RegExp(r'[NSEWnsew北南东西]').hasMatch(normalized);
    double? lat;
    double? lng;
    if (directional) {
      final point = _parseDirectional(normalized);
      if (point == null) return null;
      lat = point.latitude;
      lng = point.longitude;
    } else {
      final parts = normalized.split(RegExp(r'[\s,;]+'));
      final numbers = <double>[];
      for (final part in parts) {
        final value = double.tryParse(part);
        if (value == null || !value.isFinite) return null;
        numbers.add(value);
      }
      if (numbers.length != 2 && numbers.length != 4 && numbers.length != 6) {
        return null;
      }
      final width = numbers.length ~/ 2;
      lat = _angle(numbers.sublist(0, width));
      lng = _angle(numbers.sublist(width));
    }
    if (lat == null || lng == null) return null;
    var outLat = lat;
    var outLng = lng;
    // 明显写反的裸坐标可交换；有方向标记时必须尊重其含义，不能改写标注。
    if (!directional && outLat.abs() > 90 && outLng.abs() <= 90) {
      final swap = outLat;
      outLat = outLng;
      outLng = swap;
    }
    if (!outLat.isFinite ||
        !outLng.isFinite ||
        outLat.abs() > 90 ||
        outLng.abs() > 180) {
      return null;
    }

    final raw100 = LatLng(outLat, outLng);
    final gcj = switch (system) {
      CoordSystem.gcj => raw100,
      CoordSystem.wgs => Coord.wgsToGcj(raw100),
      CoordSystem.bd09 => Coord.bd09ToGcj(raw100),
    };
    if (!Coord.isValidPoint(gcj)) return null;
    return CoordinateReading(
      gcj: gcj,
      source: system,
      latitude: outLat,
      longitude: outLng,
      pretty: '${outLat.toStringAsFixed(6)}, ${outLng.toStringAsFixed(6)}',
    );
  }

  /// Android 的 q 参数才是标注点；地址或非法查询不能回退到主体的 0,0 占位点。
  static CoordinateReading? _parseGeoUri(String text) {
    try {
      final uri = Uri.tryParse(text);
      if (uri == null || uri.hasAuthority || uri.hasFragment) return null;
      final body = RegExp(
        r'^\s*([+-]?\d+(?:\.\d+)?)\s*,\s*([+-]?\d+(?:\.\d+)?)\s*$',
      ).firstMatch(uri.path);
      if (body == null) return null;
      final query = uri.queryParametersAll['q'];
      if (query != null && query.length != 1) return null;
      final match = query == null
          ? body
          : RegExp(
              r'^\s*([+-]?\d+(?:\.\d+)?)\s*,\s*([+-]?\d+(?:\.\d+)?)\s*(?:\([^()]*\))?\s*$',
            ).firstMatch(query.single);
      if (match == null) return null;
      final lat = double.tryParse(match.group(1)!);
      final lng = double.tryParse(match.group(2)!);
      if (lat == null ||
          lng == null ||
          !lat.isFinite ||
          !lng.isFinite ||
          lat.abs() > 90 ||
          lng.abs() > 180) {
        return null;
      }
      final point = LatLng(lat, lng);
      return CoordinateReading(
        gcj: Coord.wgsToGcj(point),
        source: CoordSystem.wgs,
        latitude: lat,
        longitude: lng,
        pretty: 'geo:$lat,$lng',
      );
    } on FormatException {
      return null;
    }
  }

  /// 只读取地图官方 URI 中明确的单点坐标；不联网展开短链或猜测坐标系。
  static CoordinateReading? _parseMapLink(String text) {
    final links = RegExp(
      r'''https?://[^\s<>"'，。]+''',
      caseSensitive: false,
    ).allMatches(text).toList();
    if (links.length != 1) return null;
    try {
      final uri = Uri.tryParse(links.single.group(0)!);
      if (uri == null || uri.userInfo.isNotEmpty) return null;
      final params = uri.queryParameters;
      if (uri.queryParametersAll.values.any((values) => values.length != 1)) {
        return null;
      }
      final path = uri.path.replaceFirst(RegExp(r'/$'), '');
      String? pair;
      var longitudeFirst = false;
      CoordSystem? system;
      if (uri.host == 'uri.amap.com' && path == '/marker') {
        pair = params['position'];
        longitudeFirst = true;
        system = switch (params['coordinate'] ?? 'gaode') {
          'gaode' => CoordSystem.gcj,
          'wgs84' => CoordSystem.wgs,
          _ => null,
        };
      } else if (uri.host == 'api.map.baidu.com' &&
          (path == '/marker' || path == '/geocoder')) {
        pair = params['location'];
        system = switch (params['coord_type'] ?? 'bd09ll') {
          'bd09ll' => CoordSystem.bd09,
          'gcj02' => CoordSystem.gcj,
          'wgs84' => CoordSystem.wgs,
          _ => null,
        };
      } else if (uri.host == 'apis.map.qq.com' && path == '/uri/v1/marker') {
        final marker = params['marker'] ?? '';
        if (marker.contains('|')) return null;
        final coords = marker
            .split(';')
            .where((part) => part.startsWith('coord:'));
        if (coords.length != 1) return null;
        pair = coords.single.substring('coord:'.length);
        system = switch (params['coord_type'] ?? '2') {
          '2' => CoordSystem.gcj,
          '1' => CoordSystem.wgs,
          _ => null,
        };
      } else if ((uri.host == 'www.google.com' || uri.host == 'google.com') &&
          path == '/maps/search' &&
          params['api'] == '1' &&
          !params.containsKey('query_place_id')) {
        pair = params['query'];
        system = CoordSystem.wgs;
      }
      if (pair == null || system == null) return null;
      final parts = pair.split(',');
      if (parts.length != 2) return null;
      final first = double.tryParse(parts[0].trim());
      final second = double.tryParse(parts[1].trim());
      if (first == null ||
          second == null ||
          !first.isFinite ||
          !second.isFinite) {
        return null;
      }
      final lat = longitudeFirst ? second : first;
      final lng = longitudeFirst ? first : second;
      if (lat.abs() > 90 || lng.abs() > 180) return null;
      final point = LatLng(lat, lng);
      return CoordinateReading(
        gcj: switch (system) {
          CoordSystem.gcj => point,
          CoordSystem.wgs => Coord.wgsToGcj(point),
          CoordSystem.bd09 => Coord.bd09ToGcj(point),
        },
        source: system,
        latitude: lat,
        longitude: lng,
        pretty: '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}',
      );
    } on FormatException {
      return null;
    }
  }

  /// 支持方向在前或在后，但每个轴只能出现一次且必须消费完整输入。
  static ({double latitude, double longitude})? _parseDirectional(String text) {
    const angle =
        r'([+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:\s+[+-]?(?:\d+(?:\.\d+)?|\.\d+)){0,2})';
    const direction = r'([NSEWnsew北南东西])';
    for (final prefix in [false, true]) {
      final pattern = RegExp(
        prefix ? '$direction\\s*$angle' : '$angle\\s*$direction',
      );
      final matches = pattern.allMatches(text).toList();
      final remainder = text
          .replaceAll(pattern, '')
          .replaceAll(RegExp(r'[\s,;]+'), '');
      if (matches.length != 2 || remainder.isNotEmpty) continue;
      double? lat;
      double? lng;
      var valid = true;
      for (final match in matches) {
        final tag = match.group(prefix ? 1 : 2)!.toUpperCase();
        final parts = match
            .group(prefix ? 2 : 1)!
            .split(RegExp(r'\s+'))
            .map(double.parse)
            .toList();
        final value = _angle(parts);
        if (value == null) {
          valid = false;
          break;
        }
        if (tag == 'N' || tag == 'S' || tag == '北' || tag == '南') {
          if (lat != null) {
            valid = false;
            break;
          }
          lat = (tag == 'S' || tag == '南') ? -value.abs() : value.abs();
        } else {
          if (lng != null) {
            valid = false;
            break;
          }
          lng = (tag == 'W' || tag == '西') ? -value.abs() : value.abs();
        }
      }
      if (valid && lat != null && lng != null) {
        return (latitude: lat, longitude: lng);
      }
    }
    return null;
  }

  /// 分、秒只能在零到六十之间，保留零度的负号。
  static double? _angle(List<double> parts) {
    if (parts.isEmpty ||
        parts.length > 3 ||
        parts.any((value) => !value.isFinite)) {
      return null;
    }
    if (parts.skip(1).any((value) => value < 0 || value >= 60)) return null;
    final sign = parts.first.isNegative ? -1.0 : 1.0;
    return sign *
        (parts.first.abs() +
            (parts.length > 1 ? parts[1] / 60 : 0) +
            (parts.length > 2 ? parts[2] / 3600 : 0));
  }
}
