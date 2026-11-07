import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'coord.dart';
import 'models.dart';

/// 一次搜索的结果：命中的地点，以及被跳过的数据源说明。
class SearchOutcome {
  const SearchOutcome({required this.places, this.notes = const []});

  final List<Place> places;
  final List<String> notes;

  bool get isEmpty => places.isEmpty;
}

/// 地点搜索。
///
/// 数据源按可用性依次尝试：
/// 1. 高德 Web 服务（配置了 Key 时）——与高德地图同源，POI 最全，坐标即 GCJ-02；
/// 2. 百度地图网页接口——免 Key，国内 POI 覆盖好，返回墨卡托坐标需换算；
/// 3. Photon（OSM）——境外与兜底。
class SearchApi {
  SearchApi({this.amapKey = '', http.Client? client})
    : _client = client ?? http.Client();

  final String amapKey;
  final http.Client _client;

  static const _ua =
      'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

  Future<SearchOutcome> search(
    String query, {
    required LatLng center,
    LatLng? origin,
  }) async {
    final keyword = query.trim();
    final notes = <String>[];
    final anchor = origin ?? center;

    if (amapKey.trim().isNotEmpty) {
      try {
        final list = await _searchAmap(keyword, center);
        if (list.isNotEmpty) {
          return SearchOutcome(places: _withDistance(list, anchor), notes: notes);
        }
        notes.add('高德未匹配到结果');
      } catch (e) {
        notes.add('高德：${_friendly(e)}');
      }
    }

    try {
      final list = await _searchBaidu(keyword, center);
      if (list.isNotEmpty) {
        return SearchOutcome(places: _withDistance(list, anchor), notes: notes);
      }
      notes.add('百度未匹配到结果');
    } catch (e) {
      notes.add('百度：${_friendly(e)}');
    }

    try {
      final list = await _searchPhoton(keyword, center);
      if (list.isNotEmpty) {
        return SearchOutcome(places: _withDistance(list, anchor), notes: notes);
      }
      notes.add('OSM 未匹配到结果');
    } catch (e) {
      notes.add('OSM：${_friendly(e)}');
    }

    return SearchOutcome(places: const [], notes: notes);
  }

  /// 逆地理：把地图上的点换成可读地址。
  Future<String?> reverseGeocode(LatLng gcj) async {
    if (amapKey.trim().isNotEmpty) {
      try {
        final uri = Uri.https('restapi.amap.com', '/v3/geocode/regeo', {
          'key': amapKey.trim(),
          'location':
              '${gcj.longitude.toStringAsFixed(6)},${gcj.latitude.toStringAsFixed(6)}',
          'extensions': 'base',
        });
        final json = await _getJson(uri);
        if ('${json['status']}' == '1') {
          final regeocode = json['regeocode'];
          if (regeocode is Map) {
            final formatted = regeocode['formatted_address'];
            if (formatted is String && formatted.trim().isNotEmpty) {
              return formatted.trim();
            }
          }
        }
      } catch (_) {
        // 逆地理失败不影响选点，继续尝试 OSM。
      }
    }
    try {
      final wgs = Coord.gcjToWgs(gcj);
      final uri = Uri.https('photon.komoot.io', '/reverse', {
        'lat': wgs.latitude.toStringAsFixed(6),
        'lon': wgs.longitude.toStringAsFixed(6),
        'limit': '1',
      });
      final json = await _getJson(uri);
      final features = json['features'];
      if (features is List && features.isNotEmpty) {
        final pr = (features.first as Map)['properties'];
        if (pr is Map) {
          final parts = [
            pr['name'],
            pr['street'],
            pr['district'],
            pr['city'],
            pr['state'],
          ].where((e) => e != null && '$e'.trim().isNotEmpty).toSet().toList();
          if (parts.isNotEmpty) return parts.join(' · ');
        }
      }
    } catch (_) {
      // 忽略，界面只提示“地址未知”。
    }
    return null;
  }

  /// 百度联想接口需要城市 ID，这里缓存最近一次搜索拿到的城市。
  static int? _baiduCityId;

