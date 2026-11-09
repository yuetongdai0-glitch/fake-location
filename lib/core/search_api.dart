import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'coord.dart';
import 'coordinate_input.dart';
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
          return SearchOutcome(
            places: _withDistance(list, anchor),
            notes: notes,
          );
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
      notes.add('开放地图未匹配到结果');
    } catch (e) {
      notes.add('开放地图：${_friendly(e)}');
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

  /// 缓存最近一次百度搜索城市，减少输入联想时重复识别城市。
  static int? _baiduCityId;

  /// 联想直接携带可定位的 POI，点击一次即可落点；无坐标的关键词交给搜索源补全。
  Future<List<Place>> suggest(String prefix, {LatLng? center}) async {
    final keyword = prefix.trim();
    if (keyword.length < 2) return const [];
    final anchor = center ?? const LatLng(39.9087, 116.3975);

    if (amapKey.trim().isNotEmpty) {
      try {
        final uri = Uri.https('restapi.amap.com', '/v3/assistant/inputtips', {
          'key': amapKey.trim(),
          'keywords': keyword,
          'datatype': 'all',
          'location':
              '${anchor.longitude.toStringAsFixed(6)},${anchor.latitude.toStringAsFixed(6)}',
        });
        final json = await _getJson(uri);
        if ('${json['status']}' == '1') {
          final tips = json['tips'];
          final places = <Place>[];
          if (tips is List) {
            for (final tip in tips) {
              if (tip is! Map) continue;
              final name = _firstString(tip['name']);
              final location = _firstString(tip['location']).split(',');
              if (name.isEmpty || location.length != 2) continue;
              final lng = double.tryParse(location[0]);
              final lat = double.tryParse(location[1]);
              if (!_validCoordinate(lat, lng)) continue;
              final point = LatLng(lat!, lng!);
              // 同名分店有不同坐标，不能只按名称去重，否则用户无法区分。
              if (places.any((p) => p.name == name && p.gcj == point)) continue;
              places.add(
                Place(
                  name: name,
                  gcj: point,
                  address: [
                    _firstString(tip['district']),
                    _firstString(tip['address']),
                  ].where((part) => part.isNotEmpty).join(' · '),
                  source: PlaceSource.amap,
                ),
              );
              if (places.length >= 8) break;
            }
          }
          if (places.isNotEmpty) return _withDistance(places, anchor);
        }
      } catch (_) {
        // 无坐标的联想和失败的接口仍走完整搜索降级，不再展示需要二次选择的纯名称。
      }
    }

    final outcome = await search(keyword, center: anchor);
    return outcome.places.take(8).toList(growable: false);
  }

  /// 过滤外部搜索源的非法坐标，避免 NaN、无穷值或占位点进入地图。
  static bool _validCoordinate(double? lat, double? lng) =>
      lat != null &&
      lng != null &&
      lat.isFinite &&
      lng.isFinite &&
      lat.abs() <= 90 &&
      lng.abs() <= 180 &&
      (lat != 0 || lng != 0);

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
      if (!_validCoordinate(lat, lng)) continue;
      final address = _firstString(raw['address']);
      places.add(
        Place(
          name: name,
          gcj: LatLng(lat!, lng!),
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
    // 记录城市 ID，供后续搜索和输入联想复用
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
      if (!_validCoordinate(gcj.latitude, gcj.longitude)) continue;
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
      if (!_validCoordinate(lat, lng)) continue;
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
          gcj: Coord.wgsToGcj(LatLng(lat!, lng!)),
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
      throw Exception('服务请求失败（状态码 ${response.statusCode}）');
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
    if (error is TimeoutException) return '请求超时，请稍后重试';
    if (error is FormatException) return '搜索服务返回的数据格式异常';
    if (error is http.ClientException || text.contains('SocketException')) {
      return '网络请求失败，请检查网络连接';
    }
    final message = text.replaceFirst(RegExp(r'^Exception:\s*'), '');
    // 仅回显应用自身的中文原因，底层英文异常和服务端错误码不直接呈现给用户。
    if (RegExp(r'[\u4e00-\u9fff]').hasMatch(message) &&
        !RegExp(r'[A-Za-z]').hasMatch(message)) {
      return message;
    }
    return '搜索服务暂不可用，请稍后重试';
  }

  static String _amapError(String info) => switch (info) {
    'INVALID_USER_KEY' || 'INVALID_USER_SCODE' => '高德密钥无效，请在设置中重新填写',
    'INVALID_USER_DOMAIN' => '高德密钥类型不匹配，请选择网页接口服务',
    'DAILY_QUERY_OVER_LIMIT' || 'ACCESS_TOO_FREQUENT' => '高德密钥今日额度已用完',
    'SERVICE_NOT_AVAILABLE' => '高德服务不可用',
    _ => '高德服务返回异常，请检查密钥与调用额度',
  };
}

/// 搜索框与坐标面板共用坐标解析，支持 geo URI 及带明确坐标的地图地点链接。
/// 普通地点名称仍走搜索，不能把门牌号、年份等数字误当作经纬度。
LatLng? parseCoordinateQuery(String input) {
  final text = input.trim();
  if (CoordinateInput.containsLink(text) || CoordinateInput.isGeoLink(text)) {
    return CoordinateInput.parse(text)?.gcj;
  }
  final coordinate = text.replaceFirst(
    RegExp(
      r'^(wgs-?84|wgs|gcj-?02|gcj|bd-?09|bd|百度|高德|gps)\s*[:：]\s*',
      caseSensitive: false,
    ),
    '',
  );
  if (!RegExp(r'''^[+\-\d\s.,，;；°º度分秒:'"′’″”NSEWnsew北南东西]+$''')
      .hasMatch(coordinate)) {
    return null;
  }
  return CoordinateInput.parse(text)?.gcj;
}