  /// 输入联想：帮助用户拼出完整地名（很多地点搜不到是因为名称不完整）。
  Future<List<String>> suggest(String prefix, {LatLng? center}) async {
    final keyword = prefix.trim();
    if (keyword.length < 2) return const [];

    if (amapKey.trim().isNotEmpty) {
      try {
        final uri = Uri.https('restapi.amap.com', '/v3/assistant/inputtips', {
          'key': amapKey.trim(),
          'keywords': keyword,
          'datatype': 'all',
          if (center != null)
            'location':
                '${center.longitude.toStringAsFixed(6)},${center.latitude.toStringAsFixed(6)}',
        });
        final json = await _getJson(uri);
        if ('${json['status']}' == '1') {
          final tips = json['tips'];
          if (tips is List) {
            final names = <String>[];
            for (final tip in tips) {
              if (tip is! Map) continue;
              final name = '${tip['name'] ?? ''}'.trim();
              if (name.isEmpty || names.contains(name)) continue;
              names.add(name);
              if (names.length >= 10) break;
            }
            if (names.isNotEmpty) return names;
          }
        }
      } catch (_) {
        // 联想失败不影响正常搜索
      }
    }

    final names = <String>[];
    {
      // 城市未知时 cid=0，接口仍会返回全国范围内的联想
      final cityId = _baiduCityId ?? 0;
      try {
        final uri = Uri.https('map.baidu.com', '/su', {
          'wd': keyword,
          'cid': '$cityId',
          'type': '0',
          'pc_ver': '2',
          'ie': 'utf-8',
        });
        final body = await _getText(
          uri,
          headers: const {
            'User-Agent': _ua,
            'Referer': 'https://map.baidu.com/',
          },
        );
        if (body.trimLeft().startsWith('{')) {
          final json = jsonDecode(body);
          final raw = json is Map ? json['s'] : null;
          if (raw is List) {
            for (final item in raw) {
              if (item is! String) continue;
              // 格式：省$市$区$名称$cid$uid$，名称在第 4 段
              final parts = item.split(r'$');
              final name = (parts.length > 3 ? parts[3] : parts.first).trim();
              if (name.isEmpty || RegExp(r'^\d+$').hasMatch(name)) continue;
              if (names.contains(name)) continue;
              names.add(name);
              if (names.length >= 10) break;
            }
          }
        }
      } catch (_) {
        // 继续走搜索兜底
      }
    }
    if (names.isNotEmpty) return names;

    // 没有城市 ID 时，用一次小规模搜索的 POI 名称作为联想
    try {
      final places = await _searchBaidu(
        keyword,
        center ?? const LatLng(39.9087, 116.3975),
        limit: 8,
      );
      return places.map((p) => p.name).toSet().take(8).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<Place>> _searchAmap(String keyword, LatLng center) async {
    final uri = Uri.https('restapi.amap.com', '/v3/place/text', {
      'key': amapKey.trim(),
      'keywords': keyword,
      'offset': '20',
      'page': '1',
      'extensions': 'base',
      'citylimit': 'false',
      'location':
          '${center.longitude.toStringAsFixed(6)},${center.latitude.toStringAsFixed(6)}',
    });
    final json = await _getJson(uri);
    if ('${json['status']}' != '1') {
      throw Exception(_amapError('${json['info']}'));
    }
    final pois = json['pois'];
    if (pois is! List) return const [];
    final places = <Place>[];
    for (final raw in pois) {
      if (raw is! Map) continue;
      final name = '${raw['name'] ?? ''}'.trim();
      final location = '${raw['location'] ?? ''}';
      final parts = location.split(',');
      if (name.isEmpty || parts.length != 2) continue;
      final lng = double.tryParse(parts[0]);
      final lat = double.tryParse(parts[1]);
      if (lng == null || lat == null || (lng == 0 && lat == 0)) continue;
      final address = _firstString(raw['address']);
      places.add(
        Place(
          name: name,
          gcj: LatLng(lat, lng),
          address: address,
          category: _firstString(raw['type']).split(';').last,
          source: PlaceSource.amap,
        ),
      );
    }
    return places;
  }

  Future<List<Place>> _searchBaidu(
    String keyword,
    LatLng center, {
    int limit = 20,
  }) async {
    // 百度网页搜索需要城市参数，否则只返回城市级别的模糊结果
    final cityId = _baiduCityId ?? await _ensureBaiduCity(center);
    final uri = Uri.https('map.baidu.com', '/', {
      'qt': 's',
      'wd': keyword,
      'rn': '$limit',
      'pn': '0',
      'ie': 'utf-8',
      'oue': '1',
      'fromproduct': 'jsapi',
      if (cityId != null) 'c': '$cityId',
    });
    final body = await _getText(
      uri,
      headers: const {
        'User-Agent': _ua,
        'Referer': 'https://map.baidu.com/',
        'Accept': 'application/json, text/plain, */*',
      },
    );
    if (!body.trimLeft().startsWith('{')) {
      throw Exception('接口返回了非预期内容');
    }
    final json = jsonDecode(body);
    if (json is! Map) throw Exception('返回格式异常');
    // 记录城市 ID，供后续联想接口使用
    final city = json['current_city'];
    if (city is Map && city['code'] is num) {
      _baiduCityId = (city['code'] as num).toInt();
    }
    final content = json['content'];
    final rows = <Map>[];
    if (content is List) {
      rows.addAll(content.whereType<Map>());
    } else if (content is Map) {
      rows.add(content);
    }
    final places = <Place>[];
    for (final raw in rows) {
      final name = '${raw['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      final x = _asDouble(raw['x']);
      final y = _asDouble(raw['y']);
      if (x == null || y == null || x == 0 || y == 0) continue;
      // 网页接口返回的是 BD-09 墨卡托，整数形式放大了 100 倍。
      final mx = x.abs() > 1e8 ? x / 100 : x;
      final my = y.abs() > 1e8 ? y / 100 : y;
      if (mx.abs() < 1000 || my.abs() < 1000) continue;
      final gcj = Coord.bd09McToGcj(mx, my);
      if (gcj.latitude.abs() > 90 || gcj.longitude.abs() > 180) continue;
      final area = [
        '${raw['city_name'] ?? ''}',
        '${raw['area_name'] ?? ''}',
      ].where((e) => e.trim().isNotEmpty).toSet().join('');
      final address = _firstString(raw['addr']);
      places.add(
        Place(
          name: name,
          gcj: gcj,
          address: address.isNotEmpty ? address : area,
          category: _firstString(raw['std_tag']).split(';').last,
          source: PlaceSource.baidu,
        ),
      );
    }
    return places;
  }

  Future<List<Place>> _searchPhoton(String keyword, LatLng center) async {
    final wgs = Coord.gcjToWgs(center);
    final uri = Uri.https('photon.komoot.io', '/api/', {
      'q': keyword,
      'limit': '15',
      'lat': wgs.latitude.toStringAsFixed(4),
      'lon': wgs.longitude.toStringAsFixed(4),
    });
    final json = await _getJson(uri);
    final features = json['features'];
    if (features is! List) return const [];
    final places = <Place>[];
    for (final raw in features) {
      if (raw is! Map) continue;
      final pr = raw['properties'];
      final geometry = raw['geometry'];
      if (pr is! Map || geometry is! Map) continue;
      final coords = geometry['coordinates'];
      if (coords is! List || coords.length < 2) continue;
      final lng = _asDouble(coords[0]);
      final lat = _asDouble(coords[1]);
      if (lng == null || lat == null) continue;
      final name = '${pr['name'] ?? ''}'.trim();
      final address = [
        pr['street'],
        pr['district'],
        pr['city'],
        pr['state'],
      ].where((e) => e != null && '$e'.trim().isNotEmpty).join(' · ');
      if (name.isEmpty && address.isEmpty) continue;
      places.add(
        Place(
          name: name.isEmpty ? address : name,
          gcj: Coord.wgsToGcj(LatLng(lat, lng)),
          address: address,
          category: '${pr['osm_value'] ?? ''}',
          source: PlaceSource.osm,
        ),
      );
    }
    return places;
  }

  /// 识别当前所在地的百度城市编号：先用 OSM 逆地理拿到城市名，
  /// 再用一次城市级搜索换取百度城市 code，之后所有搜索与联想都带城市参数。
  Future<int?> _ensureBaiduCity(LatLng center) async {
    if (_baiduCityId != null) return _baiduCityId;
    final city = await _cityName(center);
    if (city == null || city.isEmpty) return null;
    try {
      final uri = Uri.https('map.baidu.com', '/', {
        'qt': 's',
        'wd': city,
        'rn': '1',
        'ie': 'utf-8',
        'oue': '1',
        'fromproduct': 'jsapi',
      });
      final json = await _getJson(uri);
      final current = json['current_city'];
      if (current is Map && current['code'] is num) {
        final code = (current['code'] as num).toInt();
        if (code > 1) _baiduCityId = code;
      }
    } catch (_) {
      // 识别失败时退化为全国搜索
    }
    return _baiduCityId;
  }

  /// 用 OSM 逆地理取城市名（国内一般为“xx市”）。
  Future<String?> _cityName(LatLng center) async {
    try {
      final wgs = Coord.gcjToWgs(center);
      final uri = Uri.https('photon.komoot.io', '/reverse', {
        'lat': wgs.latitude.toStringAsFixed(6),
        'lon': wgs.longitude.toStringAsFixed(6),
        'limit': '1',
      });
      final json = await _getJson(uri);
      final features = json['features'];
      if (features is List && features.isNotEmpty) {
        final pr = (features.first as Map)['properties'];
        if (pr is Map) {
          final city = '${pr['city'] ?? ''}'.trim();
          final state = '${pr['state'] ?? ''}'.trim();
          // 国内 OSM 的 city 有时是新区/县级市，state 通常是地级市
          if (state.endsWith('市')) return state;
          if (city.isNotEmpty) return city;
          if (state.isNotEmpty) return state;
        }
      }
    } catch (_) {}
    return null;
  }

  List<Place> _withDistance(List<Place> places, LatLng anchor) => places
      .map((p) => p.withDistance(Coord.distanceMeters(anchor, p.gcj)))
      .toList(growable: false);

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final body = await _getText(uri);
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw const FormatException('返回格式异常');
    return Map<String, dynamic>.from(decoded);
  }

  Future<String> _getText(Uri uri, {Map<String, String>? headers}) async {
    final response = await _client
        .get(uri, headers: headers ?? const {'User-Agent': _ua})
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  static String _firstString(Object? value) {
    if (value is String) return value.trim();
    if (value is List) {
      for (final item in value) {
        if (item is String && item.trim().isNotEmpty) return item.trim();
      }
    }
    if (value is Map) {
      for (final item in value.values) {
        if (item is String && item.trim().isNotEmpty) return item.trim();
      }
    }
    return '';
  }

  static double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static String _friendly(Object error) {
    final text = error.toString();
    if (text.contains('TimeoutException')) return '请求超时';
    if (text.contains('SocketException')) return '网络不可用';
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  static String _amapError(String info) => switch (info) {
    'INVALID_USER_KEY' || 'INVALID_USER_SCODE' => '高德 Key 无效，请在设置中重新填写',
    'INVALID_USER_DOMAIN' => '高德 Key 的平台类型需选择“Web 服务”',
    'DAILY_QUERY_OVER_LIMIT' || 'ACCESS_TOO_FREQUENT' => '高德 Key 今日额度已用完',
    'SERVICE_NOT_AVAILABLE' => '高德服务不可用',
    _ => '高德返回错误（$info）',
  };
}

/// 解析“坐标输入”：支持 `29.75,106.58`、`gcj:29.75,106.58`、`wgs:…`、`bd:…`。
/// 不带前缀时按 WGS-84 解释（与系统 GPS 一致）。
LatLng? parseCoordinateQuery(String input) {
  final text = input.trim().replaceAll('，', ',');
  final match = RegExp(
    r'^(wgs|wgs84|gcj|gcj02|bd|bd09)?\s*[:：]?\s*(-?\d{1,3}(?:\.\d+)?)\s*,\s*(-?\d{1,3}(?:\.\d+)?)$',
    caseSensitive: false,
  ).firstMatch(text);
  if (match == null) return null;
  final lat = double.tryParse(match.group(2)!);
  final lng = double.tryParse(match.group(3)!);
  if (lat == null || lng == null) return null;
  if (lat.abs() > 90 || lng.abs() > 180) return null;
  final kind = (match.group(1) ?? 'wgs').toLowerCase();
  final raw = LatLng(lat, lng);
  return switch (kind) {
    'gcj' || 'gcj02' => raw,
    'bd' || 'bd09' => Coord.bd09ToGcj(raw),
    _ => Coord.wgsToGcj(raw),
  };
}
